<#
  build-data.ps1

  Turns the raw catalogue scrape plus the image manifest into src\data\products.json,
  the single canonical product list the site build consumes: clean slugs, family
  assignment, and ready-to-use responsive image objects.

  Run this after tools\fetch-media.ps1 and before build.ps1.

  Keep this file pure ASCII and saved with a UTF-8 BOM -- see CLAUDE.md.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$SiteRoot  = Split-Path $PSScriptRoot -Parent
$Source    = Join-Path (Split-Path $SiteRoot -Parent) 'research\fatop\fatop-products.json'
$ImagesIn  = Join-Path $SiteRoot 'src\data\images.json'
$Catalogue = Join-Path $SiteRoot 'src\data\catalogue.json'
$OutPath   = Join-Path $SiteRoot 'src\data\products.json'

foreach ($p in @($Source, $ImagesIn, $Catalogue)) {
    if (-not (Test-Path $p)) { throw "Missing input: $p" }
}

$raw       = Get-Content $Source    -Raw -Encoding UTF8 | ConvertFrom-Json
$images    = Get-Content $ImagesIn  -Raw -Encoding UTF8 | ConvertFrom-Json
$catalogue = Get-Content $Catalogue -Raw -Encoding UTF8 | ConvertFrom-Json

. (Join-Path $PSScriptRoot 'slug.ps1')
$slugMap = Resolve-ProductSlugs -Products $raw

# sourceName (as it appears in the scraped breadcrumb) -> family slug
$familyBySource = @{}
foreach ($f in $catalogue.families) { $familyBySource[$f.sourceName] = $f }

# ---------------------------------------------------------------------------
# Build a ready-to-use responsive image object from a manifest entry
#   Templates should never have to assemble a srcset by hand.
# ---------------------------------------------------------------------------
function New-ImageObject {
    param($Entry, [string]$Alt)

    $sources = @($Entry.sources | Sort-Object width)
    if ($sources.Count -eq 0) { return $null }

    $largest = $sources[$sources.Count - 1]
    $parts = @()
    foreach ($s in $sources) { $parts += ("{0} {1}w" -f $s.src, $s.width) }

    # Height for the widest derivative, so width/height on the tag matches the
    # image the browser most likely picks and CLS stays at zero.
    $ratio = 1.0
    if ($Entry.width -gt 0) { $ratio = [double]$Entry.height / [double]$Entry.width }

    # pscustomobject, not [ordered]@{}: these objects get sorted, copied and
    # re-serialised, and OrderedDictionary's int/object indexer overloads make
    # that fragile. This also matches what ConvertFrom-Json hands back.
    return [pscustomobject]@{
        src    = $largest.src
        srcset = ($parts -join ', ')
        width  = $largest.width
        height = [int][math]::Round($largest.width * $ratio)
        alt    = $Alt
    }
}

# ---------------------------------------------------------------------------
# Products
# ---------------------------------------------------------------------------

$products = New-Object System.Collections.Generic.List[object]

foreach ($p in $raw) {
    $slug = $slugMap[$p.slug]

    $source = ''
    if ($p.breadcrumb -and @($p.breadcrumb).Count -gt 0) { $source = $p.breadcrumb[0] }
    $family = $null
    if ($source -and $familyBySource.ContainsKey($source)) { $family = $familyBySource[$source] }

    $famSlug = $null
    $famName = $null
    if ($family) {
        $famSlug = [string]$family.slug
        $famName = [string]$family.name
    }

    # Alt text describes what the machine is, not "image of a machine".
    $altBase = $p.title
    if ($p.model) { $altBase = "{0} {1}" -f $p.model, $p.title }

    $entry = $null
    if ($images.PSObject.Properties[$slug]) { $entry = $images.$slug }

    $gallery = New-Object System.Collections.Generic.List[object]
    $spec    = $null
    $feature = $null
    $app     = $null

    if ($entry) {
        foreach ($img in @($entry.images)) {
            $obj = New-ImageObject -Entry $img -Alt $altBase
            if (-not $obj) { continue }
            switch ($img.kind) {
                'gallery' { $gallery.Add($obj) }
                'spec'    { if (-not $spec)    { $obj.alt = "$altBase - published specifications"; $spec = $obj } }
                'feature' { if (-not $feature) { $obj.alt = "$altBase - features"; $feature = $obj } }
                'app'     { if (-not $app)     { $obj.alt = "$altBase - applications"; $app = $obj } }
            }
        }
    }

    # The widest gallery image is the one worth leading with.
    $hero = $null
    if ($gallery.Count -gt 0) {
        $hero = @($gallery | Sort-Object { -$_.width })[0]
    }

    $products.Add([pscustomobject]@{
        slug       = $slug
        model      = $p.model
        title      = $p.title
        family     = $famSlug
        familyName = $famName
        hero       = $hero
        # .ToArray(), not @($gallery): the array subexpression operator throws
        # "Argument types do not match" on a Generic.List[object] in PS 5.1.
        gallery    = $gallery.ToArray()
        spec       = $spec
        feature    = $feature
        app        = $app
        hasSpec    = ($null -ne $spec)
        imageCount = $gallery.Count
    })
}

# ---------------------------------------------------------------------------
# Family covers -- the widest available photo from a product in that family,
# so the category grid on the home page shows a real machine.
# ---------------------------------------------------------------------------

$covers = [ordered]@{}
foreach ($f in $catalogue.families) {
    $inFamily = @($products | Where-Object { $_.family -eq $f.slug -and $_.hero })
    if ($inFamily.Count -eq 0) { continue }
    $best = @($inFamily | Sort-Object { -$_.hero.width })[0]
    $covers[$f.slug] = [pscustomobject]@{
        src       = $best.hero.src
        srcset    = $best.hero.srcset
        width     = $best.hero.width
        height    = $best.hero.height
        alt       = ("{0} - {1}" -f $f.name, $best.title)
        fromModel = $best.model
        fromSlug  = $best.slug
    }
}

$out = [pscustomobject]@{
    generated = (Get-Date -Format 'yyyy-MM-dd')
    covers    = $covers
    products  = $products.ToArray()
}

$json = $out | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($OutPath, $json, (New-Object System.Text.UTF8Encoding($false)))

$withHero = @($products | Where-Object { $_.hero }).Count
$withSpec = @($products | Where-Object { $_.hasSpec }).Count
$noFamily = @($products | Where-Object { -not $_.family })

Write-Host ""
Write-Host "Product data built" -ForegroundColor Green
Write-Host ("  products        : {0}" -f $products.Count) -ForegroundColor DarkGray
Write-Host ("  with a photo    : {0}" -f $withHero) -ForegroundColor DarkGray
Write-Host ("  with spec image : {0}" -f $withSpec) -ForegroundColor DarkGray
Write-Host ("  family covers   : {0} of {1}" -f $covers.Keys.Count, @($catalogue.families).Count) -ForegroundColor DarkGray
if ($noFamily.Count -gt 0) {
    Write-Host ("  UNMAPPED FAMILY : {0}" -f $noFamily.Count) -ForegroundColor Red
    foreach ($n in $noFamily) { Write-Host ("    " + $n.title) -ForegroundColor DarkRed }
}
Write-Host ("  -> src\data\products.json") -ForegroundColor DarkGray
Write-Host ""
