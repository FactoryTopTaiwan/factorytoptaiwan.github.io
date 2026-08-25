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

# --- Every .ps1 here must carry a UTF-8 BOM ---------------------------------
# The system ANSI codepage on this machine is Big5. Without a BOM, PowerShell
# 5.1 decodes this file's non-ASCII bytes as double-byte characters that eat
# the following character -- and some of those bytes are inside the published
# page copy, so an em dash in a sentence silently became "??" and swallowed the
# next letter on three live pages. Editors drop BOMs; this notices immediately.
foreach ($script in (Get-ChildItem $Root -Recurse -Filter '*.ps1' -File)) {
    $head = [System.IO.File]::ReadAllBytes($script.FullName)
    if ($head.Length -lt 3 -or $head[0] -ne 0xEF -or $head[1] -ne 0xBB -or $head[2] -ne 0xBF) {
        Write-Host ""
        Write-Host ("BUILD REFUSED - no UTF-8 BOM: {0}" -f $script.FullName) -ForegroundColor Red
        Write-Host "  Re-save it as UTF-8 with BOM before building. Without one the" -ForegroundColor Yellow
        Write-Host "  Big5 codepage corrupts any non-ASCII text this script writes." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

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
               'support', 'contact', 'catalog', 'terms', 'privacy',
               'products\tag',
               'assets\css', 'assets\js', 'assets\img',
               'sitemap.xml', 'sitemap', 'robots.txt', '404.html', 'ja')

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

# ---------------------------------------------------------------------------
# Output validation
#
#   The build once shipped all 76 product pages with an empty <h1>, no machine
#   photograph and no model number, because the page scope was handed a path
#   prefix instead of the product object. Nothing caught it. The title and the
#   meta description are composed separately in this file, so they survived:
#   the pages looked correct in a search result and were blank on arrival, and
#   they reached production that way.
#
#   These checks turn that class of failure into a build failure. A page whose
#   heading is missing is a broken page even when every file on disk exists.
# ---------------------------------------------------------------------------

$script:Problems = New-Object System.Collections.Generic.List[string]

function Add-Problem {
    param([string]$Where, [string]$What)
    $script:Problems.Add(("{0} : {1}" -f $Where, $What))
}

function Test-GeneratedPage {
    param([string]$RelativePath, [string]$Html)

    # Exactly one non-empty h1. Zero means a template field resolved to nothing;
    # more than one means the document outline is wrong.
    $heads = [regex]::Matches($Html, '(?is)<h1[^>]*>(.*?)</h1>')
    if ($heads.Count -eq 0) {
        Add-Problem $RelativePath 'no <h1> on the page'
    } elseif ($heads.Count -gt 1) {
        Add-Problem $RelativePath ("{0} <h1> elements, expected 1" -f $heads.Count)
    } else {
        $bare = [regex]::Replace($heads[0].Groups[1].Value, '<[^>]+>', '').Trim()
        if (-not $bare) { Add-Problem $RelativePath '<h1> is empty' }
    }

    # A title that opens with the separator means page.title resolved to nothing.
    # The separator is an em dash, built with [char] so this file stays ASCII.
    $sep = [string][char]0x2014
    if ($Html -match ('(?is)<title>\s*[-' + $sep + ']')) {
        Add-Problem $RelativePath 'page title is empty'
    }
    if ($Html -match '(?is)<meta name="description" content="\s*">') {
        Add-Problem $RelativePath 'meta description is empty'
    }

    # A stray {{ means the template engine did not understand something.
    if ($Html.Contains('{{')) {
        Add-Problem $RelativePath 'unresolved template tag left in the output'
    }
}

function Write-Page {
    param([string]$RelativePath, [string]$Html)
    $full = Join-Path $OutDir $RelativePath
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # UTF8 without BOM — a BOM upsets some static hosts and shows as  in <title>
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($full, $Html, $enc)
    if ($RelativePath.EndsWith('.html')) { Test-GeneratedPage -RelativePath $RelativePath -Html $Html }
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
        # Do not name this $OutPfx: that is the locale output prefix further down,
        # and reusing the name here is how $prod once got overwritten with '' and
        # blanked the H1 on all 76 product pages.
        $doomed = Join-Path $OutDir $g
        if (Test-Path $doomed) { Remove-Item $doomed -Recurse -Force; Write-Host ("  - {0}" -f $g) -ForegroundColor DarkGray }
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
# culture and dateFormat are used to render the one ISO date in legal.json for
# each locale, so a Japanese page cannot end up showing an English date.
$Locales = @(
    @{ code = '';   dir = '';     url = '';    lang = 'en'
       culture = 'en-GB'; dateFormat = 'd MMMM yyyy' },
    @{ code = 'ja'; dir = 'ja\';  url = '/ja'; lang = 'ja'
       culture = 'ja-JP'; dateFormat = 'yyyy' + [char]0x5E74 + 'M' + [char]0x6708 + 'd' + [char]0x65E5 }
)

function Add-FamilyExtras {
    param($Catalogue, [string]$UrlPrefix, $Site)
    # Fallback label for the model slot on cards where the catalogue carries
    # no model number. Templates can only see the current item inside {{#each}}
    # loops (the engine does not walk parent scopes), so per-item strings are
    # baked in here.
    $byProject = ''
    if ($Site -and $Site.PSObject.Properties['ui'] -and $Site.ui.PSObject.Properties['byProject']) {
        $byProject = $Site.ui.byProject
    }
    foreach ($f in $Catalogue.families) {
        $cover = $null
        if ($data.covers.PSObject.Properties[$f.slug]) { $cover = $data.covers.($f.slug) }
        $members = @($data.products | Where-Object { $_.family -eq $f.slug } | ForEach-Object {
            $c = $_.PSObject.Copy()
            Add-Member -InputObject $c -NotePropertyName 'href' -NotePropertyValue ("{0}/products/{1}/" -f $UrlPrefix, $_.slug) -Force
            $md = if ($c.model) { $c.model } else { $byProject }
            Add-Member -InputObject $c -NotePropertyName 'modelDisplay' -NotePropertyValue $md -Force
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

Add-Member -InputObject $site -NotePropertyName 'urlPrefix'  -NotePropertyValue $loc.url  -Force
Add-Member -InputObject $site -NotePropertyName 'lang'       -NotePropertyValue $loc.lang -Force
# Stamp is derived from the app.js content hash so identical builds produce
# identical HTML, keeping the git diff clean; the stamp only changes when
# app.js does. Falls back to build-time if the file is missing.
$appJsPath = Join-Path $SrcDir 'assets/js/app.js'
$appJsStamp = if (Test-Path $appJsPath) {
    $hash = Get-FileHash -Path $appJsPath -Algorithm SHA256
    $hash.Hash.Substring(0, 10).ToLower()
} else {
    [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
}
Add-Member -InputObject $site -NotePropertyName 'buildStamp' -NotePropertyValue $appJsStamp -Force
# Decorate every product record with the display fields templates need inside
# each loops (the engine does not walk parent scope), so tag pages, siblings
# and family lists all get the same treatment as family products.
$byProjectLabel = ''
if ($site.ui.PSObject.Properties['byProject']) { $byProjectLabel = $site.ui.byProject }
foreach ($p in $data.products) {
    $md = if ($p.model) { $p.model } else { $byProjectLabel }
    if ($p.PSObject.Properties['modelDisplay']) { $p.modelDisplay = $md }
    else { Add-Member -InputObject $p -NotePropertyName 'modelDisplay' -NotePropertyValue $md -Force }
}
Add-FamilyExtras -Catalogue $catalogue -UrlPrefix $loc.url -Site $site

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

    # Regional search-term signal. Meta keywords is a weak Google signal but
    # still read by Bing, Yandex, and some Asian engines, and it also gives the
    # writer a place to see the vocabulary a page is targeting. The regions
    # are the ones the client named: US and Canada first, then SEA, India,
    # Europe. Terms are the trade terms buyers actually search in each region.
    $motorTerm = 'motor'
    if     ($prod.title -match 'Brushless|BLDC') { $motorTerm = 'BLDC motor, brushless motor, hairpin motor' }
    elseif ($prod.title -match 'Armature|Commutator|Varnish|Fusing') { $motorTerm = 'brushed motor, universal motor, DC motor, armature' }
    elseif ($prod.title -match 'Semiconductor') { $motorTerm = 'semiconductor packaging' }
    $kwParts = @()
    if ($prod.model) { $kwParts += $prod.model }
    $kwParts += $prod.title.ToLower()
    $kwParts += $motorTerm
    $kwParts += 'motor production equipment, motor manufacturing machinery'
    $kwParts += 'Taiwan manufacturer, OEM equipment supplier'
    $kwParts += 'USA, Canada, Mexico, Vietnam, India, Thailand, Germany, Italy, Turkey'
    $keywords = ($kwParts -join ', ')

    # Compose per-locale tag hrefs. The tag catalogue is in $data.products, but
    # each product carries only slugs + labels; the href needs the locale prefix.
    $tagLinks = @()
    if ($prod.tags) {
        foreach ($tg in $prod.tags) {
            $tagLinks += [pscustomobject]@{
                slug  = $tg.slug
                label = $tg.label
                kind  = $tg.kind
                href  = ("{0}/products/tag/{1}/" -f $UrlPfx, $tg.slug)
            }
        }
    }

    # Pick the copy list for this locale, so the template just uses page.desc
    # and page.spec and doesn't have to know which language it's in.
    $desc = @()
    $spec = @()
    if ($prod.copy) {
        $descKey = 'enDesc'; $specKey = 'enSpec'
        if ($loc.code -eq 'ja') {
            if ($prod.copy.PSObject.Properties['jaDesc'] -and @($prod.copy.jaDesc).Count -gt 0) { $descKey = 'jaDesc' }
            if ($prod.copy.PSObject.Properties['jaSpec'] -and @($prod.copy.jaSpec).Count -gt 0) { $specKey = 'jaSpec' }
        }
        if ($prod.copy.PSObject.Properties[$descKey]) { $desc = @($prod.copy.$descKey) }
        if ($prod.copy.PSObject.Properties[$specKey]) { $spec = @($prod.copy.$specKey) }
    }

    # Schema.org Product + BreadcrumbList. Puts the machine into Google's
    # product graph, so a Google search for the model number surfaces the
    # product knowledge panel, and lists the page in the site's breadcrumb
    # trail for rich-result sitelinks. Composed as a single JSON-LD block
    # per page - two @graph nodes rather than two script tags.
    $absUrl = ($site.origin + $UrlPfx + '/products/' + $prod.slug + '/')
    $imageAbs = if ($prod.hero) { $site.origin + $prod.hero.src } else { '' }
    $schema = [ordered]@{
        '@context' = 'https://schema.org'
        '@graph'   = @()
    }
    $product = [ordered]@{
        '@type'       = 'Product'
        '@id'         = $absUrl + '#product'
        'name'        = $t
        'description' = $summary
        'url'         = $absUrl
        'brand'       = [ordered]@{ '@type' = 'Brand'; 'name' = $site.name }
        'manufacturer' = [ordered]@{
            '@type' = 'Organization'; 'name' = $site.legalName; 'url' = $site.origin
        }
        'category'    = $(if ($prod.familyName) { $prod.familyName } else { 'Motor production equipment' })
    }
    if ($prod.model)  { $product['mpn']         = $prod.model; $product['sku'] = $prod.model }
    if ($imageAbs)    { $product['image']       = $imageAbs }
    if ($prod.video)  {
        $product['video'] = [ordered]@{
            '@type'       = 'VideoObject'
            'name'        = ($t + ' running')
            'description' = ('The ' + $t + ' filmed on the factory floor.')
            'thumbnailUrl' = $site.origin + $prod.video.poster.src
            'contentUrl'   = 'https://www.youtube.com/watch?v=' + $prod.video.youtubeId
            'embedUrl'     = 'https://www.youtube-nocookie.com/embed/' + $prod.video.youtubeId
            'uploadDate'   = '2024-01-01'
        }
    }
    $schema['@graph'] += $product

    # BreadcrumbList
    $crumbs = @(
        [ordered]@{ '@type' = 'ListItem'; 'position' = 1; 'name' = $site.ui.home;     'item' = ($site.origin + $UrlPfx + '/') },
        [ordered]@{ '@type' = 'ListItem'; 'position' = 2; 'name' = $site.ui.products; 'item' = ($site.origin + $UrlPfx + '/products/') }
    )
    if ($prod.familyName -and $prod.family) {
        $crumbs += [ordered]@{
            '@type' = 'ListItem'; 'position' = 3; 'name' = $prod.familyName
            'item' = ($site.origin + $UrlPfx + '/products/' + $prod.family + '/')
        }
        $crumbs += [ordered]@{ '@type' = 'ListItem'; 'position' = 4; 'name' = $prod.title; 'item' = $absUrl }
    } else {
        $crumbs += [ordered]@{ '@type' = 'ListItem'; 'position' = 3; 'name' = $prod.title; 'item' = $absUrl }
    }
    $schema['@graph'] += [ordered]@{
        '@type'          = 'BreadcrumbList'
        'itemListElement' = $crumbs
    }
    $schemaJson = $schema | ConvertTo-Json -Depth 10 -Compress

    Build-Page -Template 'product.html' -Out ($OutPfx + ("products\{0}\index.html" -f $prod.slug)) -Page @{
        title       = $t
        description = $summary
        keywords    = $keywords
        url         = ("{0}/products/{1}/" -f $UrlPfx, $prod.slug)
        nav         = 'products'
        product     = $prod
        siblings    = $siblings
        tagLinks    = $tagLinks
        desc        = $desc
        spec        = $spec
        schema      = $schemaJson
        copy        = @{ summary = $summary; stage = $stage; motorTypes = $motorTypes }
    }
    $urls.Add(("{0}/products/{1}/" -f $UrlPfx, $prod.slug))
}

# --- Standing pages ---------------------------------------------------------
# Copy comes from $site.pages, never from string literals here. Literals in this
# file cannot be overlaid by a locale, which is exactly how /ja/solutions/,
# /ja/support/, /ja/contact/ and /ja/catalog/ shipped in English while the rest
# of the Japanese site was translated. Headings that already live in a localised
# data file (turnkey, positioning) keep coming from there.
$c = $site.pages

$pages = @(
    @{ out='turnkey';   nav='turnkey';   title=$c.turnkey.title
       eyebrow=$catalogue.turnkey.eyebrow; heading=$catalogue.turnkey.title; lede=$catalogue.turnkey.lede
       description=$c.turnkey.description
       blocks=@(
         @{ eyebrow=$c.turnkey.scopeEyebrow;  title=$c.turnkey.scopeTitle;        bullets=$catalogue.turnkey.points },
         @{ eyebrow=$c.turnkey.onLineEyebrow; title=$company.capabilities.title;  bullets=$company.capabilities.points }
       ) },
    @{ out='solutions'; nav='solutions'; title=$c.solutions.title
       eyebrow=$c.solutions.eyebrow; heading=$c.solutions.heading
       lede=$c.solutions.lede
       description=$c.solutions.description
       industries=$company.industries },
    @{ out='about';     nav='about';     title=$c.about.title
       eyebrow=$c.about.eyebrow; heading=$company.positioning.line; lede=$company.positioning.summary
       description=$c.about.description
       timeline=$company.timeline
       blocks=@( @{ eyebrow=$c.about.howEyebrow; title=$c.about.howTitle; items=$company.services } ) },
    @{ out='support';   nav='support';   title=$c.support.title
       eyebrow=$c.support.eyebrow; heading=$c.support.heading
       lede=$c.support.lede
       description=$c.support.description
       blocks=@( @{ eyebrow=$c.support.blockEyebrow; title=$c.support.blockTitle; bullets=$company.capabilities.points } )
       showContact=$true },
    @{ out='contact';   nav='contact';   title=$c.contact.title
       eyebrow=$c.contact.eyebrow; heading=$c.contact.heading
       lede=$c.contact.lede
       description=$c.contact.description
       showContact=$true },
    @{ out='catalog';   nav='catalog';   title=$c.catalog.title
       eyebrow=$c.catalog.eyebrow; heading=$c.catalog.heading
       lede=$c.catalog.lede
       description=$c.catalog.description
       showContact=$true }
)

foreach ($pg in $pages) {
    $pgData = @{} + $pg
    $pgData['url'] = ("{0}/{1}/" -f $UrlPfx, $pg.out)
    Build-Page -Template 'page.html' -Out ($OutPfx + ("{0}\index.html" -f $pg.out)) -Page $pgData
    $urls.Add(("{0}/{1}/" -f $UrlPfx, $pg.out))
}

# --- One page per tag -------------------------------------------------------
# A tag is a cross-cut through the catalogue. A single machine can appear on
# several tag pages without splitting its own URL, and adding a tag is a data
# change with no template edit.
$tagIndex = @{}
foreach ($prod in $data.products) {
    if (-not $prod.tags) { continue }
    foreach ($tg in $prod.tags) {
        if (-not $tagIndex.ContainsKey($tg.slug)) {
            $tagIndex[$tg.slug] = [pscustomobject]@{
                slug = $tg.slug; label = $tg.label; kind = $tg.kind
                products = New-Object System.Collections.Generic.List[object]
            }
        }
        $c = $prod.PSObject.Copy()
        Add-Member -InputObject $c -NotePropertyName 'href' -NotePropertyValue ("{0}/products/{1}/" -f $UrlPfx, $prod.slug) -Force
        $tagIndex[$tg.slug].products.Add($c)
    }
}

foreach ($tagSlug in $tagIndex.Keys) {
    $t = $tagIndex[$tagSlug]
    # .ToArray() on a Generic.List[object], never @(): the array subexpression
    # operator throws "Argument types do not match" on that type in PS 5.1.
    $prodsArr = $t.products.ToArray()
    $count = $prodsArr.Count
    $tagObj = [pscustomobject]@{
        slug = $t.slug; label = $t.label; kind = $t.kind; products = $prodsArr
    }
    $title = ("{0} - {1} {2}" -f $t.label, $count, $site.ui.machines)
    $desc  = ("{0} equipment from the Teamwork Automation catalogue: {1} {2} tagged {3}." -f $t.label, $count, $site.ui.machines, $t.label)
    Build-Page -Template 'tag.html' -Out ($OutPfx + ("products\tag\{0}\index.html" -f $tagSlug)) -Page @{
        title       = $title
        description = $desc
        url         = ("{0}/products/tag/{1}/" -f $UrlPfx, $tagSlug)
        nav         = 'products'
        tag         = $tagObj
    }
    $urls.Add(("{0}/products/tag/{1}/" -f $UrlPfx, $tagSlug))
}

# --- Terms of use and privacy policy ----------------------------------------
# Kept out of $pages because they are neither a marketing page nor a bullet
# list: each is a set of headed clauses, and a reader arrives looking for one
# of them rather than reading top to bottom.
$legal = Read-LocaleJson 'legal.json' $loc.code

$stamp = [datetime]::ParseExact($legal.lastUpdated, 'yyyy-MM-dd', $null)
$stampText = $stamp.ToString($loc.dateFormat, [Globalization.CultureInfo]::GetCultureInfo($loc.culture))

foreach ($doc in @(
    @{ out = 'terms';   key = 'terms';   nav = 'terms'   },
    @{ out = 'privacy'; key = 'privacy'; nav = 'privacy' }
)) {
    $body = $legal.PSObject.Properties[$doc.key].Value

    # A locale with no translated legal text falls through to the English, which
    # is correct but must not be silent: the reader is told which version applies.
    $notice = ''
    if ($loc.code -and -not (Test-Path (Join-Path $DataDir ("{0}\legal.json" -f $loc.code)))) {
        $notice = $site.ui.legalInEnglish
    }

    Build-Page -Template 'legal.html' -Out ($OutPfx + ("{0}\index.html" -f $doc.out)) -Page @{
        title             = $body.heading
        description       = $body.lede
        url               = ("{0}/{1}/" -f $UrlPfx, $doc.out)
        nav               = $doc.nav
        doc               = $body
        lastUpdated       = $stampText
        lastUpdatedISO    = $legal.lastUpdated
        updatedLabel      = $site.ui.lastUpdated
        translationNotice = $notice
    }
    $urls.Add(("{0}/{1}/" -f $UrlPfx, $doc.out))
}

# --- Search index -----------------------------------------------------------
# One small JSON per locale, fetched the first time the reader opens search and
# then cached by the browser. A static host cannot run a query, and a buyer who
# knows the model number should not have to guess which family it sits in.
#
# Fields are one letter because this file is downloaded, not read:
#   t title   m model   f family   u url   k extra keywords
$index = New-Object System.Collections.Generic.List[object]

foreach ($fam in $catalogue.families) {
    $index.Add([pscustomobject]@{
        t = $fam.name
        m = ''
        f = $site.ui.family
        u = ("{0}/products/{1}/" -f $UrlPfx, $fam.slug)
        k = $fam.summary
    })
}

foreach ($item in $data.products) {
    $famName = ''
    if ($item.familyName) { $famName = $item.familyName }
    # Include tag labels as extra keywords so a search for "BLDC" or
    # "wedge insertion" reaches every machine tagged that way.
    $keys = @()
    if ($item.tags) { foreach ($tg in $item.tags) { $keys += $tg.label } }
    $index.Add([pscustomobject]@{
        t = $item.title
        m = $(if ($item.model) { $item.model } else { '' })
        f = $famName
        u = ("{0}/products/{1}/" -f $UrlPfx, $item.slug)
        k = ($keys -join ' ')
    })
}

# Tag pages are themselves searchable landing pages.
foreach ($tagSlug in $tagIndex.Keys) {
    $t = $tagIndex[$tagSlug]
    $index.Add([pscustomobject]@{
        t = $t.label; m = ''; f = $site.ui.tag
        u = ("{0}/products/tag/{1}/" -f $UrlPfx, $tagSlug); k = ''
    })
}

# The standing pages, so search reaches the whole site and not only machines.
$standing = New-Object System.Collections.Generic.List[object]
$standing.Add([pscustomobject]@{ t = $site.ui.everyMachine; u = "$UrlPfx/products/" })
foreach ($pg in $pages) {
    $standing.Add([pscustomobject]@{ t = $pg.title; u = ("{0}/{1}/" -f $UrlPfx, $pg.out) })
}
$standing.Add([pscustomobject]@{ t = $legal.terms.heading;   u = "$UrlPfx/terms/" })
$standing.Add([pscustomobject]@{ t = $legal.privacy.heading; u = "$UrlPfx/privacy/" })
$standing.Add([pscustomobject]@{ t = $site.ui.sitemapHeading; u = "$UrlPfx/sitemap/" })

foreach ($pg in $standing) {
    $index.Add([pscustomobject]@{ t = $pg.t; m = ''; f = $site.ui.company; u = $pg.u; k = '' })
}

# .ToArray(), never @(): @() throws ArgumentException on a Generic.List[object].
Write-Page -RelativePath ($OutPfx + 'search.json') `
           -Html ($index.ToArray() | ConvertTo-Json -Depth 3 -Compress)

# --- Human sitemap ----------------------------------------------------------
# Distinct from sitemap.xml: that one is for crawlers, this one is for a buyer
# who knows the model number and would rather not go through the filters.
Build-Page -Template 'sitemap.html' -Out ($OutPfx + "sitemap\index.html") -Page @{
    title       = $site.ui.sitemapHeading
    description = $site.ui.sitemapLede
    url         = "$UrlPfx/sitemap/"
    nav         = 'sitemap'
}
$urls.Add("$UrlPfx/sitemap/")

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

# --- Check the generated output ---------------------------------------------
#   A homepage advertising pages that do not exist shipped once. Every internal
#   link and every asset reference is resolved against the filesystem here, so
#   that cannot leave this machine again. Local preview is not a substitute:
#   GitHub Pages has rules the preview server does not, but a link to a file
#   that was never written is broken in both.

Write-Host "Checking the generated output" -ForegroundColor Cyan

$SkipDirs = @('\src\', '\_media\', '\.git\', '\tools\')
$Built = @(Get-ChildItem $OutDir -Recurse -Filter '*.html' -File | Where-Object {
    $keep = $true
    foreach ($skip in $SkipDirs) { if ($_.FullName -like ('*' + $skip + '*')) { $keep = $false } }
    $keep
})

$targets = 0
$checked = 0
foreach ($file in $Built) {
    $rel  = $file.FullName.Substring($OutDir.Length).TrimStart('\')
    $html = [System.IO.File]::ReadAllText($file.FullName)

    foreach ($ref in [regex]::Matches($html, '(?:src|href)="(/[^"]*)"')) {
        $targets++
        # Strip the fragment and the query: neither reaches the filesystem.
        $path = $ref.Groups[1].Value -replace '[#?].*$', ''
        if (-not $path) { continue }
        $checked++
        $onDisk = Join-Path $OutDir ($path.TrimStart('/').Replace('/', '\'))
        if (Test-Path $onDisk -PathType Container) { $onDisk = Join-Path $onDisk 'index.html' }
        if (-not (Test-Path $onDisk)) { Add-Problem $rel ("link goes nowhere: " + $path) }
    }
}

# Every page must be in sitemap.xml. The standing rule is that a new page
# reaches both sitemaps automatically, so a miss here is a generator bug.
$declared = @{}
foreach ($u in $urls) { $declared[$u] = $true }
foreach ($file in $Built) {
    $rel = $file.FullName.Substring($OutDir.Length).TrimStart('\')
    if ($rel -eq '404.html' -or $rel.EndsWith('\404.html')) { continue }
    $asUrl = '/' + $rel.Replace('\', '/')
    $asUrl = $asUrl -replace 'index\.html$', ''
    if (-not $declared.ContainsKey($asUrl)) { Add-Problem $rel ("missing from sitemap.xml: " + $asUrl) }
}

Write-Host ("  {0} pages, {1} internal references resolved" -f $Built.Count, $checked) -ForegroundColor DarkGray

if ($script:Problems.Count -gt 0) {
    Write-Host ""
    Write-Host ("BUILD FAILED - {0} problem(s) in the generated output:" -f $script:Problems.Count) -ForegroundColor Red
    foreach ($problem in $script:Problems) { Write-Host ("  ! " + $problem) -ForegroundColor Red }
    Write-Host ""
    Write-Host "  The files were written, so you can inspect them, but this output" -ForegroundColor Yellow
    Write-Host "  must not be committed or pushed until these are fixed." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# --- Done -------------------------------------------------------------------
$elapsed = [math]::Round(((Get-Date) - $started).TotalMilliseconds)
Write-Host ""
Write-Host ("Built {0} files in {1} ms, output checked clean" -f $script:PagesWritten, $elapsed) -ForegroundColor Green
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
            $ctx.Response.Headers.Add('Cache-Control', 'no-store, must-revalidate')
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $ctx.Response.StatusCode = 404
        }
        $ctx.Response.Close()
    }
}
