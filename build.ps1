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
# CNAME is hand-maintained and absent from this list on purpose: deleting it
# would drop the custom domain and take fatop-global.com offline.
# assets\images is deliberately absent: those are expensive derivatives owned by
# tools\fetch-media.ps1, and -Clean must not throw away a 157-image download.
$Generated = @('index.html', 'products', 'solutions', 'turnkey', 'about',
               'support', 'contact', 'catalog', 'assets\css', 'assets\js', 'assets\img',
               'sitemap.xml', 'robots.txt', '404.html', 'ja')

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
    foreach ($sub in @('css', 'js', 'img')) {
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
        $OutPfx = Join-Path $OutDir $g
        if (Test-Path $OutPfx) { Remove-Item $OutPfx -Recurse -Force; Write-Host ("  - {0}" -f $g) -ForegroundColor DarkGray }
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Locales
#   English is the primary language and carries the marketing. Other locales
#   exist so buyers see them, and their only job is to be exactly right, so a
#   locale overlays only the files it actually translates -- anything it does
#   not provide falls through to English rather than being machine-filled.
# ---------------------------------------------------------------------------

function Read-LocaleJson {
    param([string]$Name, [string]$Locale)
    $base = Read-Json $Name
    if (-not $Locale) { return $base }
    $path = Join-Path $DataDir ("{0}\{1}" -f $Locale, $Name)
    if (-not (Test-Path $path)) { return $base }
    $over = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    # Shallow overlay: a translated key wins, an absent one keeps the English.
    foreach ($ovProp in $over.PSObject.Properties) {
        Add-Member -InputObject $base -NotePropertyName $ovProp.Name -NotePropertyValue $ovProp.Value -Force
    }
    return $base
}

$data    = Read-Json 'products.json'
$company = Read-Json 'company.json'

# Locale code, output folder, url prefix. Empty code is English at the root.
$Locales = @(
    @{ code = '';   dir = '';     url = '';    lang = 'en' },
    @{ code = 'ja'; dir = 'ja\';  url = '/ja'; lang = 'ja' }
)

function Add-FamilyExtras {
    param($Catalogue, [string]$UrlPrefix)
    foreach ($f in $Catalogue.families) {
        $cover = $null
        if ($data.covers.PSObject.Properties[$f.slug]) { $cover = $data.covers.($f.slug) }
        $members = @($data.products | Where-Object { $_.family -eq $f.slug } | ForEach-Object {
            $c = $_.PSObject.Copy()
            Add-Member -InputObject $c -NotePropertyName 'href' -NotePropertyValue ("{0}/products/{1}/" -f $UrlPrefix, $_.slug) -Force
            $c
        })
        Add-Member -InputObject $f -NotePropertyName 'cover'    -NotePropertyValue $cover   -Force
        Add-Member -InputObject $f -NotePropertyName 'products' -NotePropertyValue $members -Force
        Add-Member -InputObject $f -NotePropertyName 'href'     -NotePropertyValue ("{0}/products/{1}/" -f $UrlPrefix, $f.slug) -Force
    }
}

$layout = Read-Template 'layout.html'

function Build-Page {
    param(
        [string]$Template,      # template file name
        [string]$Out,           # output path relative to root
        [hashtable]$Page        # page-level values: title, description, url
    )
    # Point each language at the SAME page in that locale, not at its home page.
    # Switching language must not cost the reader their place -- landing back on
    # the home page reads as "the switch did not work".
    $here = [string]$Page['url']
    $langs = @()
    foreach ($l in $site.languages) {
        $href = $l.href
        if (-not $l.external) {
            $bare = $here
            foreach ($other in $Locales) {
                if ($other.url -and $bare.StartsWith($other.url + '/')) {
                    $bare = $bare.Substring($other.url.Length); break
                }
                if ($other.url -and $bare -eq ($other.url + '/')) { $bare = '/'; break }
            }
            $target = $l.code
            $pfx = ''
            foreach ($other in $Locales) { if ($other.lang -eq $target) { $pfx = $other.url } }
            $href = $pfx + $bare
            if (-not $href) { $href = '/' }
        }
        $langs += [pscustomobject]@{
            code = $l.code; label = $l.label; href = $href
            current = $l.current; external = $l.external
        }
    }
    $localSite = $site.PSObject.Copy()
    Add-Member -InputObject $localSite -NotePropertyName 'languages' -NotePropertyValue $langs -Force

    $scope = @{
        site     = $localSite
        page     = $Page
        catalog  = $catalogue
        company  = $company
        products = $data.products
    }
    $body = Expand-Template -Template (Read-Template $Template) -Scope $scope
    $scope['content'] = $body
    $html = Expand-Template -Template $layout -Scope $scope
    Write-Page -RelativePath $Out -Html $html
}

$urls = New-Object System.Collections.Generic.List[string]

foreach ($loc in $Locales) {

$site      = Read-LocaleJson 'site.json'      $loc.code
$catalogue = Read-LocaleJson 'catalogue.json' $loc.code
$company   = Read-LocaleJson 'company.json'   $loc.code

Add-Member -InputObject $site -NotePropertyName 'urlPrefix' -NotePropertyValue $loc.url  -Force
Add-Member -InputObject $site -NotePropertyName 'lang'      -NotePropertyValue $loc.lang -Force
Add-FamilyExtras -Catalogue $catalogue -UrlPrefix $loc.url

$OutPfx = $loc.dir   # output folder prefix
$UrlPfx = $loc.url   # url prefix

Write-Host ("  [{0}]" -f $(if ($loc.code) { $loc.code } else { 'en' })) -ForegroundColor Cyan

$urls.Add("$UrlPfx/")

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

Build-Page -Template 'home.html' -Out ($OutPfx + 'index.html') -Page @{
    title        = $site.tagline
    description  = $site.description
    url          = '/'
    nav          = 'home'
    feature      = $feature
    processShots = $shots
}


# --- Catalogue index --------------------------------------------------------
Build-Page -Template 'products.html' -Out ($OutPfx + 'products\index.html') -Page @{
    title       = ("All {0} machines for motor production" -f $catalogue.totals.products)
    description = ("The complete Teamwork Automation catalogue: {0} machines across {1} families, covering winding, slot insulation, wedge insertion, fusing, turning, balancing and test." -f $catalogue.totals.products, $catalogue.totals.families)
    url         = "$UrlPfx/products/"
    nav         = 'products'
}
$urls.Add("$UrlPfx/products/")

# --- One page per family ----------------------------------------------------
foreach ($f in $catalogue.families) {
    Build-Page -Template 'family.html' -Out ($OutPfx + ("products\{0}\index.html" -f $f.slug)) -Page @{
        title       = $f.name
        description = $f.summary
        url         = ("{0}/products/{1}/" -f $UrlPfx, $f.slug)
        nav         = 'products'
        family      = $f
    }
    $urls.Add(("{0}/products/{1}/" -f $UrlPfx, $f.slug))
}

# --- One page per machine ---------------------------------------------------
foreach ($prod in $data.products) {
    # Siblings from the same family give the buyer somewhere to go when this
    # machine is close but not right.
    $siblings = @($data.products |
        Where-Object { $_.family -eq $prod.family -and $_.slug -ne $prod.slug } |
        Select-Object -First 3)

    $stage = $site.ui.processStage
    if ($prod.familyName) { $stage = $prod.familyName
    foreach ($fam in $catalogue.families) { if ($fam.slug -eq $prod.family) { $stage = $fam.name } } }

    $motorTypes = $site.ui.motorsAll
    if ($prod.title -match 'Brushless|BLDC')      { $motorTypes = $site.ui.motorsBldc }
    elseif ($prod.title -match 'Armature|Commutator|Varnish') { $motorTypes = $site.ui.motorsBrushed }
    elseif ($prod.title -match 'Semiconductor')   { $motorTypes = $site.ui.motorsSemi }

    $summary = ("{0} built by Teamwork Automation in Taichung, Taiwan. Supplied as a standalone machine or integrated into a complete production line." -f $prod.title)
    if ($prod.model) {
        $summary = ("{0} is a {1} built by Teamwork Automation in Taichung, Taiwan. Supplied as a standalone machine or integrated into a complete production line." -f $prod.model, $prod.title.ToLowerInvariant())
    }

    $t = $prod.title
    if ($prod.model) { $t = ("{0} {1}" -f $prod.model, $prod.title) }

    Build-Page -Template 'product.html' -Out ($OutPfx + ("products\{0}\index.html" -f $prod.slug)) -Page @{
        title       = $t
        description = $summary
        url         = ("{0}/products/{1}/" -f $UrlPfx, $prod.slug)
        nav         = 'products'
        product     = $OutPfx
        siblings    = $siblings
        copy        = @{ summary = $summary; stage = $stage; motorTypes = $motorTypes }
    }
    $urls.Add(("{0}/products/{1}/" -f $UrlPfx, $prod.slug))
}

# --- Standing pages ---------------------------------------------------------
$pages = @(
    @{ out='turnkey';   nav='turnkey';   title='Turnkey production lines';
       eyebrow=$catalogue.turnkey.eyebrow; heading=$catalogue.turnkey.title; lede=$catalogue.turnkey.lede
       description='Complete motor production lines planned, built and commissioned by one supplier — layout, workstation count, traceability and remote monitoring included.'
       blocks=@(
         @{ eyebrow='Scope'; title='What is included'; bullets=$catalogue.turnkey.points },
         @{ eyebrow='On the line'; title=$company.capabilities.title; bullets=$company.capabilities.points }
       ) },
    @{ out='solutions'; nav='solutions'; title='Industries we build for';
       eyebrow='Solutions'; heading='The motors our machines are built around'
       lede='Automotive, two-wheel and e-mobility, power tools, drone and micro BLDC, appliance, and semiconductor packaging. The machine is specified against the part, so the industry decides the tooling.'
       description='Motor production equipment for automotive, e-mobility, power tools, drone motors, appliances and semiconductor packaging.'
       industries=$company.industries },
    @{ out='about';     nav='about';     title='About Teamwork Automation';
       eyebrow='About'; heading=$company.positioning.line; lede=$company.positioning.summary
       description='Teamwork Automation has built motor production equipment in Taichung, Taiwan since 1992, and has guided more than twenty listed manufacturers through new plant launches.'
       timeline=$company.timeline
       blocks=@( @{ eyebrow='How we work'; title='Five ways a project reaches us'; items=$company.services } ) },
    @{ out='support';   nav='support';   title='Support and service';
       eyebrow='Support'; heading='Repair without borders.'
       lede='Any machine with a PLC can carry the remote monitoring module. When something stops, an engineer connects over the internet and diagnoses it — a fault eight thousand kilometres away does not have to wait for a flight to be booked.'
       description='Remote diagnostics, installation, operator training and spare parts for Teamwork Automation motor production equipment.'
       blocks=@( @{ eyebrow='On the line'; title='What the monitoring module gives you'; bullets=$company.capabilities.points } )
       showContact=$true },
    @{ out='contact';   nav='contact';   title='Contact and quotations';
       eyebrow='Contact'; heading='Tell us the part. We will tell you the line.'
       lede='Send the stator, armature or rotor you need to produce, along with the output you are planning for. Specifications are never gated and there is no account to create.'
       description='Request a quotation, ask for a specification, or book a video call with the Teamwork Automation engineering team in Taichung, Taiwan.'
       showContact=$true },
    @{ out='catalog';   nav='catalog';   title='Catalogue downloads';
       eyebrow='Catalogue'; heading='The full catalogue, on request'
       lede='Machine specifications on this site are open — nothing behind a form. The complete printed catalogue is available on request so we know who to follow up with.'
       description='Request the full Teamwork Automation machine catalogue.'
       showContact=$true }
)

foreach ($pg in $pages) {
    $pgData = @{} + $pg
    $pgData['url'] = ("{0}/{1}/" -f $UrlPfx, $pg.out)
    Build-Page -Template 'page.html' -Out ($OutPfx + ("{0}\index.html" -f $pg.out)) -Page $pgData
    $urls.Add(("{0}/{1}/" -f $UrlPfx, $pg.out))
}

# --- 404 --------------------------------------------------------------------
Build-Page -Template 'page.html' -Out ($OutPfx + '404.html') -Page @{
    title       = 'Page not found'
    description = 'That page does not exist.'
    url         = "$UrlPfx/404.html"
    eyebrow     = '404'
    heading     = 'That page is not here.'
    lede        = 'The link may be out of date, or the page may have moved during the site rebuild. The full machine catalogue is the best place to pick the thread back up.'
}

} # end locale loop

Copy-Assets

# --- robots.txt / sitemap ---------------------------------------------------
$sitemap = New-Object System.Text.StringBuilder
[void]$sitemap.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$sitemap.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
foreach ($UrlPfx in $urls) {
    [void]$sitemap.AppendLine("  <url><loc>$($site.origin)$UrlPfx</loc></url>")
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
