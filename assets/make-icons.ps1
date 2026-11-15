# Generates every coffee-bar icon asset with GDI+ (Windows PowerShell 5.1 or pwsh).
# Source of truth: files/design/project/Icon1.dc.html (18 px glyph grid) and MenuF.dc.html (16 px menu icons).
# Usage: powershell -File make-icons.ps1
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
$code = Split-Path -Parent $PSScriptRoot
$winDir = Join-Path $code 'windows\icons'
$macDir = Join-Path $code 'macos\CoffeeBar\Assets.xcassets'
New-Item -ItemType Directory -Force $winDir, $macDir | Out-Null

function C([string]$hex, [int]$a = 255) {
    $v = [Convert]::ToInt32($hex.TrimStart('#'), 16)
    [Drawing.Color]::FromArgb($a, ($v -shr 16) -band 255, ($v -shr 8) -band 255, $v -band 255)
}
function P($x, $y) { New-Object Drawing.PointF ([single]$x), ([single]$y) }
function Rect($x, $y, $w, $h) { New-Object Drawing.RectangleF ([single]$x), ([single]$y), ([single]$w), ([single]$h) }
function Pen($color, $w) {
    $p = New-Object Drawing.Pen $color, ([single]$w)
    $p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'; $p
}
function Brush($color) { New-Object Drawing.SolidBrush $color }

# ---- shapes in the 18 px glyph grid (SVG path data translated by hand) ----
function Path-Cup {      # M3 7.5h9.5v4a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4z
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddLine((P 3 7.5), (P 12.5 7.5)); $p.AddLine((P 12.5 7.5), (P 12.5 11.5))
    $p.AddArc((Rect 4.5 7.5 8 8), 0, 90)
    $p.AddLine((P 8.5 15.5), (P 7 15.5))
    $p.AddArc((Rect 3 7.5 8 8), 90, 90)
    $p.CloseFigure(); $p
}
function Path-Handle {   # M12.5 9h1a2.25 2.25 0 0 1 0 4.5h-1
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddLine((P 12.5 9), (P 13.5 9)); $p.AddArc((Rect 11.25 9 4.5 4.5), -90, 180); $p.AddLine((P 13.5 13.5), (P 12.5 13.5)); $p
}
function Path-Steam {    # M6.2 5.4c-.8-.75-.8-1.45 0-2.15s.8-1.4 0-2.1 (x2, second wisp at +3.2)
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    foreach ($dx in 0, 3.2) {
        $p.StartFigure()
        $x = 6.2 + $dx
        $p.AddBezier((P $x 5.4), (P ($x - .8) 4.65), (P ($x - .8) 3.95), (P $x 3.25))
        $p.AddBezier((P $x 3.25), (P ($x + .8) 2.55), (P ($x + .8) 1.85), (P $x 1.15))
    }
    $p
}

# Menu-bar / tray glyph. $g is already scaled so 18 units = canvas.
function Draw-Glyph($g, [bool]$active, $color) {
    $pen = Pen $color 1.5
    $cup = Path-Cup
    if ($active) { $g.FillPath((Brush $color), $cup) }
    $g.DrawPath($pen, $cup); $g.DrawPath($pen, (Path-Handle))
    if ($active) { $g.DrawPath($pen, (Path-Steam)) }
}

# App icon: espresso plate + cream cup. $simple drops the saucer and bolds the steam (16 px).
function Draw-App($g, [single]$offset, [single]$plate, [single]$radius, [bool]$simple) {
    $rr = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2; $e = $offset + $plate
    $rr.AddArc($offset, $offset, $d, $d, 180, 90); $rr.AddArc($e - $d, $offset, $d, $d, 270, 90)
    $rr.AddArc($e - $d, $e - $d, $d, $d, 0, 90);   $rr.AddArc($offset, $e - $d, $d, $d, 90, 90); $rr.CloseFigure()
    $grad = New-Object Drawing.Drawing2D.LinearGradientBrush (P 0 $offset), (P 0 $e), (C '#5a3a27'), (C '#2f1d15')
    $g.FillPath($grad, $rr)
    $k = $plate / 824                                   # design units: 824 px plate
    if ($simple) { $s = 34 * $k; $tx = 412 - 8.7 * 34; $ty = 412 - 8.3 * 34 } else { $s = 30 * $k; $tx = 151; $ty = 130 }
    $g.TranslateTransform($offset + $tx * $k, $offset + $ty * $k); $g.ScaleTransform($s, $s)
    $cream = C '#f4e9d8'
    if ($simple) { $steamPen = Pen $cream 1.6 } else { $steamPen = Pen (C '#f4e9d8' 191) 1.1 }
    $g.DrawPath($steamPen, (Path-Steam))
    $g.DrawPath((Pen $cream 1.5), (Path-Handle))
    $g.FillPath((Brush $cream), (Path-Cup))
    $g.FillRectangle((Brush (C '#d48a4e')), 3, 9.1, 9.5, 1.5)                        # caramel band
    if (-not $simple) { $g.DrawLine((Pen $cream 1.2), (P 1.6 17), (P 14.2 17)) }     # saucer
}

# Menu icons, 16 px design grid, stroke 1.3.
function Draw-Timer($g, $color) {
    $pen = Pen $color 1.3
    $g.DrawEllipse($pen, 2.7, 3.7, 10.6, 10.6)
    $g.DrawLine($pen, (P 8 9), (P 8 6.2)); $g.DrawLine($pen, (P 6.4 1.8), (P 9.6 1.8))
}
function Draw-Exit($g, $color) {   # door (M9.5 2.5h3a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-3) + arrow (M6 5L3 8l3 3M3 8h7.5)
    $pen = Pen $color 1.3
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddLine((P 9.5 2.5), (P 12.5 2.5)); $p.AddArc((Rect 11.5 2.5 2 2), -90, 90)
    $p.AddLine((P 13.5 4.5), (P 13.5 12.5)); $p.AddArc((Rect 11.5 11.5 2 2), 0, 90)
    $p.AddLine((P 12.5 13.5), (P 9.5 13.5)); $g.DrawPath($pen, $p)
    $g.DrawLines($pen, [Drawing.PointF[]]@((P 6 5), (P 3 8), (P 6 11))); $g.DrawLine($pen, (P 3 8), (P 10.5 8))
}

function Draw-CupSaucer($g, $color) {   # outline cup (18 grid, lifted 1.5) + saucer line, stroke 1.5
    $pen = Pen $color 1.5
    $st = $g.Save(); $g.TranslateTransform(0, -1.5); $g.DrawPath($pen, (Path-Cup)); $g.DrawPath($pen, (Path-Handle)); $g.Restore($st)
    $g.DrawLine($pen, (P 1.8 16.6), (P 14.4 16.6))
}

# ---- output helpers ----
function Render([int]$size, [scriptblock]$draw) {
    $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)
    & $draw $g
    $g.Dispose(); $bmp
}
function Save-Png($bmp, $path) { New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null; $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png) }
function Png-Bytes($bmp) { $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $ms.ToArray() }
function Save-Rgba($bmp, $path) {   # straight alpha, top-down RGBA8
    $r = New-Object Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $d = $bmp.LockBits($r, 'ReadOnly', [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $buf = New-Object byte[] ($d.Stride * $bmp.Height)
    [Runtime.InteropServices.Marshal]::Copy($d.Scan0, $buf, 0, $buf.Length); $bmp.UnlockBits($d)
    $out = New-Object byte[] ($bmp.Width * $bmp.Height * 4)
    for ($y = 0; $y -lt $bmp.Height; $y++) { for ($x = 0; $x -lt $bmp.Width; $x++) {
        $s = $y * $d.Stride + $x * 4; $o = ($y * $bmp.Width + $x) * 4
        $out[$o] = $buf[$s + 2]; $out[$o + 1] = $buf[$s + 1]; $out[$o + 2] = $buf[$s]; $out[$o + 3] = $buf[$s + 3] } }
    [IO.File]::WriteAllBytes($path, $out)
}
function Save-Both($bmp, $stem) { Save-Rgba $bmp "$stem.rgba"; Save-Png $bmp "$stem.png" }
function Write-Json($obj, $path) {
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
}

# ---- Windows tray + menu icons (32 px) ----
$themes = [ordered]@{ light = '#1a1a1a'; dark = '#ffffff' }
foreach ($theme in $themes.Keys) {
    foreach ($state in 'idle', 'active') {
        $col = C $themes[$theme]; $act = ($state -eq 'active')
        $bmp = Render 32 { param($g) $g.ScaleTransform(32 / 18, 32 / 18); Draw-Glyph $g $act $col }.GetNewClosure()
        Save-Both $bmp (Join-Path $winDir "$state-$theme")
    }
}
$grey = C '#6b6b6b'
Save-Both (Render 32 { param($g) $g.ScaleTransform(2, 2); Draw-Timer $g $grey }.GetNewClosure()) (Join-Path $winDir 'timer')
Save-Both (Render 32 { param($g) $g.ScaleTransform(2, 2); Draw-Exit $g $grey }.GetNewClosure()) (Join-Path $winDir 'exit')
Save-Both (Render 32 { param($g) $g.ScaleTransform(32 / 18, 32 / 18); Draw-CupSaucer $g $grey }.GetNewClosure()) (Join-Path $winDir 'cup')

# ---- Windows app.ico (PNG-compressed entries) ----
$sizes = 256, 48, 32, 16
$pngs = @()
foreach ($s in $sizes) {
    $simple = ($s -le 16)
    $pngs += , (Png-Bytes (Render $s { param($g) Draw-App $g 0 $s ($s * 130 / 824) $simple }.GetNewClosure()))
}
$ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($b in $pngs) { $w.Write([byte[]]$b) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $winDir 'app.ico'), $ms.ToArray())

# ---- macOS asset catalog ----
$info = @{ version = 1; author = 'xcode' }
Write-Json @{ info = $info } (Join-Path $macDir 'Contents.json')
foreach ($state in 'Idle', 'Active') {
    $set = Join-Path $macDir "Menu$state.imageset"; $imgs = @()
    $act = ($state -eq 'Active'); $black = C '#000000'
    foreach ($scale in 1, 2) {
        $suffix = ''; if ($scale -eq 2) { $suffix = '@2x' }
        $name = "menu-$($state.ToLowerInvariant())$suffix.png"
        Save-Png (Render (18 * $scale) { param($g) $g.ScaleTransform($scale, $scale); Draw-Glyph $g $act $black }.GetNewClosure()) (Join-Path $set $name)
        $imgs += @{ idiom = 'universal'; filename = $name; scale = "${scale}x" }
    }
    Write-Json @{ images = $imgs; info = $info; properties = @{ 'template-rendering-intent' = 'template' } } (Join-Path $set 'Contents.json')
}
$app = Join-Path $macDir 'AppIcon.appiconset'; $imgs = @()
foreach ($pt in 16, 32, 128, 256, 512) { foreach ($scale in 1, 2) {
    $px = $pt * $scale; $suffix = ''; if ($scale -eq 2) { $suffix = '@2x' }
    $name = "icon_${pt}x${pt}$suffix.png"
    $k = $px / 1024; $simple = ($px -le 32)    # Apple grid: 824 px plate centred on 1024, corner radius 185
    Save-Png (Render $px { param($g) Draw-App $g (100 * $k) (824 * $k) (185 * $k) $simple }.GetNewClosure()) (Join-Path $app $name)
    $imgs += @{ idiom = 'mac'; size = "${pt}x${pt}"; scale = "${scale}x"; filename = $name }
} }
Write-Json @{ images = $imgs; info = $info } (Join-Path $app 'Contents.json')
Write-Host 'icons written'
