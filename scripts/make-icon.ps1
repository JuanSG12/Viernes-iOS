# Genera el icono de la app (1024x1024): dos órbitas de cromo oscuro entrelazadas con luz naranja sobre negro.
# Uso: powershell -File scripts/make-icon.ps1
Add-Type -AssemblyName System.Drawing
$size = 1024
$bmp = New-Object System.Drawing.Bitmap $size, $size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

function Color($a, $r, $gr, $b) { [System.Drawing.Color]::FromArgb($a, $r, $gr, $b) }

# Fondo: negro con un reflejo diagonal frío y calidez abajo a la derecha.
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.Point]::new(0,0)), ([System.Drawing.Point]::new($size,$size)), (Color 255 4 4 6), (Color 255 18 19 22)
$g.FillRectangle($bg, 0, 0, $size, $size)
$c = $size / 2
$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
$gp.AddEllipse($c - 520, $c - 520, 1040, 1040)
$warm = New-Object System.Drawing.Drawing2D.PathGradientBrush $gp
$warm.CenterColor = Color 130 255 107 0
$warm.SurroundColors = @((Color 0 255 107 0))
$g.FillEllipse($warm, $c - 520, $c - 520, 1040, 1040)

function New-ChromeBrush($rx, $ry) {
    $rect = New-Object System.Drawing.RectangleF (-$rx), (-$ry), (2 * $rx), (2 * $ry)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, (Color 255 20 20 24), (Color 255 20 20 24), 35.0
    $blend = New-Object System.Drawing.Drawing2D.ColorBlend 7
    $blend.Colors = @((Color 255 14 14 17), (Color 255 120 124 132), (Color 255 245 247 250), (Color 255 70 72 80), (Color 255 12 12 15), (Color 255 255 120 20), (Color 255 14 14 17))
    $blend.Positions = @(0.0, 0.18, 0.30, 0.45, 0.62, 0.80, 1.0)
    $brush.InterpolationColors = $blend
    return $brush
}

function Draw-Ring($rx, $ry, $angle, $width, $arcStart, $arcSweep) {
    $g.ResetTransform()
    $g.TranslateTransform($c, $c)
    $g.RotateTransform($angle)
    $shadow = New-Object System.Drawing.Pen (Color 255 0 0 0), ($width + 26)
    # Los arcos parciales (mitad delantera) llevan remate plano para empalmar sin abultamientos con el anillo de debajo.
    $cap = if ($arcSweep -ge 360) { [System.Drawing.Drawing2D.LineCap]::Round } else { [System.Drawing.Drawing2D.LineCap]::Flat }
    $shadow.StartCap = $cap; $shadow.EndCap = $cap
    $brush = New-ChromeBrush $rx $ry
    $body = New-Object System.Drawing.Pen $brush, $width
    $body.StartCap = $cap; $body.EndCap = $cap
    $glint = New-Object System.Drawing.Pen (Color 150 255 255 255), ($width * 0.13)
    foreach ($pen in @($shadow, $body, $glint)) {
        if ($arcSweep -ge 360) { $g.DrawEllipse($pen, -$rx, -$ry, 2 * $rx, 2 * $ry) }
        else { $g.DrawArc($pen, -$rx, -$ry, 2 * $rx, 2 * $ry, [single]$arcStart, [single]$arcSweep) }
    }
    $shadow.Dispose(); $body.Dispose(); $glint.Dispose(); $brush.Dispose()
    $g.ResetTransform()
}

function Draw-Heat($rx, $ry, $angle, $start, $sweep) {
    $g.ResetTransform()
    $g.TranslateTransform($c, $c)
    $g.RotateTransform($angle)
    foreach ($spec in @(@(34, 70, 255, 107, 0), @(11, 255, 255, 140, 20), @(4, 255, 255, 255, 255))) {
        $pen = New-Object System.Drawing.Pen (Color $spec[1] $spec[2] $spec[3] $spec[4]), $spec[0]
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $g.DrawArc($pen, -$rx, -$ry, 2 * $rx, 2 * $ry, [single]$start, [single]$sweep)
        $pen.Dispose()
    }
    $g.ResetTransform()
}

# Órbitas entrelazadas: A completa, B completa y la mitad delantera de A encima de B.
Draw-Ring 400 190 -32 58 0 360
Draw-Ring 345 165 38 46 0 360
Draw-Ring 400 190 -32 58 0 180
Draw-Heat 400 190 -32 200 70
Draw-Heat 345 165 38 20 55

# Chispa central con destellos en cruz.
$cp = New-Object System.Drawing.Drawing2D.GraphicsPath
$cp.AddEllipse($c - 150, $c - 150, 300, 300)
$spark = New-Object System.Drawing.Drawing2D.PathGradientBrush $cp
$spark.CenterColor = Color 255 255 255 255
$spark.SurroundColors = @((Color 0 255 107 0))
$g.FillEllipse($spark, $c - 150, $c - 150, 300, 300)
foreach ($len in @(300, 170)) {
    $rot = if ($len -eq 300) { 0 } else { 45 }
    $g.ResetTransform(); $g.TranslateTransform($c, $c); $g.RotateTransform($rot)
    $fp = New-Object System.Drawing.Pen (Color 200 255 235 210), 5
    $g.DrawLine($fp, -$len, 0, $len, 0); $g.DrawLine($fp, 0, -$len, 0, $len)
    $fp.Dispose()
}
$g.ResetTransform()

$out = Join-Path $PSScriptRoot "..\App\Viernes\Assets.xcassets\AppIcon.appiconset\icon-1024.png"
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "Icono generado: $out"
