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
. (Join-Path $PSScriptRoot 'classify.ps1')
$slugMap = Resolve-ProductSlugs -Products $raw

$OrigRoot = Join-Path $SiteRoot '_media\original'

# Optional videos.json: one YouTube id + poster per product slug. It carries
# the assets the product page's video block needs. Absent is fine - the block
# renders only for products with an entry, so leaving a product out keeps its
# page as it was.
$VideosPath = Join-Path $SiteRoot 'src\data\videos.json'
$videos = @{}
if (Test-Path $VideosPath) {
    $vraw = Get-Content $VideosPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $vraw.PSObject.Properties) {
        if ($prop.Name -notlike '_*') { $videos[$prop.Name] = $prop.Value }
    }
}

# Optional product-copy.json: description and specification bullets per slug,
# extracted from the client's Chinese-site and English-site product pages
# with terminology.json corrections applied. Absent slugs simply render
# without the description/spec blocks, so the pipeline is safe if the file
# is deleted.
$CopyPath = Join-Path $SiteRoot 'src\data\product-copy.json'
$prodCopy = @{}
if (Test-Path $CopyPath) {
    $craw = Get-Content $CopyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $craw.PSObject.Properties) {
        if ($prop.Name -notlike '_*') { $prodCopy[$prop.Name] = $prop.Value }
    }
}

# Optional tags.json: process/motor-type/form tags per product slug. Absent
# is fine - products just carry no tags. Tags let a product appear in every
# category it belongs to without splitting its URL, which is how the client
# asked for a machine that serves several use cases to be discoverable.
$TagsPath = Join-Path $SiteRoot 'src\data\tags.json'
$productTags = @{}
$tagCatalogue = @{}
if (Test-Path $TagsPath) {
    $traw = Get-Content $TagsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $traw.tags.PSObject.Properties) {
        $tagCatalogue[$prop.Name] = $prop.Value
    }
    foreach ($prop in $traw.products.PSObject.Properties) {
        $productTags[$prop.Name] = @($prop.Value)
    }
}

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

    $equipment = New-Object System.Collections.Generic.List[object]
    $workpiece = New-Object System.Collections.Generic.List[object]
    $gallery   = New-Object System.Collections.Generic.List[object]
    $spec      = $null
    $feature   = $null
    $app       = $null

    if ($entry) {
        foreach ($img in @($entry.images)) {
            $obj = New-ImageObject -Entry $img -Alt $altBase
            if (-not $obj) { continue }
            switch ($img.kind) {
                'gallery' {
                    # Separate the machine from the part it makes. This company
                    # sells automation equipment; leading with a photo of a
                    # customer's motor tells a procurement engineer the wrong
                    # thing about who they are talking to.
                    $orig = Join-Path $OrigRoot ("{0}\gallery-{1:d2}.jpg" -f $slug, $img.index)
                    $kind = 'workpiece'
                    if (Test-Path $orig) { $kind = Get-PhotoKind -Path $orig }
                    Add-Member -InputObject $obj -NotePropertyName 'shows' -NotePropertyValue $kind -Force
                    if ($kind -eq 'equipment') {
                        $obj.alt = "$altBase in operation"
                        $equipment.Add($obj)
                    } else {
                        $obj.alt = "$altBase - finished part produced on this machine"
                        $workpiece.Add($obj)
                    }
                    $gallery.Add($obj)
                }
                'machine' {
                    # Declared equipment, never guessed at. classify.ps1 reads a
                    # studio cutout on white as a workpiece, which is true of the
                    # old catalogue galleries and false for the photographs on
                    # the cate- listing pages: those are whole machines shot on
                    # white, and the classifier files every one of them wrong.
                    # Anything taken from that source is declared here instead.
                    Add-Member -InputObject $obj -NotePropertyName 'shows' -NotePropertyValue 'equipment' -Force
                    if ($img.PSObject.Properties['alt'] -and $img.alt) { $obj.alt = $img.alt }
                    $equipment.Add($obj)
                    $gallery.Add($obj)
                }
                'spec'    { if (-not $spec)    { $obj.alt = "$altBase - published specifications"; $spec = $obj } }
                'feature' { if (-not $feature) { $obj.alt = "$altBase - features"; $feature = $obj } }
                'app'     { if (-not $app)     { $obj.alt = "$altBase - applications"; $app = $obj } }
            }
        }
    }

    # Lead with the machine, always. Only fall back to a workpiece photo when
    # the catalogue has no equipment shot at all -- 15 products are in that
    # position and need photography from the client.
    $hero = $null
    if ($equipment.Count -gt 0) {
        $hero = @($equipment | Sort-Object { -$_.width })[0]
    } elseif ($workpiece.Count -gt 0) {
        $hero = @($workpiece | Sort-Object { -$_.width })[0]
    }

    $video = $null
    if ($videos.ContainsKey($slug)) { $video = $videos[$slug] }

    # Copy is stored with both enDesc and jaDesc; build.ps1 chooses per locale.
    # products.json carries the full record so nothing has to look up the copy
    # file again at template render time.
    $copy = $null
    if ($prodCopy.ContainsKey($slug)) { $copy = $prodCopy[$slug] }

    # Expand each raw tag slug into { slug, label, kind } so templates can
    # render the human label and never have to lift it out of a dictionary.
    # href is composed in build.ps1 because it depends on the locale prefix.
    $tags = @()
    if ($productTags.ContainsKey($slug)) {
        foreach ($tagSlug in $productTags[$slug]) {
            $meta = $tagCatalogue[$tagSlug]
            if ($null -eq $meta) {
                $tags += [pscustomobject]@{ slug = $tagSlug; label = $tagSlug; kind = 'other' }
            } else {
                $tags += [pscustomobject]@{ slug = $tagSlug; label = $meta.label; kind = $meta.kind }
            }
        }
    }

    $products.Add([pscustomobject]@{
        slug       = $slug
        model      = $p.model
        title      = $p.title
        family     = $famSlug
        familyName = $famName
        hero       = $hero
        heroShows  = $(if ($equipment.Count -gt 0) { 'equipment' } elseif ($workpiece.Count -gt 0) { 'workpiece' } else { $null })
        video      = $video
        copy       = $copy
        tags       = $tags
        # .ToArray(), not @($gallery): the array subexpression operator throws
        # "Argument types do not match" on a Generic.List[object] in PS 5.1.
        gallery    = $gallery.ToArray()
        equipment  = $equipment.ToArray()
        workpiece  = $workpiece.ToArray()
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
    # A category card must show equipment. Prefer a product in this family that
    # actually has a machine photograph, before falling back on width.
    $withEquip = @($products | Where-Object { $_.family -eq $f.slug -and $_.heroShows -eq 'equipment' })
    $inFamily  = $withEquip
    if ($inFamily.Count -eq 0) {
        $inFamily = @($products | Where-Object { $_.family -eq $f.slug -and $_.hero })
    }
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
