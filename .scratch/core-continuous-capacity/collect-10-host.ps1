$ErrorActionPreference = 'Stop'
$ccRoot = 'D:\github\Ringwin-core-continuous-capacity'
$ccResult = [ordered]@{
    observed_utc = (Get-Date).ToUniversalTime().ToString('o')
    scope = 'read-only native Windows host metadata; functional file evidence only'
    workspace = $ccRoot
    platform_performance_qualified = $false
    production_qualified = $false
}
try { $ccResult.os = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture } catch { $ccResult.os_error = $_.Exception.Message }
try { $ccResult.cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed) } catch { $ccResult.cpu_error = $_.Exception.Message }
try { $ccResult.memory = Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, TotalPhysicalMemory, HypervisorPresent } catch { $ccResult.memory_error = $_.Exception.Message }
try { $ccResult.volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'" | Select-Object DeviceID, DriveType, FileSystem, Size, FreeSpace } catch { $ccResult.volume_error = $_.Exception.Message }
try {
    $ccPartition = Get-Partition -DriveLetter D
    $ccResult.partition = $ccPartition | Select-Object DiskNumber, PartitionNumber, Type, Size, Offset
    $ccResult.disk = Get-Disk -Number $ccPartition.DiskNumber | Select-Object Number, FriendlyName, BusType, PartitionStyle, LogicalSectorSize, PhysicalSectorSize, Size
    $ccResult.device = Get-CimInstance Win32_DiskDrive -Filter "Index=$($ccPartition.DiskNumber)" | Select-Object Index, Model, InterfaceType, FirmwareRevision, Size, BytesPerSector
} catch { $ccResult.device_error = $_.Exception.Message }
$ccResult.drivers = @()
foreach ($ccName in @('ntfs.sys', 'disk.sys', 'volmgr.sys')) {
    $ccDriver = Join-Path $env:SystemRoot ('System32\drivers\' + $ccName)
    try {
        $ccInfo = Get-Item -LiteralPath $ccDriver
        $ccResult.drivers += [ordered]@{ name = $ccName; file_version = $ccInfo.VersionInfo.FileVersion; bytes = $ccInfo.Length }
    } catch { $ccResult.drivers += [ordered]@{ name = $ccName; error = $_.Exception.Message } }
}
try {
    $ccIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $ccPrincipal = [Security.Principal.WindowsPrincipal]::new($ccIdentity)
    $ccResult.process_permissions = [ordered]@{ elevated_administrator = $ccPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); identity_names_and_sids = 'not_collected' }
} catch { $ccResult.process_permissions_error = $_.Exception.Message }
$ccResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ccRoot '.scratch\core-continuous-capacity\10-windows-host.json') -Encoding utf8
Write-Output '10-windows-host.json captured read-only OS/filesystem/device/driver/permission metadata'
