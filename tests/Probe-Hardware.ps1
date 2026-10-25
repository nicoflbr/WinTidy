# Probe-Hardware.ps1 - read-only. Checks which hardware/thermal data sources are available on this PC.
# Output: probe-hardware.json next to this script. Runs with and without admin rights.
$ErrorActionPreference = 'SilentlyContinue'
$out = [ordered]@{ Computer = $env:COMPUTERNAME; Admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); Time = (Get-Date).ToString('s') }
function Try-It($name, [scriptblock]$sb) {
    try { $r = & $sb; $out[$name] = $r } catch { $out[$name] = 'ERROR: ' + $_.Exception.Message }
}
Try-It 'Win32_Fan' { @(Get-CimInstance Win32_Fan | Select-Object Name, Status, ActiveCooling, DesiredSpeed, VariableSpeed) }
Try-It 'Win32_TemperatureProbe' { @(Get-CimInstance Win32_TemperatureProbe | Select-Object Name, CurrentReading, Status) }
Try-It 'ACPI_ThermalZone' { @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature | ForEach-Object { [pscustomobject]@{ Instance = $_.InstanceName; Celsius = [math]::Round($_.CurrentTemperature / 10 - 273.15, 1); Critical = [math]::Round($_.CriticalTripPoint / 10 - 273.15, 1) } }) }
Try-It 'PerfThermalZone' { @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation | Select-Object Name, Temperature, HighPrecisionTemperature, PercentPassiveLimit, ThrottleReasons) }
Try-It 'CPU' { Get-CimInstance Win32_Processor | Select-Object Name, MaxClockSpeed, CurrentClockSpeed, LoadPercentage, NumberOfCores, NumberOfLogicalProcessors }
Try-It 'ProcPerf' { @(Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation | Where-Object { $_.Name -eq '_Total' } | Select-Object PercentProcessorPerformance, PercentProcessorUtility, ProcessorFrequency, PercentofMaximumFrequency, PercentPerformanceLimit) }
Try-It 'PowerScheme' { (powercfg /getactivescheme) -join ' ' }
Try-It 'SysCoolPol' { (powercfg /query SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 94d3a615-a899-4ac5-ae2b-e4d8f634367f) -join "`n" }
Try-It 'ProcMinMax' { ((powercfg /query SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c) + (powercfg /query SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 bc5038f7-23e0-4960-96da-33abaf5935ec)) -join "`n" }
Try-It 'DiskReliability' { @(Get-PhysicalDisk | ForEach-Object { $d = $_; $r = $d | Get-StorageReliabilityCounter; [pscustomobject]@{ Name = $d.FriendlyName; Bus = [string]$d.BusType; Media = [string]$d.MediaType; Health = [string]$d.HealthStatus; Temp = $r.Temperature; TempMax = $r.TemperatureMax; Wear = $r.Wear; PowerOnHours = $r.PowerOnHours; ReadErr = $r.ReadErrorsTotal; WriteErr = $r.WriteErrorsTotal } }) }
Try-It 'MSStorageDriver_FailurePredictStatus' { @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus | Select-Object InstanceName, PredictFailure, Reason) }
Try-It 'Battery' { @(Get-CimInstance Win32_Battery | Select-Object Name, EstimatedChargeRemaining, DesignCapacity, FullChargeCapacity) }
Try-It 'BatteryWmi' { @(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity | Select-Object FullChargedCapacity) + @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData | Select-Object DesignedCapacity) }
Try-It 'nvidia_smi' {
    $exe = (Get-Command nvidia-smi.exe).Source
    if (-not $exe) { $p = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'; if (Test-Path $p) { $exe = $p } }
    if ($exe) { (& $exe --query-gpu=name,temperature.gpu,fan.speed,power.draw,power.limit,clocks.sm,clocks.max.sm,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,clocks_throttle_reasons.active --format=csv,noheader) -join "`n" } else { 'not present' }
}
Try-It 'LibreHWM_WMI' { @(Get-CimInstance -Namespace root\LibreHardwareMonitor -ClassName Sensor | Where-Object { $_.SensorType -in 'Fan','Temperature' } | Select-Object Name, SensorType, Value, Parent) }
Try-It 'OpenHWM_WMI' { @(Get-CimInstance -Namespace root\OpenHardwareMonitor -ClassName Sensor | Where-Object { $_.SensorType -in 'Fan','Temperature' } | Select-Object Name, SensorType, Value, Parent) }
Try-It 'HWTools' { @('LibreHardwareMonitor','OpenHardwareMonitor','HWiNFO','HWiNFO64','FanControl','PawnIO','ArmouryCrate','AsrPolychromeRGB','AsrockA-Tuning','MSI Center','NZXT CAM','iCUE','Argus Monitor','SpeedFan') | ForEach-Object { $n = $_; $hit = @(Get-ChildItem $env:ProgramFiles, ${env:ProgramFiles(x86)} -Directory -Filter "*$n*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName); $proc = @(Get-Process -Name "*$n*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique); if ($hit -or $proc) { [pscustomobject]@{ Tool = $n; Folders = $hit; Process = $proc } } } }
$since = (Get-Date).AddDays(-30)
Try-It 'Events_KernelProcessorPower' { @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; StartTime = $since } -MaxEvents 500 | Group-Object Id | Select-Object Name, Count) }
Try-It 'Events_KernelPower' { @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; StartTime = $since } -MaxEvents 500 | Group-Object Id | Select-Object Name, Count) }
Try-It 'Events_ACPI' { @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'ACPI'; StartTime = $since } -MaxEvents 200 | Group-Object Id | Select-Object Name, Count) }
Try-It 'Events_WHEA' { @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -MaxEvents 200 | Group-Object Id | Select-Object Name, Count) }
Try-It 'Events_Thermal_Sample' { @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37, 55; StartTime = $since } -MaxEvents 3 | Select-Object Id, TimeCreated, Message) }
Try-It 'RAM' { @(Get-CimInstance Win32_PhysicalMemory | Select-Object BankLabel, Capacity, Speed, ConfiguredClockSpeed, Manufacturer, PartNumber) }
Try-It 'GPU' { @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate, AdapterRAM, CurrentRefreshRate, MaxRefreshRate) }
Try-It 'Monitors' { @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes | ForEach-Object { $_.InstanceName }) }
Try-It 'Board' { Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product, Version }
Try-It 'Chassis' { (Get-CimInstance Win32_SystemEnclosure).ChassisTypes }
Try-It 'ProblemDevices' { @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } | Select-Object Name, PNPClass, ConfigManagerErrorCode, PNPDeviceID) }
$path = Join-Path $PSScriptRoot 'probe-hardware.json'
$out | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
Write-Host "Done: $path" -ForegroundColor Green
