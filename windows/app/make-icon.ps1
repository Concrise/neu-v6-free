# 画程序图标（和 mac/app/make-icon.swift 一样：蓝绿渐变圆角方块 + 白色「v6」+「免流」），存成多尺寸的 .ico。
# 用法：powershell -File make-icon.ps1 <输出.ico>。GitHub Actions 编译前运行（.github/workflows/windows-app.yml）
param([Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Png([int]$s) {
  $bmp = New-Object System.Drawing.Bitmap $s, $s
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $m = [single]($s * 0.06); $w = [single]($s - 2 * $m); $rad = [single]($s * 0.2); $d = 2 * $rad
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc($m, $m, $d, $d, 180, 90); $path.AddArc($m + $w - $d, $m, $d, $d, 270, 90)
  $path.AddArc($m + $w - $d, $m + $w - $d, $d, $d, 0, 90); $path.AddArc($m, $m + $w - $d, $d, $d, 90, 90); $path.CloseFigure()
  $rect = New-Object System.Drawing.RectangleF $m, $m, $w, $w
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(33, 107, 242)), ([System.Drawing.Color]::FromArgb(13, 189, 158)), ([single]45)
  $g.FillPath($brush, $path)
  $fmt = New-Object System.Drawing.StringFormat
  $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
  $small = $s -lt 48  # 小图标只写 v6，字大一点
  $font = New-Object System.Drawing.Font 'Segoe UI', ([single]($s * $(if ($small) { 0.5 } else { 0.4 }))), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $top = if ($small) { 0 } else { -$s * 0.07 }
  $g.DrawString('v6', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, ([single]$top), $s, $s), $fmt)
  if (-not $small) {
    $f2 = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([single]($s * 0.12)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $c = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 255, 255, 255))
    $g.DrawString('免流', $f2, $c, (New-Object System.Drawing.RectangleF 0, ([single]($s * 0.28)), $s, $s), $fmt)
  }
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  , $ms.ToArray()
}

# .ico：文件头 + 每个尺寸 16 字节的目录项 + 各尺寸的 PNG（Vista 起支持 PNG 压缩的图标）
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$pngs = @($sizes | ForEach-Object { , (Png $_) })
$fs = [System.IO.File]::Create([System.IO.Path]::GetFullPath($Out))
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $b = if ($s -ge 256) { 0 } else { $s }
  $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
  $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()
Write-Host "已生成 $Out（$($sizes -join '、') 像素）"
