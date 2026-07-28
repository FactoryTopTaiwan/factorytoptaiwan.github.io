<#
  fetch-media.ps1

  Downloads the client's own machine photography and technical images from
  en.fatop.com.tw / img.mweb.com.tw, converts everything to WebP, and writes a
  manifest the site build consumes.

  Originals land in site\_media\original\ which is gitignored and never
  committed. Only the WebP derivatives are published.

  Keep this file pure ASCII and saved with a UTF-8 BOM -- see CLAUDE.md.

  Usage:
    .\tools\fetch-media.ps1                 download what is missing, convert
    .\tools\fetch-media.ps1 -Force          re-download everything
    .\tools\fetch-media.ps1 -ConvertOnly    skip the network, re-run conversion
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$ConvertOnly,
    [int]$DelayMs = 150
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SiteRoot = Split-Path $PSScriptRoot -Parent
$Source   = Join-Path (Split-Path $SiteRoot -Parent) 'research\fatop\fatop-products.json'
$OrigDir  = Join-Path $SiteRoot '_media\original'
$OutDir   = Join-Path $SiteRoot 'assets\images'
# Not $Manifest: PowerShell variable names are case-insensitive, so the
# $manifest hashtable below would silently overwrite the path and WriteAllText
# would take the hashtable's ToString() as its filename.
$ManifestPath = Join-Path $SiteRoot 'src\data\images.json'

# Gallery sources are 1000x1000. Never upscale -- widths above the source are
# dropped when the derivative set is built.
$GalleryWidths = @(400, 800, 1000)

if (-not (Test-Path $Source)) { throw "Catalogue data not found: $Source" }
foreach ($d in @($OrigDir, $OutDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

. (Join-Path $PSScriptRoot 'slug.ps1')

# ---------------------------------------------------------------------------
# Collect every image, keyed by product
# ---------------------------------------------------------------------------

$products = Get-Content $Source -Raw -Encoding UTF8 | ConvertFrom-Json
$slugMap  = Resolve-ProductSlugs -Products $products

$kinds = [ordered]@{
    gallery_images = 'gallery'
    spec_images    = 'spec'
    feature_images = 'feature'
    app_images     = 'app'
}

$jobs = New-Object System.Collections.Generic.List[object]
foreach ($p in $products) {
    $slug = $slugMap[$p.slug]
    foreach ($field in $kinds.Keys) {
        $urls = $p.$field
        if (-not $urls) { continue }
        $i = 0
        foreach ($u in @($urls)) {
            if (-not $u) { continue }
            $i++
            $jobs.Add([pscustomobject]@{
                Slug  = $slug
                Model = $p.model
                Kind  = $kinds[$field]
                Index = $i
                Url   = [string]$u
                Name  = ('{0}-{1:d2}' -f $kinds[$field], $i)
            })
        }
    }
}

Write-Host ""
Write-Host ("Media pipeline: {0} images across {1} products" -f $jobs.Count, $products.Count) -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

$downloaded = 0; $skipped = 0; $failed = New-Object System.Collections.Generic.List[object]

if (-not $ConvertOnly) {
    Write-Host "Downloading originals" -ForegroundColor Yellow
    $n = 0
    foreach ($j in $jobs) {
        $n++
        $ext = [System.IO.Path]::GetExtension(([Uri]$j.Url).AbsolutePath)
        if (-not $ext) { $ext = '.jpg' }
        $dir = Join-Path $OrigDir $j.Slug
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $dest = Join-Path $dir ($j.Name + $ext)
        $j | Add-Member -NotePropertyName Original -NotePropertyValue $dest -Force

        if ((Test-Path $dest) -and (-not $Force)) { $skipped++; continue }

        try {
            Invoke-WebRequest -Uri $j.Url -OutFile $dest -UseBasicParsing -TimeoutSec 40
            $downloaded++
            if ($n % 20 -eq 0) { Write-Host ("  {0}/{1}" -f $n, $jobs.Count) -ForegroundColor DarkGray }
            Start-Sleep -Milliseconds $DelayMs
        } catch {
            $failed.Add([pscustomobject]@{ Url = $j.Url; Error = $_.Exception.Message.Split("`n")[0] })
            if (Test-Path $dest) { Remove-Item $dest -Force }
        }
    }
    Write-Host ("  downloaded {0}, already present {1}, failed {2}" -f $downloaded, $skipped, $failed.Count) -ForegroundColor DarkGray
} else {
    foreach ($j in $jobs) {
        $ext = [System.IO.Path]::GetExtension(([Uri]$j.Url).AbsolutePath)
        if (-not $ext) { $ext = '.jpg' }
        $j | Add-Member -NotePropertyName Original `
             -NotePropertyValue (Join-Path (Join-Path $OrigDir $j.Slug) ($j.Name + $ext)) -Force
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "  Failed downloads:" -ForegroundColor Red
    foreach ($f in $failed) { Write-Host ("    " + $f.Url) -ForegroundColor Red
                              Write-Host ("      " + $f.Error) -ForegroundColor DarkRed }
}

# ---------------------------------------------------------------------------
# Convert to WebP
#   gallery -> responsive set, quality 82, sharpened slightly after resize
#   spec / feature / app -> these are technical drawings and parameter tables.
#     Resizing or lossy compression would destroy legibility, so they are
#     converted at native size, near-lossless.
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Converting to WebP" -ForegroundColor Yellow

$converted = 0; $convFailed = New-Object System.Collections.Generic.List[string]
$manifest = @{}

foreach ($j in $jobs) {
    if (-not (Test-Path $j.Original)) { continue }

    $outSub = Join-Path $OutDir $j.Slug
    if (-not (Test-Path $outSub)) { New-Item -ItemType Directory -Path $outSub -Force | Out-Null }

    $srcW = 0
    try { $srcW = [int](& magick identify -format "%w" $j.Original) } catch { $srcW = 0 }
    $srcH = 0
    try { $srcH = [int](& magick identify -format "%h" $j.Original) } catch { $srcH = 0 }
    if ($srcW -le 0) { $convFailed.Add($j.Original); continue }

    $entry = [ordered]@{
        kind = $j.Kind; index = $j.Index; width = $srcW; height = $srcH; sources = @()
    }

    if ($j.Kind -eq 'gallery') {
        $widths = @($GalleryWidths | Where-Object { $_ -le $srcW })
        if ($widths.Count -eq 0) { $widths = @($srcW) }
        foreach ($w in $widths) {
            $out = Join-Path $outSub ("{0}-{1}w.webp" -f $j.Name, $w)
            & magick $j.Original -strip -resize ("{0}x" -f $w) -unsharp 0x0.6+0.6+0.01 `
                     -quality 82 -define webp:method=6 $out 2>$null
            if (Test-Path $out) {
                $entry.sources += [ordered]@{
                    width = $w
                    src   = ("/assets/images/{0}/{1}-{2}w.webp" -f $j.Slug, $j.Name, $w)
                    bytes = (Get-Item $out).Length
                }
                $converted++
            }
        }
    } else {
        $out = Join-Path $outSub ($j.Name + '.webp')
        & magick $j.Original -strip -define webp:near-lossless=60 -quality 95 `
                 -define webp:method=6 $out 2>$null
        if (Test-Path $out) {
            $entry.sources += [ordered]@{
                width = $srcW
                src   = ("/assets/images/{0}/{1}.webp" -f $j.Slug, $j.Name)
                bytes = (Get-Item $out).Length
            }
            $converted++
        }
    }

    if ($entry.sources.Count -eq 0) { $convFailed.Add($j.Original); continue }

    if (-not $manifest.ContainsKey($j.Slug)) {
        $manifest[$j.Slug] = [ordered]@{ model = $j.Model; images = @() }
    }
    $manifest[$j.Slug].images += $entry
}

Write-Host ("  wrote {0} WebP derivatives" -f $converted) -ForegroundColor DarkGray
if ($convFailed.Count -gt 0) {
    Write-Host ("  {0} images could not be converted:" -f $convFailed.Count) -ForegroundColor Red
    foreach ($f in $convFailed) { Write-Host ("    " + $f) -ForegroundColor DarkRed }
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

$json = $manifest | ConvertTo-Json -Depth 8
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ManifestPath, $json, $enc)

$origBytes = (Get-ChildItem $OrigDir -Recurse -File | Measure-Object Length -Sum).Sum
$webpBytes = (Get-ChildItem $OutDir  -Recurse -File | Measure-Object Length -Sum).Sum

Write-Host ""
Write-Host "Done" -ForegroundColor Green
Write-Host ("  products with imagery : {0}" -f $manifest.Keys.Count) -ForegroundColor DarkGray
Write-Host ("  originals             : {0:N1} MB (not committed)" -f ($origBytes / 1MB)) -ForegroundColor DarkGray
Write-Host ("  webp published        : {0:N1} MB" -f ($webpBytes / 1MB)) -ForegroundColor DarkGray
if ($origBytes -gt 0) {
    Write-Host ("  size vs originals     : {0:N0}%" -f ($webpBytes / $origBytes * 100)) -ForegroundColor DarkGray
}
Write-Host ("  manifest              : src\data\images.json") -ForegroundColor DarkGray
Write-Host ""
