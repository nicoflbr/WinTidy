# Probe-Display.ps1 - read-only. Current display mode per monitor vs. the highest refresh rate offered.
$ErrorActionPreference = 'Continue'
$Error.Clear()
try {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WtDisp {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString; public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplayDevices(string dev, int i, ref DISPLAY_DEVICE dd, int flags);
}
'@
$res = @()
for ($i = 0; $i -lt 16; $i++) {
  $dd = New-Object WtDisp+DISPLAY_DEVICE; $dd.cb = [Runtime.InteropServices.Marshal]::SizeOf($dd)
  if (-not [WtDisp]::EnumDisplayDevices($null, $i, [ref]$dd, 0)) { break }
  if (-not ($dd.StateFlags -band 1)) { continue }   # not attached to the desktop
  $cur = New-Object WtDisp+DEVMODE; $cur.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($cur)
  [void][WtDisp]::EnumDisplaySettings($dd.DeviceName, -1, [ref]$cur)
  $modes = @(); $m = 0
  while ($true) { $dm = New-Object WtDisp+DEVMODE; $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm); if (-not [WtDisp]::EnumDisplaySettings($dd.DeviceName, $m, [ref]$dm)) { break }; $modes += [pscustomobject]@{ W = $dm.dmPelsWidth; H = $dm.dmPelsHeight; Hz = $dm.dmDisplayFrequency; Bpp = $dm.dmBitsPerPel }; $m++; if ($m -gt 5000) { break } }
  $same = $modes | Where-Object { $_.W -eq $cur.dmPelsWidth -and $_.H -eq $cur.dmPelsHeight }
  $mon = New-Object WtDisp+DISPLAY_DEVICE; $mon.cb = [Runtime.InteropServices.Marshal]::SizeOf($mon); [void][WtDisp]::EnumDisplayDevices($dd.DeviceName, 0, [ref]$mon, 0)
  $res += [pscustomobject]@{
    Output = $dd.DeviceName; Graphics = $dd.DeviceString; Monitor = $mon.DeviceString; MonitorId = $mon.DeviceID
    Current = "$($cur.dmPelsWidth)x$($cur.dmPelsHeight) @ $($cur.dmDisplayFrequency) Hz"
    MaxHzAtResolution = ($same | Measure-Object Hz -Maximum).Maximum
    MaxResolution = ($modes | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1 | ForEach-Object { "$($_.W)x$($_.H)" })
    AllHz = (($modes | Select-Object -ExpandProperty Hz -Unique | Sort-Object) -join ',')
  }
}
} catch { $failure = $_ | Out-String }
$wmi = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes | ForEach-Object { $i = $_.InstanceName; $_.MonitorSourceModes | ForEach-Object { [pscustomobject]@{ Instance = $i; W = $_.HorizontalActivePixels; H = $_.VerticalActivePixels; Hz = if ($_.VerticalRefreshRateDenominator) { [math]::Round($_.VerticalRefreshRateNumerator / $_.VerticalRefreshRateDenominator, 2) } else { 0 } } } } | Sort-Object Hz -Descending | Select-Object -First 8)
$out = [ordered]@{ Displays = $res; EdidModesTop = $wmi; Failure = $failure; Errors = @($Error | ForEach-Object { $_.ToString() + ' @ ' + $_.InvocationInfo.PositionMessage }) }
$path = Join-Path $PSScriptRoot 'probe-display.json'
$out | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
Write-Host "Done: $path" -ForegroundColor Green
