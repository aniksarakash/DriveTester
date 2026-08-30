<#
    Inventory.ps1 - what is actually attached, and what the bus claims about it.

    Everything here is read-only and works without elevation. Where a CIM class
    needs admin (Get-StorageReliabilityCounter, MSStorageDriver_*), the caller
    handles the gap - this file never fails a run because a class is missing.
#>

function Get-CimSafe {
    <# CIM query that returns @() instead of throwing. #>
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [string]$Namespace = 'root\cimv2',
        [string]$Filter
    )
    try {
        $p = @{ ClassName = $ClassName; Namespace = $Namespace; ErrorAction = 'Stop' }
        if ($Filter) { $p.Filter = $Filter }
        $res = @(Get-CimInstance @p)
        return ,$res
    } catch { return ,@() }
}

function Get-BusTypeName {
    [OutputType([string])]
    param([AllowNull()][object]$BusType)
    if ($null -eq $BusType) { return 'Unknown' }
    if ($BusType -is [string] -and $BusType -notmatch '^\d+$') { return $BusType }
    $map = @{
        0 = 'Unknown'; 1 = 'SCSI'; 2 = 'ATAPI'; 3 = 'ATA'; 4 = '1394'; 5 = 'SSA'
        6 = 'Fibre Channel'; 7 = 'USB'; 8 = 'RAID'; 9 = 'iSCSI'; 10 = 'SAS'
        11 = 'SATA'; 12 = 'SD'; 13 = 'MMC'; 14 = 'Virtual'; 15 = 'File Backed Virtual'
        16 = 'Storage Spaces'; 17 = 'NVMe'; 18 = 'SCM'; 19 = 'UFS'
    }
    $k = [int]$BusType
    if ($map.ContainsKey($k)) { $map[$k] } else { "Bus$k" }
}

function Get-MediaTypeName {
    [OutputType([string])]
    param([AllowNull()][object]$MediaType)
    if ($null -eq $MediaType) { return 'Unspecified' }
    if ($MediaType -is [string] -and $MediaType -notmatch '^\d+$') { return $MediaType }
    switch ([int]$MediaType) {
        0 { 'Unspecified' } 3 { 'HDD' } 4 { 'SSD' } 5 { 'SCM' } default { "Media$MediaType" }
    }
}

function Get-DriveInventory {
    <#
        One record per physical disk, with the volumes that live on it.

        MSFT_PhysicalDisk is the richest source but is absent on some systems,
        so Win32_DiskDrive is used to fill the gaps and as a fallback.
    #>
    [OutputType([object[]])]
    param()

    $phys = Get-CimSafe -ClassName 'MSFT_PhysicalDisk' -Namespace 'root\Microsoft\Windows\Storage'
    $disks = Get-CimSafe -ClassName 'MSFT_Disk' -Namespace 'root\Microsoft\Windows\Storage'
    $w32 = Get-CimSafe -ClassName 'Win32_DiskDrive'
    $parts = Get-CimSafe -ClassName 'Win32_DiskDriveToDiskPartition'
    $logical = Get-CimSafe -ClassName 'Win32_LogicalDiskToPartition'

    # DiskNumber -> drive letters, via Win32 association classes.
    $letters = @{}
    foreach ($a in $parts) {
        $devId = $a.Antecedent.DeviceID   # \\.\PHYSICALDRIVE0
        $partId = $a.Dependent.DeviceID    # Disk #0, Partition #1
        if ($devId -notmatch 'PHYSICALDRIVE(\d+)') { continue }
        $num = [int]$Matches[1]
        foreach ($l in $logical) {
            if ($l.Antecedent.DeviceID -eq $partId) {
                $letter = ([string]$l.Dependent.DeviceID).TrimEnd(':')
                if ($letter) {
                    if (-not $letters.ContainsKey($num)) { $letters[$num] = [System.Collections.ArrayList]::new() }
                    if ($letters[$num] -notcontains $letter) { [void]$letters[$num].Add($letter) }
                }
            }
        }
    }

    $out = [System.Collections.ArrayList]::new()
    $source = if ($phys.Count -gt 0) { $phys } else { $w32 }

    foreach ($p in $source) {
        $num = if ($null -ne $p.DeviceId) { [int]$p.DeviceId } elseif ($null -ne $p.Index) { [int]$p.Index } else { -1 }
        $w = $w32 | Where-Object { $_.Index -eq $num } | Select-Object -First 1
        $d = $disks | Where-Object { [int]$_.Number -eq $num } | Select-Object -First 1

        $model = if ($p.FriendlyName) { $p.FriendlyName } elseif ($w.Model) { $w.Model } else { 'Unknown device' }
        $size = if ($p.Size) { [long]$p.Size } elseif ($w.Size) { [long]$w.Size } else { 0L }
        $serial = if ($p.SerialNumber) { ([string]$p.SerialNumber).Trim() }
        elseif ($w.SerialNumber) { ([string]$w.SerialNumber).Trim() } else { '' }

        [void]$out.Add([pscustomobject]@{
                DiskNumber      = $num
                Model           = ([string]$model).Trim()
                Manufacturer    = if ($p.Manufacturer) { ([string]$p.Manufacturer).Trim() } else { '' }
                SerialNumber    = $serial
                FirmwareVersion = if ($p.FirmwareVersion) { [string]$p.FirmwareVersion } elseif ($w.FirmwareRevision) { [string]$w.FirmwareRevision } else { '' }
                SizeBytes       = $size
                BusType         = Get-BusTypeName $p.BusType
                MediaTypeRaw    = $p.MediaType
                MediaType       = Get-MediaTypeName $p.MediaType
                SpindleSpeed    = if ($null -ne $p.SpindleSpeed) { [int]$p.SpindleSpeed } else { $null }
                HealthStatus    = if ($null -ne $p.HealthStatus) { [string]$p.HealthStatus } else { 'Unknown' }
                OperationalName = if ($p.OperationalStatus) { ($p.OperationalStatus -join ', ') } else { '' }
                PartitionStyle  = if ($d) { [string]$d.PartitionStyle } else { '' }
                IsBoot          = [bool]($d -and $d.IsBoot)
                IsSystem        = [bool]($d -and $d.IsSystem)
                IsReadOnly      = [bool]($d -and $d.IsReadOnly)
                InterfaceType   = if ($w.InterfaceType) { [string]$w.InterfaceType } else { '' }
                DeviceId        = if ($w.DeviceID) { [string]$w.DeviceID } else { '' }
                Letters         = if ($letters.ContainsKey($num)) { @($letters[$num]) } else { @() }
                Source          = if ($phys.Count -gt 0) { 'MSFT_PhysicalDisk' } else { 'Win32_DiskDrive' }
            })
    }

    @($out | Sort-Object DiskNumber)
}

function Get-VolumeInfo {
    <# Volume facts for one drive letter, plus its owning disk record. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][char]$Drive)

    $d = ([string]$Drive).ToUpperInvariant()[0]
    $info = @{
        Letter     = [string]$d
        Root       = "${d}:\"
        Label      = ''
        FileSystem = ''
        SizeBytes  = 0L
        FreeBytes  = 0L
        Ready      = $false
        DiskNumber = -1
        Disk       = $null
        Reason     = ''
    }

    try {
        $di = [System.IO.DriveInfo]::new($info.Root)
        $info.Ready = [bool]$di.IsReady
        if ($di.IsReady) {
            $info.Label = [string]$di.VolumeLabel
            $info.FileSystem = [string]$di.DriveFormat
            $info.SizeBytes = [long]$di.TotalSize
            $info.FreeBytes = [long]$di.AvailableFreeSpace
        } else { $info.Reason = 'volume not ready' }
    } catch { $info.Reason = $_.Exception.Message }

    try {
        $part = Get-Partition -DriveLetter $d -ErrorAction Stop | Select-Object -First 1
        if ($part) { $info.DiskNumber = [int]$part.DiskNumber }
    } catch { }

    if ($info.DiskNumber -ge 0) {
        $info.Disk = Get-DriveInventory | Where-Object { $_.DiskNumber -eq $info.DiskNumber } | Select-Object -First 1
    }

    $info
}

function Get-VolumeGeometry {
    <#
        Cluster size, sector sizes and TRIM state - the numbers that decide
        block alignment for unbuffered I/O. fsutil is used because the
        equivalent CIM properties are unreliable across drivers.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][char]$Drive)

    $d = ([string]$Drive).ToUpperInvariant()[0]
    $g = @{
        ClusterBytes         = 4096
        PhysicalSectorBytes  = 512
        LogicalSectorBytes   = 512
        FileSystem           = ''
        TrimEnabled          = $null
        TotalClusters        = $null
        FreeClusters         = $null
        Source               = 'default'
        Raw                  = ''
    }

    try {
        $txt = (& fsutil fsinfo ntfsinfo "${d}:" 2>&1) -join "`n"
        $g.Raw = $txt
        if ($txt -match '(?im)^\s*Bytes Per Cluster\s*:\s*(\d+)') { $g.ClusterBytes = [int]$Matches[1]; $g.Source = 'fsutil' }
        if ($txt -match '(?im)^\s*Bytes Per Sector\s*:\s*(\d+)') { $g.LogicalSectorBytes = [int]$Matches[1] }
        if ($txt -match '(?im)^\s*Bytes Per Physical Sector\s*:\s*(\d+)') { $g.PhysicalSectorBytes = [int]$Matches[1] }
        if ($txt -match '(?im)^\s*Total Clusters\s*:\s*0x[0-9a-f]+\s*\((\d+)\)') { $g.TotalClusters = [long]$Matches[1] }
        elseif ($txt -match '(?im)^\s*Total Clusters\s*:\s*(\d+)') { $g.TotalClusters = [long]$Matches[1] }
        if ($txt -match '(?im)^\s*Free Clusters\s*:\s*0x[0-9a-f]+\s*\((\d+)\)') { $g.FreeClusters = [long]$Matches[1] }
        elseif ($txt -match '(?im)^\s*Free Clusters\s*:\s*(\d+)') { $g.FreeClusters = [long]$Matches[1] }
    } catch { }

    try {
        $vi = Get-VolumeInfo -Drive $d
        $g.FileSystem = $vi.FileSystem
    } catch { }

    try {
        $t = (& fsutil behavior query DisableDeleteNotify 2>&1) -join "`n"
        if ($t -match 'DisableDeleteNotify\s*(?:=|\s)\s*(\d)') { $g.TrimEnabled = ([int]$Matches[1] -eq 0) }
        elseif ($t -match 'NTFS\s+DisableDeleteNotify\s*=\s*(\d)') { $g.TrimEnabled = ([int]$Matches[1] -eq 0) }
    } catch { }

    if ($g.PhysicalSectorBytes -lt $g.LogicalSectorBytes) { $g.PhysicalSectorBytes = $g.LogicalSectorBytes }
    $g
}
