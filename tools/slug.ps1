<#
  slug.ps1 -- shared slug rules, dot-sourced by fetch-media.ps1 and build-data.ps1.

  Both scripts must agree on slugs: they name the image folders on disk AND the
  public URLs. If they ever disagreed, every product page would point at images
  that are not there.

  Keep this file pure ASCII and saved with a UTF-8 BOM -- see CLAUDE.md.
#>

function ConvertTo-Slug {
    param([string]$Text)
    $s = $Text.ToLowerInvariant()
    $s = $s -replace '[^a-z0-9]+', '-'
    $s = $s -replace '(^-+|-+$)', ''
    return $s
}

function Test-UsableSlug {
    param([string]$Slug)
    if (-not $Slug) { return $false }
    # Percent-encoded or non-ASCII: one product is served from a Chinese filename.
    if ($Slug -match '%' -or $Slug -match '[^\x00-\x7F]') { return $false }
    # CMS row ids carry no meaning for a reader or a search engine.
    if ($Slug -match '^show-\d+$' -or $Slug -match '^\d+$') { return $false }
    return $true
}

<#
  Resolves the final slug for every product in one pass, so collisions can be
  settled deterministically. Returns a hashtable keyed by the ORIGINAL slug.

  Readable original slugs are kept -- they are what existing inbound links use.
  Unusable ones are rebuilt from the title, and a collision takes the model
  number as its discriminator before falling back to a counter.
#>
function Resolve-ProductSlugs {
    param($Products)

    $result = @{}
    $used   = @{}

    # Pass 1: keep the slugs that are already good.
    foreach ($p in $Products) {
        if (Test-UsableSlug $p.slug) {
            $result[$p.slug] = $p.slug
            $used[$p.slug]   = $true
        }
    }

    # Pass 2: rebuild the rest.
    foreach ($p in $Products) {
        if ($result.ContainsKey($p.slug)) { continue }

        $candidate = ConvertTo-Slug $p.title
        if (-not $candidate) { $candidate = 'machine' }

        if ($used.ContainsKey($candidate)) {
            $withModel = $candidate
            if ($p.model) { $withModel = "{0}-{1}" -f $candidate, (ConvertTo-Slug $p.model) }
            if ($withModel -ne $candidate -and -not $used.ContainsKey($withModel)) {
                $candidate = $withModel
            } else {
                $n = 2
                while ($used.ContainsKey(("{0}-{1}" -f $candidate, $n))) { $n++ }
                $candidate = "{0}-{1}" -f $candidate, $n
            }
        }

        $result[$p.slug] = $candidate
        $used[$candidate] = $true
    }

    return $result
}
