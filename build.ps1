<#
  build.ps1 — static site generator for fatop-global.com

  No Node, no Python on this machine, so the generator is PowerShell 5.1 and the
  output is plain static HTML that GitHub Pages serves with no build step of its
  own. Sources live in src\, output is written to the repository root.

  Usage:
    .\build.ps1              build
    .\build.ps1 -Clean       delete previously generated output first
    .\build.ps1 -Serve       build, then serve the result on http://localhost:8080
#>
[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$Serve,
    [int]$Port = 8080
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Root    = $PSScriptRoot
$SrcDir  = Join-Path $Root 'src'
$DataDir = Join-Path $SrcDir 'data'
$TplDir  = Join-Path $SrcDir 'templates'
$OutDir  = $Root

# Everything the generator owns. -Clean removes exactly this and nothing else,
# so hand-maintained files at the root (CNAME, README) are never touched.
# assets\images is deliberately absent: those are expensive derivatives owned by
# tools\fetch-media.ps1, and -Clean must not throw away a 157-image download.
$Generated = @('index.html', 'products', 'solutions', 'turnkey', 'about',
               'support', 'contact', 'catalog', 'assets\css', 'assets\js',
               'sitemap.xml', 'robots.txt', '404.html')

# ---------------------------------------------------------------------------
# Template engine
#   {{key}}          HTML-escaped value        {{{key}}}  raw value
#   {{#each list}}...{{/each}}                 {{#if key}}...{{else}}...{{/if}}
#   Inside #each: {{.}} is the item, {{@index}} / {{@number}} the position.
#
#   Keep this file pure ASCII. The system ANSI codepage here is Big5, and in a
#   BOM-less script PowerShell 5.1 decodes non-ASCII bytes as double-byte
#   characters that swallow the following ASCII character. The file is saved
#   with a UTF-8 BOM for the same reason.
# ---------------------------------------------------------------------------

function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').
          Replace('"', '&quot;').Replace("'", '&#39;')
}

function Resolve-Path-Value {
    param($Scope, [string]$Path)
    if ($Path -eq '.') { return $Scope }
    $cur = $Scope
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [hashtable]) {
            if (-not $cur.ContainsKey($part)) { return $null }
            $cur = $cur[$part]
        } else {
            $prop = $cur.PSObject.Properties[$part]
            if ($null -eq $prop) { return $null }
            $cur = $prop.Value
        }
    }
    return $cur
}

function Test-Truthy {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) { return $Value.Length -gt 0 }
    if ($Value -is [array]) { return $Value.Count -gt 0 }
    return $true
}

function Expand-Template {
    param([string]$Template, $Scope)

    $text = $Template

    # --- {{#each}} — innermost first, so nesting resolves bottom-up ----------
    $eachRx = '\{\{#each\s+([\w.]+)\}\}((?:(?!\{\{#each\s)[\s\S])*?)\{\{/each\}\}'
    while ($text -match $eachRx) {
        $text = [regex]::Replace($text, $eachRx, {
            param($m)
            $list = Resolve-Path-Value $Scope $m.Groups[1].Value
            $body = $m.Groups[2].Value
            if ($null -eq $list) { return '' }
            if ($list -isnot [array]) { $list = @($list) }
            $sb = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $list.Count; $i++) {
                $item = $list[$i]
                # Give each item access to its position without mutating source data
                $frag = $body.Replace('{{@index}}', "$i").Replace('{{@number}}', "$($i + 1)")
                [void]$sb.Append((Expand-Template -Template $frag -Scope $item))
            }
            $sb.ToString()
        }, 1)
    }

    # --- {{#if}} / {{else}} — innermost first -------------------------------
    $ifRx = '\{\{#if\s+([\w.]+)\}\}((?:(?!\{\{#if\s)[\s\S])*?)\{\{/if\}\}'
    while ($text -match $ifRx) {
        $text = [regex]::Replace($text, $ifRx, {
            param($m)
            $val = Resolve-Path-Value $Scope $m.Groups[1].Value
            $body = $m.Groups[2].Value
            $yes = $body; $no = ''
            $split = [regex]::Match($body, '^([\s\S]*?)\{\{else\}\}([\s\S]*)$')
            if ($split.Success) { $yes = $split.Groups[1].Value; $no = $split.Groups[2].Value }
            if (Test-Truthy $val) { $yes } else { $no }
        }, 1)
    }

    # --- {{{raw}}} then {{escaped}} -----------------------------------------
    $text = [regex]::Replace($text, '\{\{\{\s*([\w.]+)\s*\}\}\}', {
        param($m)
        $v = Resolve-Path-Value $Scope $m.Groups[1].Value
        if ($null -eq $v) { '' } else { [string]$v }
    })

    $text = [regex]::Replace($text, '\{\{\s*([\w.]+|\.)\s*\}\}', {
        param($m)
        $v = Resolve-Path-Value $Scope $m.Groups[1].Value
        if ($null -eq $v) { '' } else { ConvertTo-HtmlText ([string]$v) }
    })

    return $text
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Read-Json {
    param([string]$Name)
    $path = Join-Path $DataDir $Name
    if (-not (Test-Path $path)) { throw "Missing data file: $path" }
    Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Read-Template {
    param([string]$Name)
    $path = Join-Path $TplDir $Name
    if (-not (Test-Path $path)) { throw "Missing template: $path" }
    Get-Content $path -Raw -Encoding UTF8
}

function Write-Page {
    param([string]$RelativePath, [string]$Html)
    $full = Join-Path $OutDir $RelativePath
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # UTF8 without BOM — a BOM upsets some static hosts and shows as  in <title>
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($full, $Html, $enc)
    $script:PagesWritten++
    Write-Host ("  + {0}" -f $RelativePath) -ForegroundColor DarkGray
}

function Copy-Assets {
    # css/ and js/ are authored in src/ and mirrored on every build.
    # images/ is NOT: it is written once by tools/fetch-media.ps1 straight into
    # assets/images/, so that the WebP derivatives are not stored twice in git.
    # Wiping assets/ wholesale here would delete them.
    foreach ($sub in @('css', 'js')) {
        $from = Join-Path $SrcDir ('assets\' + $sub)
        $to   = Join-Path $OutDir ('assets\' + $sub)
        if (-not (Test-Path $from)) { continue }
        if (Test-Path $to) { Remove-Item $to -Recurse -Force }
        New-Item -ItemType Directory -Path $to -Force | Out-Null
        Copy-Item (Join-Path $from '*') $to -Recurse -Force
        # @() is required: a folder holding one file yields a bare FileInfo, and
        # under Set-StrictMode reading .Count on a scalar throws.
        $n = @(Get-ChildItem $to -Recurse -File).Count
        Write-Host ("  + assets/{0}/ ({1} files)" -f $sub, $n) -ForegroundColor DarkGray
    }
    $imgDir = Join-Path $OutDir 'assets\images'
    if (Test-Path $imgDir) {
        $n = @(Get-ChildItem $imgDir -Recurse -File).Count
        Write-Host ("  = assets/images/ ({0} files, left in place)" -f $n) -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

$script:PagesWritten = 0
$started = Get-Date

Write-Host ""
Write-Host "Building fatop-global.com" -ForegroundColor Cyan
Write-Host ("  source " + $SrcDir) -ForegroundColor DarkGray
Write-Host ""

if ($Clean) {
    Write-Host "Cleaning previous output" -ForegroundColor Yellow
    foreach ($g in $Generated) {
        $p = Join-Path $OutDir $g
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Host ("  - {0}" -f $g) -ForegroundColor DarkGray }
    }
    Write-Host ""
}

$site      = Read-Json 'site.json'
$catalogue = Read-Json 'catalogue.json'
$data      = Read-Json 'products.json'

# Attach each family's cover photo and its product list, so templates can render
# a category card or a family page without doing any lookups themselves.
foreach ($f in $catalogue.families) {
    $cover = $null
    if ($data.covers.PSObject.Properties[$f.slug]) { $cover = $data.covers.($f.slug) }
    $members = @($data.products | Where-Object { $_.family -eq $f.slug })
    Add-Member -InputObject $f -NotePropertyName 'cover'    -NotePropertyValue $cover   -Force
    Add-Member -InputObject $f -NotePropertyName 'products' -NotePropertyValue $members -Force
}

$layout = Read-Template 'layout.html'

function Build-Page {
    param(
        [string]$Template,      # template file name
        [string]$Out,           # output path relative to root
        [hashtable]$Page        # page-level values: title, description, url
    )
    $scope = @{
        site     = $site
        page     = $Page
        catalog  = $catalogue
        products = $data.products
    }
    $body = Expand-Template -Template (Read-Template $Template) -Scope $scope
    $scope['content'] = $body
    $html = Expand-Template -Template $layout -Scope $scope
    Write-Page -RelativePath $Out -Html $html
}

# --- Home -------------------------------------------------------------------

# Lead with the flagship BLDC machine: it is the growth story, and it is one of
# the few products with a spec sheet, a feature image and video already.
$feature = $data.products | Where-Object { $_.model -eq 'TWM-929' } | Select-Object -First 1
if (-not $feature) { $feature = $data.products | Where-Object { $_.hero } | Select-Object -First 1 }

# Two supporting shots for the turnkey section, from different process stages so
# the pair reads as a chain rather than two views of the same machine.
$shots = @()
foreach ($m in @('TWM-308A', 'TWM-RF30S')) {
    $s = $data.products | Where-Object { $_.model -eq $m -and $_.hero } | Select-Object -First 1
    if ($s) { $shots += $s }
}
if ($shots.Count -lt 2) {
    $shots = @($data.products | Where-Object { $_.hero -and $_.slug -ne $feature.slug } | Select-Object -First 2)
}

Build-Page -Template 'home.html' -Out 'index.html' -Page @{
    title        = $site.tagline
    description  = $site.description
    url          = '/'
    nav          = 'home'
    feature      = $feature
    processShots = $shots
}

Copy-Assets

# --- robots.txt / sitemap ---------------------------------------------------
$urls = @('/')
$sitemap = New-Object System.Text.StringBuilder
[void]$sitemap.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$sitemap.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
foreach ($u in $urls) {
    [void]$sitemap.AppendLine("  <url><loc>$($site.origin)$u</loc></url>")
}
[void]$sitemap.AppendLine('</urlset>')
Write-Page -RelativePath 'sitemap.xml' -Html $sitemap.ToString()

Write-Page -RelativePath 'robots.txt' -Html @"
User-agent: *
Allow: /

Sitemap: $($site.origin)/sitemap.xml
"@

# --- Done -------------------------------------------------------------------
$elapsed = [math]::Round(((Get-Date) - $started).TotalMilliseconds)
Write-Host ""
Write-Host ("Built {0} files in {1} ms" -f $script:PagesWritten, $elapsed) -ForegroundColor Green
Write-Host ""

if ($Serve) {
    Write-Host ("Serving http://localhost:{0}/  (Ctrl+C to stop)" -f $Port) -ForegroundColor Cyan
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    $types = @{
        '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
        '.js' = 'text/javascript; charset=utf-8'; '.json' = 'application/json'
        '.svg' = 'image/svg+xml'; '.webp' = 'image/webp'; '.png' = 'image/png'
        '.jpg' = 'image/jpeg'; '.xml' = 'application/xml'; '.txt' = 'text/plain'
        '.woff2' = 'font/woff2'; '.ico' = 'image/x-icon'
    }
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
        if ($rel -eq '') { $rel = 'index.html' }
        $file = Join-Path $OutDir $rel
        if (Test-Path $file -PathType Container) { $file = Join-Path $file 'index.html' }
        if (-not (Test-Path $file)) { $file = Join-Path $OutDir '404.html' }
        if (Test-Path $file) {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $ext = [System.IO.Path]::GetExtension($file).ToLower()
            $ctx.Response.ContentType = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $ctx.Response.StatusCode = 404
        }
        $ctx.Response.Close()
    }
}
