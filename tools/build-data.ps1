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

# Optional image-overrides.json: promote specific gallery images from
# 'workpiece' to 'machine' where the classifier misfires, demote scraped
# 'machine' shots that are actually finished parts, and remove images that
# must not appear on the public site (third-party branded photographs).
$OverridesPath = Join-Path $SiteRoot 'src\data\image-overrides.json'
$machineOverrides = @{}
$workpieceOverrides = @{}
$removeOverrides = @{}
if (Test-Path $OverridesPath) {
    $oraw = Get-Content $OverridesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($oraw.PSObject.Properties['machine']) {
        foreach ($prop in $oraw.machine.PSObject.Properties) {
            if ($prop.Name -notlike '_*') {
                # Keep the array in its source order so IndexOf gives a rank
                # that matches the client's preference (first-listed wins).
                $machineOverrides[$prop.Name] = @($prop.Value)
            }
        }
    }
    if ($oraw.PSObject.Properties['workpiece']) {
        foreach ($prop in $oraw.workpiece.PSObject.Properties) {
            if ($prop.Name -notlike '_*') {
                $workpieceOverrides[$prop.Name] = @($prop.Value)
            }
        }
    }
    if ($oraw.PSObject.Properties['remove']) {
        foreach ($prop in $oraw.remove.PSObject.Properties) {
            if ($prop.Name -notlike '_*') {
                $removeOverrides[$prop.Name] = @($prop.Value)
            }
        }
    }
}

# Optional specs.json: transcribed spec-sheet values as a { label, value }
# table per product. Absent slugs render as before (spec image + on-request).
$SpecsPath = Join-Path $SiteRoot 'src\data\specs.json'
$specTables = @{}
if (Test-Path $SpecsPath) {
    $sraw = Get-Content $SpecsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $sraw.PSObject.Properties) {
        if ($prop.Name -notlike '_*') { $specTables[$prop.Name] = $prop.Value }
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
    $bytes = 0
    if ($largest.PSObject.Properties['bytes']) { $bytes = [int]$largest.bytes }

    return [pscustomobject]@{
        src    = $largest.src
        srcset = ($parts -join ', ')
        width  = $largest.width
        height = [int][math]::Round($largest.width * $ratio)
        alt    = $Alt
        _bytes = $bytes
    }
}

# Drop near-identical thumbnails from a list. Two images are treated as the
# same when their widest-source byte count is identical - which for our
# WebP pipeline means the same picture at the same resolution.
function Remove-DuplicateImages {
    param([System.Collections.Generic.List[object]]$List)
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $List -or $List.Count -eq 0) { return ,$out }
    $seen = @{}
    foreach ($it in $List) {
        $key = ''
        if ($it.PSObject.Properties['_bytes'] -and $it._bytes -gt 0) {
            $key = "{0}x{1}b" -f $it.width, $it._bytes
        } else {
            $key = "{0}|{1}" -f $it.width, $it.src
        }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $out.Add($it)
    }
    return ,$out
}

# Strip transient helper props before serialisation.
function Remove-InternalProps {
    param([object]$Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties['_bytes']) {
        $Obj.PSObject.Properties.Remove('_bytes')
    }
    return $Obj
}

# ---------------------------------------------------------------------------
# Products
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Title Case for product names, Amazon-style. Every word capitalised except a
# short list of connecting words, which stay lower unless they open the title.
# Model numbers (TWM-xxx), acronyms (BLDC, SCARA, PLC, AC, DC, OD, HMI) and
# any all-caps token stay verbatim. Numeric words (3-phase, 3D) also stay.
# ---------------------------------------------------------------------------
$script:TitleSkip = @('a','an','and','as','at','but','by','for','from','in','of','on','or','the','to','via','with')
$script:TitleKeep = @('TWM','TWA','TMW','NB','BLDC','SCARA','PLC','AC','DC','OD','ID','HMI','LED','LCD','CNC','VCR','MELFA','SP001','AP01','IP01','IW01','ISW001','ISP01','LA01','WB001','RF30S','RT533','LS001','RT533-04')

function Convert-TitleCase {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $words = $Text -split '(\s+|[\-\/\\\(\)])'
    $out = @()
    $wordIdx = 0
    for ($i = 0; $i -lt $words.Count; $i++) {
        $w = $words[$i]
        if ([string]::IsNullOrEmpty($w)) { continue }
        if ($w -match '^\s+$' -or $w -match '^[\-\/\\\(\)]$') { $out += $w; continue }
        # Keep uppercase tokens as-is (model numbers, acronyms)
        if ($w -cmatch '^[A-Z0-9\-]+$' -and $w.Length -ge 2) { $out += $w; $wordIdx++; continue }
        # Keep hyphenated model-like tokens
        $upper = $w.ToUpperInvariant()
        if ($script:TitleKeep -contains $upper) { $out += $upper; $wordIdx++; continue }
        # Small connecting words stay lower unless first word
        $lower = $w.ToLowerInvariant()
        if ($wordIdx -gt 0 -and $script:TitleSkip -contains $lower) { $out += $lower; $wordIdx++; continue }
        # Standard title case: capitalise first, lowercase the rest
        # Preserve any embedded caps that look like part of a compound word.
        if ($w.Length -eq 1) { $out += $w.ToUpperInvariant() }
        else { $out += $w.Substring(0,1).ToUpperInvariant() + $w.Substring(1).ToLowerInvariant() }
        $wordIdx++
    }
    return ($out -join '')
}

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
        # Overrides for this slug (may be empty). Order preserved from JSON so
        # the first basename listed wins hero selection.
        $slugMachineList   = @()
        $slugWorkpieceList = @()
        $slugRemoveList    = @()
        if ($machineOverrides.ContainsKey($slug))   { $slugMachineList   = $machineOverrides[$slug] }
        if ($workpieceOverrides.ContainsKey($slug)) { $slugWorkpieceList = $workpieceOverrides[$slug] }
        if ($removeOverrides.ContainsKey($slug))    { $slugRemoveList    = $removeOverrides[$slug] }

        foreach ($img in @($entry.images)) {
            $obj = New-ImageObject -Entry $img -Alt $altBase
            if (-not $obj) { continue }
            # basename to match against overrides (gallery-01, spec-01, etc.)
            $imgBase = ''
            if ($img.PSObject.Properties['basename'] -and $img.basename) {
                $imgBase = $img.basename
            } elseif ($img.kind -eq 'gallery') {
                $imgBase = ("gallery-{0:d2}" -f $img.index)
            }
            # Filter: image is on the public removal list
            if ($imgBase -and ($slugRemoveList -contains $imgBase)) { continue }

            switch ($img.kind) {
                'gallery' {
                    # Separate the machine from the part it makes. This company
                    # sells automation equipment; leading with a photo of a
                    # customer's motor tells a procurement engineer the wrong
                    # thing about who they are talking to.
                    $orig = Join-Path $OrigRoot ("{0}\gallery-{1:d2}.jpg" -f $slug, $img.index)
                    $kind = 'workpiece'
                    if (Test-Path $orig) { $kind = Get-PhotoKind -Path $orig }
                    # image-overrides.json can override the classifier
                    if ($imgBase -and ($slugMachineList -contains $imgBase)) { $kind = 'equipment' }
                    Add-Member -InputObject $obj -NotePropertyName 'shows' -NotePropertyValue $kind -Force
                    if ($kind -eq 'equipment') {
                        $obj.alt = "$altBase in operation"
                        # Give overridden gallery images a primary rank based on
                        # the order they appear in the override list, so hero
                        # picking still respects the client's preferred first shot.
                        if (($slugMachineList -contains $imgBase)) {
                            $rank = [array]::IndexOf($slugMachineList, $imgBase) + 1
                            Add-Member -InputObject $obj -NotePropertyName 'primary' -NotePropertyValue $rank -Force
                        }
                        $equipment.Add($obj)
                    } else {
                        $obj.alt = "$altBase - finished part produced on this machine"
                        $workpiece.Add($obj)
                    }
                    $gallery.Add($obj)
                }
                'machine' {
                    # Declared equipment. classify.ps1 misfires on machines shot
                    # on a white studio background, which is how the cate- pages
                    # publish everything, so anything scraped from that source
                    # comes with kind='machine' set explicitly.
                    # Some scraped shots are actually finished parts on white
                    # (armatures, rotors, stators). image-overrides.json's
                    # workpiece list downgrades those to workpiece so they land
                    # at the end of the gallery, not beside real equipment.
                    if ($imgBase -and ($slugWorkpieceList -contains $imgBase)) {
                        Add-Member -InputObject $obj -NotePropertyName 'shows' -NotePropertyValue 'workpiece' -Force
                        $obj.alt = "$altBase - finished part produced on this machine"
                        $workpiece.Add($obj)
                        $gallery.Add($obj)
                        continue
                    }
                    Add-Member -InputObject $obj -NotePropertyName 'shows' -NotePropertyValue 'equipment' -Force
                    if ($img.PSObject.Properties['alt'] -and $img.alt) { $obj.alt = $img.alt }
                    # Extract the primary index from the basename (twm-929-...-01-1600w
                    # -> 01, ...-02-1600w -> 02) so the hero picker can prefer the
                    # first shot from the source page, which is the machine, over
                    # any later frame that happens to be pixel-larger but shows a
                    # workpiece or a detail. Falls to 99 for anything unparseable
                    # so it never leapfrogs a real primary.
                    $primary = 99
                    if ($img.PSObject.Properties['basename'] -and $img.basename -match '-(\d+)$') {
                        $primary = [int]$Matches[1]
                    }
                    Add-Member -InputObject $obj -NotePropertyName 'primary' -NotePropertyValue $primary -Force
                    $equipment.Add($obj)
                    $gallery.Add($obj)
                }
                'spec'    { if (-not $spec)    { $obj.alt = "$altBase - published specifications"; $spec = $obj } }
                'feature' { if (-not $feature) { $obj.alt = "$altBase - features"; $feature = $obj } }
                'app'     { if (-not $app)     { $obj.alt = "$altBase - applications"; $app = $obj } }
            }
        }
    }

    # Lead with the machine, always. The picker prefers the primary shot from
    # the source page (basename ends in -01 -> primary=1) so a machine photo
    # cannot lose to a workpiece detail that happens to be larger. Ties on
    # primary go to the widest derivative.
    $hero = $null
    if ($equipment.Count -gt 0) {
        $hero = @($equipment | Sort-Object @{Expression={ if ($_.PSObject.Properties['primary']) { $_.primary } else { 50 } }}, @{Expression={ -$_.width }})[0]
    } elseif ($workpiece.Count -gt 0) {
        $hero = @($workpiece | Sort-Object { -$_.width })[0]
    }

    # Reorder the gallery so the hero comes first, then any other declared
    # machine shots by primary index, then equipment gallery shots, then
    # workpiece shots at the very end. The client's instruction: "all the
    # products generated (motor itself) should be at the very end, not the
    # main image".
    if ($equipment.Count -gt 0 -or $workpiece.Count -gt 0) {
        # Drop near-identical thumbs within each group before sorting so
        # dedup does not have to fight cross-group ordering.
        $equipment = Remove-DuplicateImages $equipment
        $workpiece = Remove-DuplicateImages $workpiece

        # Sort each group in place, so the standalone equipment/workpiece
        # arrays serialized into products.json (consumed by the lightbox
        # SOLUTION / FINISHED_PRODUCTS tabs) share the same order as the
        # merged gallery.
        $equipmentSorted = New-Object System.Collections.Generic.List[object]
        foreach ($e in @($equipment | Sort-Object @{Expression={ if ($_.PSObject.Properties['primary']) { $_.primary } else { 50 } }}, @{Expression={ -$_.width }})) {
            $equipmentSorted.Add($e)
        }
        $equipment = $equipmentSorted

        $workpieceSorted = New-Object System.Collections.Generic.List[object]
        foreach ($w in @($workpiece | Sort-Object { -$_.width })) {
            $workpieceSorted.Add($w)
        }
        $workpiece = $workpieceSorted

        $ordered = New-Object System.Collections.Generic.List[object]
        # Machine-kind first, sorted by primary index (declared machine
        # frames, basename ending -01 -> primary=1, beat any equipment
        # gallery detail shot). Ties break on the widest derivative.
        foreach ($e in $equipment) { $ordered.Add($e) }
        # Workpiece shots pushed to the back
        foreach ($w in $workpiece) { $ordered.Add($w) }
        $gallery = $ordered
    }

    # Strip internal-only props from every image object before serialising.
    foreach ($it in $gallery)   { Remove-InternalProps $it | Out-Null }
    foreach ($it in $equipment) { Remove-InternalProps $it | Out-Null }
    foreach ($it in $workpiece) { Remove-InternalProps $it | Out-Null }
    Remove-InternalProps $hero | Out-Null
    Remove-InternalProps $spec | Out-Null
    Remove-InternalProps $feature | Out-Null
    Remove-InternalProps $app | Out-Null

    $video = $null
    if ($videos.ContainsKey($slug)) { $video = $videos[$slug] }

    # Copy is stored with both enDesc and jaDesc; build.ps1 chooses per locale.
    # products.json carries the full record so nothing has to look up the copy
    # file again at template render time.
    $copy = $null
    if ($prodCopy.ContainsKey($slug)) { $copy = $prodCopy[$slug] }

    # Transcribed spec table takes precedence over the spec image where both
    # exist. The image stays available in the disclosure below the table.
    $specTable = $null
    if ($specTables.ContainsKey($slug)) { $specTable = $specTables[$slug] }

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

    # Title Case per Amazon convention. Model numbers stay as-is (upper).
    $titleCased = Convert-TitleCase $p.title
    $products.Add([pscustomobject]@{
        slug       = $slug
        model      = $p.model
        title      = $titleCased
        family     = $famSlug
        familyName = $famName
        hero       = $hero
        heroShows  = $(if ($equipment.Count -gt 0) { 'equipment' } elseif ($workpiece.Count -gt 0) { 'workpiece' } else { $null })
        video      = $video
        copy       = $copy
        tags       = $tags
        specTable  = $specTable
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
    # A category card must show a machine, never a workpiece. Look across every
    # product in the family and pick the best primary machine shot -- the
    # image whose basename ends in -01 wins over a larger later frame that
    # might show a component. Only if no product in the family has a machine
    # shot at all do we fall back on the widest hero.
    $inFamily = @($products | Where-Object { $_.family -eq $f.slug })
    if ($inFamily.Count -eq 0) { continue }

    # Gather every equipment image from every product in this family and
    # score them by (primary index ascending, width descending).
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($p in $inFamily) {
        if (-not $p.equipment) { continue }
        foreach ($img in @($p.equipment)) {
            $prim = 50
            if ($img.PSObject.Properties['primary']) { $prim = $img.primary }
            $candidates.Add([pscustomobject]@{
                img = $img; primary = $prim; product = $p
            })
        }
    }

    $chosen = $null
    if ($candidates.Count -gt 0) {
        $best = @($candidates | Sort-Object primary, @{Expression={ -$_.img.width }})[0]
        $chosen = $best
    } else {
        # No machine shot exists in this family at all. Fall back on the hero
        # of the largest product so the card is not blank.
        $withHero = @($inFamily | Where-Object { $_.hero })
        if ($withHero.Count -eq 0) { continue }
        $bestP = @($withHero | Sort-Object { -$_.hero.width })[0]
        $chosen = [pscustomobject]@{ img = $bestP.hero; product = $bestP }
    }

    $covers[$f.slug] = [pscustomobject]@{
        src       = $chosen.img.src
        srcset    = $chosen.img.srcset
        width     = $chosen.img.width
        height    = $chosen.img.height
        alt       = ("{0} - {1}" -f $f.name, $chosen.product.title)
        fromModel = $chosen.product.model
        fromSlug  = $chosen.product.slug
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
