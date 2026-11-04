# Genera el icono de la app (1024x1024): núcleo holográfico de anillos cian sobre azul profundo.
# Uso: powershell -File scripts/make-icon.ps1
Add-Type -AssemblyName System.Drawing
$size = 1024
$bmp = New-Object System.Drawing.Bitmap $size, $size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.Point]::new(0,0)), ([System.Drawing.Point]::new(0,$size)), ([System.Drawing.Color]::FromArgb(255,2,6,15)), ([System.Drawing.Color]::FromArgb(255,4,28,60))
$g.FillRectangle($bg, 0, 0, $size, $size)

$c = $size / 2
# Halo
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddEllipse($c - 430, $c - 430, 860, 860)
$halo = New-Object System.Drawing.Drawing2D.PathGradientBrush $path
$halo.CenterColor = [System.Drawing.Color]::FromArgb(150, 0, 229, 255)
$halo.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 0, 229, 255))
$g.FillEllipse($halo, $c - 430, $c - 430, 860, 860)

# Anillos segmentados
$rings = @(@(400, 5, 72, 0.5), @(335, 12, 6, 0.62), @(270, 5, 40, 0.4), @(205, 16, 3, 0.55))
$idx = 0
foreach ($r in $rings) {
    $radius = $r[0]; $w = $r[1]; $segs = $r[2]; $dash = $r[3]
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 0, 229, 255)), $w
    $step = 360.0 / $segs
    $offset = 13 * ($idx + 1)
    for ($i = 0; $i -lt $segs; $i++) {
        $g.DrawArc($pen, $c - $radius, $c - $radius, 2 * $radius, 2 * $radius, [single]($offset + $i * $step), [single]($step * $dash))
    }
    $idx++
}

# Núcleo
$cp = New-Object System.Drawing.Drawing2D.GraphicsPath
$cp.AddEllipse($c - 120, $c - 120, 240, 240)
$core = New-Object System.Drawing.Drawing2D.PathGradientBrush $cp
$core.CenterColor = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
$core.SurroundColors = @([System.Drawing.Color]::FromArgb(40, 0, 229, 255))
$g.FillEllipse($core, $c - 120, $c - 120, 240, 240)

$out = Join-Path $PSScriptRoot "..\App\Viernes\Assets.xcassets\AppIcon.appiconset\icon-1024.png"
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "Icono generado: $out"
