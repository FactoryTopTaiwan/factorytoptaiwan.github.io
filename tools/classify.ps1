<#
  classify.ps1 -- tells an equipment photo from a workpiece photo.

  This company builds automation equipment. It does not build motors. The old
  catalogue leant heavily on photographs of the parts its machines produce --
  stators, rotors, armatures, coils -- which reads to a procurement engineer as
  "motor manufacturer", exactly the wrong signal. Only 35 of 163 catalogue
  photographs actually show a machine.

  The two kinds are shot completely differently: workpieces are studio cutouts
  on pure white, equipment is photographed in the factory against a busy
  background. Thresholding at 94% and taking the mean separates them cleanly --
  measured across the real catalogue, workpieces land at 0.48-0.63 and equipment
  at 0.02.

  Keep this file pure ASCII and saved with a UTF-8 BOM -- see CLAUDE.md.
#>

# Above this fraction of near-white pixels, treat the photo as a studio cutout.
$script:WorkpieceThreshold = 0.25

function Get-WhiteFraction {
    param([string]$Path)
    try {
        $v = & magick $Path -colorspace sRGB -threshold 94% -format "%[fx:mean]" info: 2>$null
        if ($null -eq $v -or $v -eq '') { return -1 }
        return [double]$v
    } catch {
        return -1
    }
}

<#
  Returns 'equipment', 'workpiece', or 'unknown' when the image cannot be read.
#>
function Get-PhotoKind {
    param([string]$Path)
    $w = Get-WhiteFraction -Path $Path
    if ($w -lt 0) { return 'unknown' }
    if ($w -ge $script:WorkpieceThreshold) { return 'workpiece' }
    return 'equipment'
}
