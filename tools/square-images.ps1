<#
  square-images.ps1

  Re-emits every product image in _media\ as a padded 1:1 square WebP, at
  widths that give room for a lightbox zoom. Amazon-style: 1000px minimum,
  2000px preferred, with derivatives at 400 / 800 / 1200 / 1600 / 2000w.
  Never crops - pads with white so the whole machine stays visible.

  Runs from site\, writes to assets\images\{slug}\ over the top of existing
  files, and rewrites the source widths in src\data\images.json so build-data
  picks up the new sizes. Idempotent.

  Keep this file pure ASCII and saved with a UTF-8 BOM (see CLAUDE.md).
#>
[CmdletBinding()]
param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$SiteRoot = Split-Path $PSScriptRoot -Parent
$MediaCatalogue = Join-Path $SiteRoot '_media\original'      # scraped catalogue gallery/spec/etc.
$MediaCate      = Join-Path $SiteRoot '_media\cate'          # cate scrape (twm-xxx named)
$MediaZh        = Join-Path $SiteRoot '_media\zh-cate'       # per-slug folders from www scrape
$MediaVideo     = Join-Path $SiteRoot '_media\video'         # YouTube posters
$ImagesJson     = Join-Path $SiteRoot 'src\data\images.json'
$AssetsRoot     = Join-Path $SiteRoot 'assets\images'

# Amazon-style widths. 2000 is the top target; below that scale steps for
# responsive srcset. Never upscale past the source.
$Widths = @(400, 800, 1200, 1600, 2000)

# Everything except spec / feature / app / video-poster gets squared. Spec
# sheets are wide rectangles that would look silly padded to 1:1, and the
# YouTube posters are already 16:9 by convention.
function Test-ShouldSquare {
    param([string]$Basename)
    if ($Basename -match '^spec-|^feature-|^app-') { return $false }
    if ($Basename -match '-video-poster-') { return $false }
    return $true
}

function Convert-ToSquare {
    param(
        [string]$SrcPath,
        [string]$OutDir,
        [string]$Basename,
        [int[]]$TargetWidths
    )
    if (-not (Test-Path $SrcPath)) { return $null }
    $info = magick identify -format '%w %h' $SrcPath
    if (-not $info) { return $null }
    $parts = $info -split ' '
    $w = [int]$parts[0]; $h = [int]$parts[1]
    if ($w -le 0 -or $h -le 0) { return $null }

    # Source largest dimension - never upscale past it.
    $maxDim = [Math]::Max($w, $h)

    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

    $sources = @()
    foreach ($tw in $TargetWidths) {
        if ($tw -gt $maxDim -and @($sources).Count -gt 0) { continue }
        # First width that exceeds max still gets emitted once so smaller sources
        # still produce a usable derivative.
        $emitW = [Math]::Min($tw, $maxDim)
        $out = Join-Path $OutDir ("{0}-{1}w.webp" -f $Basename, $emitW)
        if ($WhatIf) {
            Write-Host ("  would write {0}" -f $out) -ForegroundColor DarkGray
        } else {
            # Resize longest side to $emitW, then pad to $emitW x $emitW on white.
            # -alpha remove flattens any PNG transparency onto white.
            magick $SrcPath `
                -background white -alpha remove -alpha off -strip `
                -resize ("{0}x{0}>" -f $emitW) `
                -gravity center -extent ("{0}x{0}" -f $emitW) `
                -quality 84 -define webp:method=6 `
                $out 2>$null | Out-Null
            if (-not (Test-Path $out)) { continue }
        }
        $sources += [pscustomobject]@{
            width = $emitW
            src   = ('/assets/images/' + (Split-Path $OutDir -Leaf) + '/' + (Split-Path $out -Leaf))
            bytes = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
        }
        if ($tw -ge $maxDim) { break }
    }
    return $sources
}

# ---------------------------------------------------------------------------
# Walk images.json and re-emit each entry
# ---------------------------------------------------------------------------

$im = Get-Content $ImagesJson -Raw -Encoding UTF8 | ConvertFrom-Json
$slugs = @($im.PSObject.Properties.Name)

$emitted = 0; $skipped = 0; $missing = 0
foreach ($slug in $slugs) {
    $entry = $im.$slug
    if (-not $entry.PSObject.Properties['images']) { continue }
    $slugOutDir = Join-Path $AssetsRoot $slug

    foreach ($img in @($entry.images)) {
        $base = ''
        if ($img.PSObject.Properties['basename'] -and $img.basename) {
            $base = $img.basename
        } elseif ($img.kind -eq 'gallery') {
            $base = ('gallery-{0:d2}' -f $img.index)
        } elseif ($img.kind -eq 'spec') {
            $base = ('spec-{0:d2}' -f $img.index)
        } elseif ($img.kind -eq 'feature') {
            $base = ('feature-{0:d2}' -f $img.index)
        } elseif ($img.kind -eq 'app') {
            $base = ('app-{0:d2}' -f $img.index)
        } elseif ($img.kind -eq 'machine') {
            # machine-kind entries carry their descriptive basename already.
            $base = ('gallery-{0:d2}' -f $img.index)
        }

        if (-not (Test-ShouldSquare -Basename $base)) { $skipped++; continue }

        # Find the source in one of _media\original\{slug}, _media\cate, or _media\zh-cate\{slug}
        $srcCandidates = @(
            (Join-Path $MediaCatalogue ("{0}\{1}.jpg" -f $slug, $base)),
            (Join-Path $MediaCatalogue ("{0}\{1}.png" -f $slug, $base)),
            (Join-Path $MediaZh        ("{0}\{1}.jpg" -f $slug, $base)),
            (Join-Path $MediaZh        ("{0}\{1}.png" -f $slug, $base)),
            (Join-Path $MediaCate      ("{0}.jpg" -f $base)),
            (Join-Path $MediaCate      ("{0}.png" -f $base))
        )
        $src = $srcCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $src) {
            $missing++
            Write-Host ("  ! missing source for {0} / {1}" -f $slug, $base) -ForegroundColor Yellow
            continue
        }

        $sources = Convert-ToSquare -SrcPath $src -OutDir $slugOutDir -Basename $base -TargetWidths $Widths
        if ($sources -and @($sources).Count -gt 0) {
            $emitted += @($sources).Count
            if (-not $WhatIf) {
                # Update the entry's sources[] and width/height to square
                $largest = $sources[-1]
                $img.width  = $largest.width
                $img.height = $largest.width
                $newSrcs = @()
                foreach ($s in $sources) {
                    $newSrcs += [pscustomobject]@{ width = $s.width; src = $s.src; bytes = $s.bytes }
                }
                $img.sources = $newSrcs
            }
        }
    }
}

if (-not $WhatIf) {
    $json = $im | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ImagesJson, $json, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host ""
Write-Host ("Square regen: {0} webp files, {1} sources missing, {2} skipped (spec/feature/app/poster)" -f $emitted, $missing, $skipped) -ForegroundColor Green
