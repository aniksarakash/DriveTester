<#
    Smart.ps1 - the drive's own account of its health.

    Four sources, in descending order of trust:

      1. smartctl        full attribute table with vendor thresholds
      2. WMI FailurePredict (admin)  raw 512-byte attribute blob from the driver
      3. StorageReliabilityCounter (admin)  temperature, wear, error counts
      4. MSFT_PhysicalDisk.HealthStatus     a single word

    Only sources 1 and 2 give per-attribute thresholds, so only those count as
    Verified. Anything less caps the final grade at B - a drive cannot earn an A
    on health nobody could read.
#>

# Attributes where a non-zero raw value is a real warning sign, not trivia.
$script:SbCriticalAttrs = @{
    5   = 'Reallocated_Sector_Ct'
    10  = 'Spin_Retry_Count'
    184 = 'End-to-End_Error'
    187 = 'Reported_Uncorrect'
    188 = 'Command_Timeout'
    196 = 'Reallocated_Event_Count'
    197 = 'Current_Pending_Sector'
    198 = 'Offline_Uncorrectable'
    199 = 'UDMA_CRC_Error_Count'
    201 = 'Soft_Read_Error_Rate'
}

$script:SbAttrNames = @{
    1   = 'Raw_Read_Error_Rate'; 2 = 'Throughput_Performance'; 3 = 'Spin_Up_Time'
    4   = 'Start_Stop_Count'; 5 = 'Reallocated_Sector_Ct'; 7 = 'Seek_Error_Rate'
    8   = 'Seek_Time_Performance'; 9 = 'Power_On_Hours'; 10 = 'Spin_Retry_Count'
    11  = 'Calibration_Retry_Count'; 12 = 'Power_Cycle_Count'
    173 = 'Wear_Leveling_Count'; 174 = 'Unexpect_Power_Loss_Ct'
    177 = 'Wear_Leveling_Count'; 179 = 'Used_Rsvd_Blk_Cnt_Tot'
    181 = 'Program_Fail_Cnt_Total'; 182 = 'Erase_Fail_Count_Total'
    183 = 'Runtime_Bad_Block'; 184 = 'End-to-End_Error'
    187 = 'Reported_Uncorrect'; 188 = 'Command_Timeout'
    189 = 'High_Fly_Writes'; 190 = 'Airflow_Temperature_Cel'
    191 = 'G-Sense_Error_Rate'; 192 = 'Power-Off_Retract_Count'
    193 = 'Load_Cycle_Count'; 194 = 'Temperature_Celsius'
    196 = 'Reallocated_Event_Count'; 197 = 'Current_Pending_Sector'
    198 = 'Offline_Uncorrectable'; 199 = 'UDMA_CRC_Error_Count'
    200 = 'Multi_Zone_Error_Rate'; 201 = 'Soft_Read_Error_Rate'
    231 = 'SSD_Life_Left'; 232 = 'Available_Reservd_Space'
    233 = 'Media_Wearout_Indicator'; 241 = 'Total_LBAs_Written'
    242 = 'Total_LBAs_Read'; 249 = 'NAND_Writes_1GiB'
}

function Get-SmartAttributeName {
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Id)
    if ($script:SbAttrNames.ContainsKey($Id)) { $script:SbAttrNames[$Id] } else { "Attribute_$Id" }
}

function Test-SmartThreshold {
    <#
        Verdict for one attribute: PASS | WARN | FAIL.

        FAIL means the normalised value has reached the manufacturer's own
        failure threshold - the drive is telling you it is dying. WARN means a
        critical counter has moved off zero: reallocated sectors, pending
        sectors, uncorrectable reads, CRC errors on the cable. Those never
        recover on their own.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Attribute)

    if ($null -eq $Attribute) { return 'PASS' }

    $id = [int]$Attribute.Id
    $value = if ($null -ne $Attribute.Value) { [int]$Attribute.Value } else { $null }
    $thresh = if ($null -ne $Attribute.Threshold) { [int]$Attribute.Threshold } else { 0 }
    $raw = if ($null -ne $Attribute.Raw) { [double]$Attribute.Raw } else { 0 }

    if ($Attribute.PSObject.Properties['WhenFailed'] -and $Attribute.WhenFailed) {
        if ([string]$Attribute.WhenFailed -match 'FAILING_NOW') { return 'FAIL' }
        if ([string]$Attribute.WhenFailed -match 'In_the_past') { return 'WARN' }
    }
    if ($null -ne $value -and $thresh -gt 0 -and $value -le $thresh) { return 'FAIL' }
    if ($script:SbCriticalAttrs.ContainsKey($id) -and $raw -gt 0) { return 'WARN' }

    # Temperature is reported in the raw field on nearly every drive.
    if ($id -eq 194 -and $raw -ge 60) { return 'WARN' }
    if ($id -eq 194 -and $raw -ge 70) { return 'FAIL' }

    'PASS'
}

function ConvertFrom-SmartctlJson {
    <# smartctl -j -a output -> normalised attribute records. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Json)

    $res = @{ Attributes = @(); Overall = $null; Model = ''; Serial = ''; Firmware = ''; Temperature = $null; PowerOnHours = $null; Notes = @() }
    try { $doc = $Json | ConvertFrom-Json -ErrorAction Stop } catch { $res.Notes += 'smartctl JSON unparsable'; return $res }

    if ($doc.model_name) { $res.Model = [string]$doc.model_name }
    if ($doc.serial_number) { $res.Serial = [string]$doc.serial_number }
    if ($doc.firmware_version) { $res.Firmware = [string]$doc.firmware_version }
    if ($null -ne $doc.temperature -and $null -ne $doc.temperature.current) { $res.Temperature = [int]$doc.temperature.current }
    if ($null -ne $doc.power_on_time -and $null -ne $doc.power_on_time.hours) { $res.PowerOnHours = [long]$doc.power_on_time.hours }
    if ($null -ne $doc.smart_status -and $null -ne $doc.smart_status.passed) {
        $res.Overall = if ($doc.smart_status.passed) { 'PASSED' } else { 'FAILED' }
    }

    $attrs = [System.Collections.ArrayList]::new()

    # ATA / SATA attribute table.
    if ($doc.ata_smart_attributes -and $doc.ata_smart_attributes.table) {
        foreach ($a in $doc.ata_smart_attributes.table) {
            [void]$attrs.Add([pscustomobject]@{
                    Id         = [int]$a.id
                    Name       = if ($a.name) { [string]$a.name } else { Get-SmartAttributeName ([int]$a.id) }
                    Value      = if ($null -ne $a.value) { [int]$a.value } else { $null }
                    Worst      = if ($null -ne $a.worst) { [int]$a.worst } else { $null }
                    Threshold  = if ($null -ne $a.thresh) { [int]$a.thresh } else { 0 }
                    Raw        = if ($a.raw -and $null -ne $a.raw.value) { [double]$a.raw.value } else { 0 }
                    RawString  = if ($a.raw -and $a.raw.string) { [string]$a.raw.string } else { '' }
                    WhenFailed = if ($a.when_failed) { [string]$a.when_failed } else { '' }
                    Source     = 'smartctl'
                })
        }
    }

    # NVMe health log - different shape, same questions.
    if ($doc.nvme_smart_health_information_log) {
        $n = $doc.nvme_smart_health_information_log
        $pairs = @(
            @{ Id = 1000; Name = 'Critical_Warning'; Raw = $n.critical_warning }
            @{ Id = 1001; Name = 'Available_Spare_Pct'; Raw = $n.available_spare; Value = $n.available_spare; Threshold = $n.available_spare_threshold }
            @{ Id = 1002; Name = 'Percentage_Used'; Raw = $n.percentage_used }
            @{ Id = 1003; Name = 'Media_Errors'; Raw = $n.media_errors }
            @{ Id = 1004; Name = 'Unsafe_Shutdowns'; Raw = $n.unsafe_shutdowns }
            @{ Id = 1005; Name = 'Power_On_Hours'; Raw = $n.power_on_hours }
            @{ Id = 1006; Name = 'Data_Units_Written'; Raw = $n.data_units_written }
        )
        foreach ($p in $pairs) {
            if ($null -eq $p.Raw) { continue }
            [void]$attrs.Add([pscustomobject]@{
                    Id         = [int]$p.Id
                    Name       = [string]$p.Name
                    Value      = if ($null -ne $p.Value) { [int]$p.Value } else { $null }
                    Worst      = $null
                    Threshold  = if ($null -ne $p.Threshold) { [int]$p.Threshold } else { 0 }
                    Raw        = [double]$p.Raw
                    RawString  = [string]$p.Raw
                    WhenFailed = ''
                    Source     = 'smartctl-nvme'
                })
        }
        if ($null -ne $n.temperature) { $res.Temperature = [int]$n.temperature }
        if ($null -ne $n.power_on_hours) { $res.PowerOnHours = [long]$n.power_on_hours }
    }

    $res.Attributes = @($attrs)
    $res
}

function Get-SmartViaSmartctl {
    <#
        smartctl through a USB bridge often needs an explicit device type, so
        several are tried in turn. The first attempt that yields attributes wins.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$SmartctlPath,
        [Parameter(Mandatory)][int]$DiskNumber,
        [string]$BusType = ''
    )

    $dev = "/dev/pd$DiskNumber"
    $types = switch ($BusType) {
        'NVMe' { @('nvme', 'auto') }
        'USB' { @('sat', 'auto', 'usbjmicron', 'usbprolific', 'usbsunplus', 'scsi') }
        default { @('auto', 'sat', 'nvme', 'scsi') }
    }

    $tried = [System.Collections.ArrayList]::new()
    foreach ($t in $types) {
        $r = Invoke-Smartctl -SmartctlPath $SmartctlPath -Arguments @('-j', '-a', '-d', $t, $dev) -TimeoutSeconds 45
        [void]$tried.Add("-d $t -> exit $($r.ExitCode)")
        if (-not $r.StdOut) { continue }
        $parsed = ConvertFrom-SmartctlJson -Json $r.StdOut
        if ($parsed.Attributes.Count -gt 0 -or $parsed.Overall) {
            $parsed.Notes = @($parsed.Notes) + "smartctl -d $t on $dev (exit $($r.ExitCode))"
            $parsed.DeviceType = $t
            $parsed.ExitCode = $r.ExitCode
            $parsed.Findings = $r.Findings
            return @{ Ok = $true; Data = $parsed; Tried = @($tried) }
        }
    }
    @{ Ok = $false; Data = $null; Tried = @($tried) }
}

function Get-SmartViaWmi {
    <#
        The driver's raw attribute blob: 362 bytes of vendor data, 12 bytes per
        attribute starting at offset 2. Needs elevation, and USB bridges usually
        refuse to pass the command through at all.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][int]$DiskNumber)

    $res = @{ Ok = $false; Attributes = @(); Overall = $null; Notes = @() }

    $data = @(Get-CimSafe -ClassName 'MSStorageDriver_FailurePredictData' -Namespace 'root\wmi')
    $thr = @(Get-CimSafe -ClassName 'MSStorageDriver_FailurePredictThresholds' -Namespace 'root\wmi')
    $status = @(Get-CimSafe -ClassName 'MSStorageDriver_FailurePredictStatus' -Namespace 'root\wmi')
    if ($data.Count -eq 0) { $res.Notes += 'MSStorageDriver_FailurePredictData unavailable (needs admin; most USB bridges never expose it)'; return $res }

    $want = "PHYSICALDRIVE$DiskNumber"
    $rec = $data | Where-Object { [string]$_.InstanceName -match [regex]::Escape($want) } | Select-Object -First 1
    if (-not $rec) { $rec = $data | Select-Object -First 1 }
    if (-not $rec -or -not $rec.VendorSpecific) { $res.Notes += 'no vendor attribute blob returned'; return $res }

    $thresholds = @{}
    $trec = $thr | Where-Object { [string]$_.InstanceName -eq [string]$rec.InstanceName } | Select-Object -First 1
    if ($trec -and $trec.VendorSpecific) {
        $tb = [byte[]]$trec.VendorSpecific
        for ($i = 2; ($i + 11) -lt $tb.Length; $i += 12) {
            $id = [int]$tb[$i]
            if ($id -eq 0) { continue }
            $thresholds[$id] = [int]$tb[$i + 1]
        }
    }

    $b = [byte[]]$rec.VendorSpecific
    $attrs = [System.Collections.ArrayList]::new()
    for ($i = 2; ($i + 11) -lt $b.Length; $i += 12) {
        $id = [int]$b[$i]
        if ($id -eq 0) { continue }
        $raw = 0.0
        for ($k = 0; $k -lt 6; $k++) { $raw += [double]$b[$i + 5 + $k] * [math]::Pow(256, $k) }
        [void]$attrs.Add([pscustomobject]@{
                Id         = $id
                Name       = Get-SmartAttributeName $id
                Value      = [int]$b[$i + 3]
                Worst      = [int]$b[$i + 4]
                Threshold  = if ($thresholds.ContainsKey($id)) { $thresholds[$id] } else { 0 }
                Raw        = $raw
                RawString  = [string]$raw
                WhenFailed = ''
                Source     = 'wmi'
            })
    }

    if ($attrs.Count -eq 0) { $res.Notes += 'attribute blob present but empty'; return $res }

    $srec = $status | Where-Object { [string]$_.InstanceName -eq [string]$rec.InstanceName } | Select-Object -First 1
    if ($srec) { $res.Overall = if ($srec.PredictFailure) { 'FAILED' } else { 'PASSED' } }

    $res.Ok = $true
    $res.Attributes = @($attrs)
    $res.Notes += "read $($attrs.Count) attributes from the storage driver"
    $res
}

function Get-SmartViaReliability {
    <# Get-StorageReliabilityCounter: coarse but often the only thing that works. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][int]$DiskNumber)

    $res = @{ Ok = $false; Attributes = @(); Notes = @(); Temperature = $null; PowerOnHours = $null; Wear = $null }
    try {
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [int]$_.DeviceId -eq $DiskNumber } | Select-Object -First 1
        if (-not $pd) { $res.Notes += "no physical disk $DiskNumber"; return $res }
        $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
        if (-not $rc) { $res.Notes += 'no reliability counters'; return $res }

        $attrs = [System.Collections.ArrayList]::new()
        $add = {
            param($id, $name, $val)
            if ($null -ne $val) {
                [void]$attrs.Add([pscustomobject]@{
                        Id = $id; Name = $name; Value = $null; Worst = $null; Threshold = 0
                        Raw = [double]$val; RawString = [string]$val; WhenFailed = ''; Source = 'reliability'
                    })
            }
        }
        & $add 194 'Temperature_Celsius' $rc.Temperature
        & $add 9 'Power_On_Hours' $rc.PowerOnHours
        & $add 233 'Wear' $rc.Wear
        & $add 187 'ReadErrorsUncorrected' $rc.ReadErrorsUncorrected
        & $add 5 'WriteErrorsUncorrected' $rc.WriteErrorsUncorrected
        & $add 12 'StartStopCycleCount' $rc.StartStopCycleCount

        $res.Temperature = $rc.Temperature
        $res.PowerOnHours = $rc.PowerOnHours
        $res.Wear = $rc.Wear
        $res.Attributes = @($attrs)
        $res.Ok = ($attrs.Count -gt 0)
        if ($res.Ok) { $res.Notes += 'read Windows storage reliability counters' }
    } catch {
        $res.Notes += "reliability counters unavailable: $($_.Exception.Message)"
    }
    $res
}

function Get-SmartReport {
    <#
        Best available health picture for one disk.

        Returns @{Status;Source;Attributes;Overall;Notes;Failures;Warnings;
                  Temperature;PowerOnHours;Verified}

        Status is Verified (thresholds available), Partial (numbers but no
        thresholds) or Unverified (nothing but a health word). Grade.ps1 caps a
        run at B unless Status is Verified.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$DiskInfo,
        [Parameter(Mandatory)][AllowNull()][hashtable]$ToolState,
        [bool]$IsAdmin = $false
    )

    $report = @{
        Status = 'Unverified'; Source = 'none'; Attributes = @(); Overall = $null
        Notes = @(); Failures = @(); Warnings = @(); Temperature = $null
        PowerOnHours = $null; Verified = $false
    }

    $diskNum = if ($DiskInfo -and $null -ne $DiskInfo.DiskNumber) { [int]$DiskInfo.DiskNumber } else { -1 }
    $busType = if ($DiskInfo -and $DiskInfo.BusType) { [string]$DiskInfo.BusType } else { '' }

    # 1. smartctl.
    if ($ToolState -and $ToolState.Smartctl -and $ToolState.Smartctl.Ok -and $diskNum -ge 0) {
        $sc = Get-SmartViaSmartctl -SmartctlPath $ToolState.Smartctl.Path -DiskNumber $diskNum -BusType $busType
        if ($sc.Ok) {
            $report.Status = 'Verified'
            $report.Source = 'smartctl'
            $report.Attributes = @($sc.Data.Attributes)
            $report.Overall = $sc.Data.Overall
            $report.Temperature = $sc.Data.Temperature
            $report.PowerOnHours = $sc.Data.PowerOnHours
            $report.Notes = @($sc.Data.Notes)
            $report.Verified = $true
        } else {
            $report.Notes += "smartctl could not read this device (tried: $($sc.Tried -join '; '))"
        }
    } elseif ($ToolState -and $ToolState.Smartctl -and -not $ToolState.Smartctl.Ok) {
        $report.Notes += 'smartctl not available'
    }

    # 2. WMI FailurePredict.
    if (-not $report.Verified -and $IsAdmin -and $diskNum -ge 0) {
        $w = Get-SmartViaWmi -DiskNumber $diskNum
        $report.Notes += @($w.Notes)
        if ($w.Ok) {
            $report.Status = 'Verified'
            $report.Source = 'wmi'
            $report.Attributes = @($w.Attributes)
            $report.Overall = $w.Overall
            $report.Verified = $true
        }
    } elseif (-not $report.Verified -and -not $IsAdmin) {
        $report.Notes += 'not elevated: the storage driver will not release raw SMART attributes'
    }

    # 3. Reliability counters.
    if (-not $report.Verified -and $diskNum -ge 0) {
        $r = Get-SmartViaReliability -DiskNumber $diskNum
        $report.Notes += @($r.Notes)
        if ($r.Ok) {
            $report.Status = 'Partial'
            $report.Source = 'reliability'
            $report.Attributes = @($r.Attributes)
            $report.Temperature = $r.Temperature
            $report.PowerOnHours = $r.PowerOnHours
        }
    }

    # 4. The one-word health status.
    if (@($report.Attributes).Count -eq 0) {
        $hs = if ($DiskInfo -and $DiskInfo.HealthStatus) { [string]$DiskInfo.HealthStatus } else { 'Unknown' }
        $report.Source = 'healthstatus'
        $report.Overall = switch ($hs) { 'Healthy' { 'PASSED' } 'Unhealthy' { 'FAILED' } 'Warning' { 'WARN' } default { $null } }
        $report.Notes += "no SMART attributes reachable; Windows reports HealthStatus '$hs'"
    }

    foreach ($a in $report.Attributes) {
        switch (Test-SmartThreshold -Attribute $a) {
            'FAIL' { $report.Failures += "$($a.Name) (id $($a.Id)) = $($a.RawString), normalised $($a.Value) at threshold $($a.Threshold)" }
            'WARN' { $report.Warnings += "$($a.Name) (id $($a.Id)) = $($a.RawString)" }
        }
        if ($a.Id -eq 194 -and $null -eq $report.Temperature -and $a.Raw -gt 0) { $report.Temperature = [int]$a.Raw }
        if ($a.Id -eq 9 -and $null -eq $report.PowerOnHours) { $report.PowerOnHours = [long]$a.Raw }
    }

    if ($report.Overall -eq 'FAILED') { $report.Failures += 'the drive reports overall SMART status FAILED' }
    $report
}
