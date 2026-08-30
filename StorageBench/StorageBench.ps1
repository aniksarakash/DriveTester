#Requires -Version 7.0
<#
    StorageBench.ps1 - the run.

    Everything hard lives in lib/. This file is the part that decides what to
    ask of a drive, in what order, and what to do when a phase comes back with
    less than it hoped for. It is deliberately the only file that knows about
    presets, prompts, exit codes and cleanup.

    Three rules shape it:

      1. Nothing is written outside <Vol>:\.storagebench-scratch\<runId>\, and
         that folder is removed in a finally block - including when the run is
         interrupted. Ctrl+C is handled cooperatively (the handler sets a flag
         and cancels the kill) precisely so cleanup cannot be skipped.
      2. A phase that cannot run degrades the report, never the process. The run
         records why, carries on, and lets Grade.ps1 decide what the gap costs.
         Only a failure to identify the drive at all aborts.
      3. -DryRun writes nothing whatsoever. It prints the plan it would have
         executed and exits 0.

    Exit codes: 0 pass, 1 warn, 2 fail, 3 aborted or tool error.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')][char]$Drive = 'D',
    [ValidateSet('Quick', 'Standard', 'Thorough', 'Certify')][string]$Preset = 'Standard',
    [switch]$Yes,
    [switch]$NoNet,
    [switch]$FetchTools,
    [switch]$Plain,
    [switch]$DryRun,
    [switch]$Force,
    [ValidateRange(0, 4096)][int]$IntegritySizeGB = 0,
    [switch]$SkipIntegrity,
    [switch]$SkipBench,
    [switch]$SkipSmart,
    [switch]$NoClean
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:SbVersion = '1.0.0'
$script:SbHome = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }

# lib\Tools.ps1 reads this to decide where fetched tools land.
$script:SbRootDir = $script:SbHome

# The dot-source order is a dependency order: Core first because everything
# formats through it, Ui and Report last because they only consume records.
$script:SbModuleOrder = @(
    'Core', 'Safety', 'Tools', 'Inventory', 'Classify', 'Smart',
    'Bench', 'Integrity', 'Surface', 'Expectations', 'Grade', 'Ui', 'Report'
)
foreach ($sbModule in $script:SbModuleOrder) {
    $sbPath = Join-Path $script:SbHome (Join-Path 'lib' "$sbModule.ps1")
    if (-not (Test-Path -LiteralPath $sbPath)) { throw "StorageBench is missing lib\$sbModule.ps1 - the install is incomplete." }
    . $sbPath
}

# Cancellation state is a synchronised bag because the console handler runs on
# another thread. Only ever written $true, only ever read between steps.
$script:SbFlags = [hashtable]::Synchronized(@{ Cancelled = $false })

function Test-SbCancelled {
    <# True once Ctrl+C has been seen. Checked between steps, never inside one. #>
    [OutputType([bool])]
    param()
    [bool]$script:SbFlags['Cancelled']
}

function Get-PresetPlan {
    <#
        Turns a preset name and the space actually available into concrete sizes.
        Every number here is a byte count the run will really write, so the
        preflight can show it and Test-Reserve can veto it before anything
        touches the disk.

        Certify is the only preset whose integrity size is computed rather than
        stated: it means "every byte of free space we are allowed to use", which
        is free space minus the safety reserve minus the files the other phases
        need at the same time.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('Quick', 'Standard', 'Thorough', 'Certify')][string]$Preset,
        [long]$VolumeBytes = 0,
        [long]$FreeBytes = 0,
        [int]$IntegritySizeGB = 0,
        [switch]$SkipBench,
        [switch]$SkipIntegrity,
        [switch]$SkipSmart
    )

    $plan = switch ($Preset) {
        'Quick' {
            @{
                ClassifyBytes = 256MB; ClassifySamples = 128
                BenchBytes = 256MB; Qd1Samples = 256; QdNSamples = 0; QueueDepth = 16
                SustainedBytes = 0L; Zones = 0
                IntegrityMB = 1024; IntegrityMode = 'Spread'
                SurfaceRegions = 0
                Estimate = 'about 2 minutes'
            }
        }
        'Standard' {
            @{
                ClassifyBytes = 512MB; ClassifySamples = 192
                BenchBytes = 1GB; Qd1Samples = 512; QdNSamples = 512; QueueDepth = 16
                SustainedBytes = 0L; Zones = 8
                IntegrityMB = 8192; IntegrityMode = 'Spread'
                SurfaceRegions = 0
                Estimate = 'about 10 minutes'
            }
        }
        'Thorough' {
            @{
                ClassifyBytes = 512MB; ClassifySamples = 256
                BenchBytes = 2GB; Qd1Samples = 1024; QdNSamples = 1024; QueueDepth = 32
                SustainedBytes = 4GB; Zones = 8
                IntegrityMB = 32768; IntegrityMode = 'Spread'
                SurfaceRegions = 64
                Estimate = 'about 40 minutes'
            }
        }
        'Certify' {
            @{
                ClassifyBytes = 512MB; ClassifySamples = 256
                BenchBytes = 2GB; Qd1Samples = 1024; QdNSamples = 2048; QueueDepth = 32
                SustainedBytes = 8GB; Zones = 8
                IntegrityMB = -1; IntegrityMode = 'Full'
                SurfaceRegions = 128
                Estimate = 'hours - every free byte is verified'
            }
        }
    }

    $plan.Name = $Preset
    $plan.DoBench = -not $SkipBench
    $plan.DoIntegrity = -not $SkipIntegrity
    $plan.DoSmart = -not $SkipSmart
    $plan.Notes = @()
    # Retuned by Update-PlanForClass once the drive has been classified; stays
    # 'generic' when classification is skipped or fails.
    $plan.Method = 'generic'

    if (-not $plan.DoBench) {
        $plan.BenchBytes = 0L; $plan.Qd1Samples = 0; $plan.QdNSamples = 0
        $plan.SustainedBytes = 0L; $plan.Zones = 0
    }
    $plan.DoSurface = ($plan.SurfaceRegions -gt 0)

    # An explicit -IntegritySizeGB wins over the preset, Certify included.
    if ($IntegritySizeGB -gt 0) {
        $plan.IntegrityMB = $IntegritySizeGB * 1024
        $plan.IntegrityMode = 'Spread'
    }

    $reserve = if ($VolumeBytes -gt 0) { Get-ReserveBytes -VolumeSizeBytes $VolumeBytes } else { 2GB }
    $concurrent = [long]$plan.ClassifyBytes + [long]$plan.BenchBytes + [long]$plan.SustainedBytes
    $budget = [long]$FreeBytes - [long]$reserve - $concurrent - 128MB

    if ($plan.IntegrityMB -lt 0) {
        $plan.IntegrityMB = if ($budget -gt 0) { [int][math]::Floor($budget / 1MB) } else { 0 }
        if ($plan.IntegrityMB -gt 0) {
            $plan.Notes += "certify sized the integrity pass at $(Format-Bytes -Bytes ([long]$plan.IntegrityMB * 1MB)) - all the free space it is allowed to use"
        }
    } elseif ($plan.DoIntegrity -and ([long]$plan.IntegrityMB * 1MB) -gt $budget) {
        $was = [long]$plan.IntegrityMB * 1MB
        $plan.IntegrityMB = if ($budget -gt 0) { [int][math]::Floor($budget / 1MB) } else { 0 }
        $plan.Notes += "integrity trimmed from $(Format-Bytes -Bytes $was) to $(Format-Bytes -Bytes ([long]$plan.IntegrityMB * 1MB)) to stay clear of the $(Format-Bytes -Bytes $reserve) reserve"
    }

    if ($plan.IntegrityMB -lt 16) {
        if ($plan.DoIntegrity) { $plan.Notes += 'there is not enough free space for a meaningful integrity pass, so it was dropped' }
        $plan.DoIntegrity = $false
        $plan.IntegrityMB = 0
    }

    $plan.NeedBytes = $concurrent + ([long]$plan.IntegrityMB * 1MB)
    $plan.ReserveBytes = [long]$reserve
    $plan
}

function Update-PlanForClass {
    <#
        Retunes the plan once the drive has said what it is.

        The same test is not equally informative on every medium, and the run
        has a fixed time budget, so spending it identically on a platter and on
        PCIe flash wastes both. What changes and why:

          queue depth   A mechanical drive has one head. Thirty-two outstanding
                        requests do not make it seek in parallel, they just
                        queue, so the number measured is the scheduler's, not
                        the drive's. Flash has many channels and only shows its
                        real throughput when the queue is deep.
          QDN samples   An HDD serves roughly a hundred random reads a second.
                        The 2048 samples that take an NVMe two seconds take a
                        platter half a minute, for a number already known after
                        a few hundred.
          zone profile  Outer tracks are genuinely faster than inner ones - it
                        is the clearest signal a platter gives. On flash the
                        same sweep measures the cache, so it stays but says so.
          sustained     The point of a long write on flash is to run the SLC
                        cache dry and find the cliff. A platter has no cliff to
                        find, only a small buffer, so the write is capped.
          surface       Weak sectors are a property of magnetic media. On flash
                        the sweep is a remap check, which needs fewer regions.

        Pure: takes a plan, returns the adjusted plan. Every change appends a
        note, so the report can always say why it measured what it measured.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$MeasuredClass,
        [string]$BusType = ''
    )

    $Plan.Method = 'generic'
    if (-not $MeasuredClass -or $MeasuredClass -eq 'Unknown') {
        $Plan.Notes += 'the medium could not be identified, so the preset was run as written'
        return $Plan
    }

    $Plan.Method = $MeasuredClass
    $usb = ($BusType -eq 'USB')

    switch ($MeasuredClass) {
        'HDD' {
            if ($Plan.QueueDepth -gt 4) {
                $Plan.Notes += "queue depth cut from $($Plan.QueueDepth) to 4 - one head cannot serve a deeper queue, so anything more measures the scheduler"
                $Plan.QueueDepth = 4
            }
            if ($Plan.QdNSamples -gt 256) {
                $Plan.Notes += "random QDN samples cut from $($Plan.QdNSamples) to 256 - at platter speed the rest would add minutes and not precision"
                $Plan.QdNSamples = 256
            }
            if ($Plan.Qd1Samples -gt 512) {
                $Plan.Notes += "random QD1 samples cut from $($Plan.Qd1Samples) to 512 for the same reason"
                $Plan.Qd1Samples = 512
            }
            if ($Plan.SustainedBytes -gt 2GB) {
                $Plan.Notes += "sustained write capped at 2.0 GB - a platter has no SLC cache to exhaust, only a small buffer"
                $Plan.SustainedBytes = 2GB
            }
            if ($Plan.Zones -lt 8) {
                $Plan.Notes += 'zone profile raised to 8 - track position is the clearest signal a platter gives'
                $Plan.Zones = 8
            }
            if ($Plan.IntegrityMB -gt 2048 -and $Plan.Name -ne 'Certify') {
                $Plan.Notes += "integrity pass trimmed from $(Format-Bytes -Bytes ([long]$Plan.IntegrityMB * 1MB)) to 2.0 GB - at platter write speed the full span would blow the preset time budget"
                $Plan.IntegrityMB = 2048
            }
        }
        'SSD' {
            $want = if ($usb) { 16 } else { 32 }
            if ($Plan.QueueDepth -lt $want -and $Plan.QdNSamples -gt 0) {
                $Plan.Notes += "queue depth raised from $($Plan.QueueDepth) to $want - solid state only shows its throughput with the queue full"
                $Plan.QueueDepth = $want
            }
            if ($Plan.SurfaceRegions -gt 32) {
                $Plan.Notes += "surface regions cut from $($Plan.SurfaceRegions) to 32 - flash has no weak tracks, so this is a remap check rather than a survey"
                $Plan.SurfaceRegions = 32
            }
            if ($Plan.Zones -gt 0) {
                $Plan.Notes += 'the zone profile is kept, but on flash it measures cache behaviour rather than geometry'
            }
        }
        'NVMe' {
            if ($Plan.QueueDepth -lt 32 -and $Plan.QdNSamples -gt 0) {
                $Plan.Notes += "queue depth raised from $($Plan.QueueDepth) to 32 - PCIe flash is idle at a shallow queue"
                $Plan.QueueDepth = 32
            }
            if ($Plan.QdNSamples -gt 0 -and $Plan.QdNSamples -lt 1024) {
                $Plan.Notes += "random QDN samples raised from $($Plan.QdNSamples) to 1024 - each one costs microseconds here, and the extra depth is where the number lives"
                $Plan.QdNSamples = 1024
            }
            if ($Plan.SurfaceRegions -gt 32) {
                $Plan.Notes += "surface regions cut from $($Plan.SurfaceRegions) to 32 - flash has no weak tracks, so this is a remap check rather than a survey"
                $Plan.SurfaceRegions = 32
            }
            if ($Plan.Zones -gt 0) {
                $Plan.Notes += 'the zone profile is kept, but on flash it measures cache behaviour rather than geometry'
            }
        }
    }

    $Plan.DoSurface = ($Plan.SurfaceRegions -gt 0)
    $Plan
}

function Get-RunExitCode {
    <#
        The one place the process's answer is decided. Grade owns the verdict;
        this only translates an abort or a crash into the reserved code 3.
    #>
    [OutputType([int])]
    param([AllowNull()][hashtable]$Grade, [switch]$Aborted, [switch]$Fatal)
    if ($Aborted -or $Fatal) { return 3 }
    if ($null -eq $Grade -or $null -eq $Grade.ExitCode) { return 3 }
    [int]$Grade.ExitCode
}

function New-ProgressCallback {
    <#
        Every measuring function reports progress, but not in the same shape:
        most call back with (current, total), while the sustained-write and
        integrity passes call back with a hashtable. This adapts all of them onto
        ui.Progress so the phases stay free of display code.
    #>
    [OutputType([scriptblock])]
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)][string]$Label)

    $state = @{
        Ui             = $Ui
        Label          = $Label
        Start          = [datetime]::Now
        FormatMbps     = (Get-Command Format-Mbps).ScriptBlock
        GetPct         = (Get-Command Get-Pct).ScriptBlock
        FormatDuration = (Get-Command Format-Duration).ScriptBlock
    }
    {
        param($a, $b)

        $cur = 0.0; $total = 0.0; $extra = ''
        if ($a -is [System.Collections.IDictionary]) {
            if ($a.Contains('WrittenBytes')) { $cur = [double]$a['WrittenBytes'] }
            elseif ($a.Contains('Bytes')) { $cur = [double]$a['Bytes'] }
            if ($a.Contains('TotalBytes') -and $a['TotalBytes']) { $total = [double]$a['TotalBytes'] }
            if ($a.Contains('MBps') -and $a['MBps']) { $extra = & ($state.FormatMbps) -MBps $a['MBps'] }
            if ($a.Contains('Phase') -and $a['Phase']) { $extra = (@([string]$a['Phase'], $extra) | Where-Object { $_ }) -join ' ' }
        } else {
            $cur = if ($null -eq $a) { 0.0 } else { [double]$a }
            $total = if ($null -eq $b) { 0.0 } else { [double]$b }
        }

        $pct = if ($total -gt 0) { & ($state.GetPct) -Current $cur -Total $total } else { 0.0 }
        $elapsed = ([datetime]::Now - $state.Start).TotalSeconds
        $eta = if ($pct -ge 2 -and $elapsed -ge 2) { 'eta ' + (& ($state.FormatDuration) -Seconds ((($elapsed / $pct) * (100.0 - $pct)))) } else { '' }
        $tail = (@($extra, $eta) | Where-Object { $_ }) -join '  '
        $state.Ui.Progress($pct, $state.Label, $tail)
    }.GetNewClosure()
}

function Resolve-TargetDisk {
    <#
        Finds the physical disk that owns the requested letter, falling back to
        the volume's disk number when the inventory could not enumerate letters
        (some USB bridges hide them).
    #>
    param([Parameter(Mandatory)][char]$Drive, [Parameter(Mandatory)][AllowNull()]$Volume)

    $letter = ([string]$Drive).ToUpperInvariant()
    $disks = @(Get-DriveInventory)
    if ($disks.Count -eq 0) { return $null }

    $hit = $disks | Where-Object { @($_.Letters) -contains $letter } | Select-Object -First 1
    if ($hit) { return $hit }
    if ($Volume -and $null -ne $Volume.DiskNumber) {
        $hit = $disks | Where-Object { $_.DiskNumber -eq $Volume.DiskNumber } | Select-Object -First 1
    }
    $hit
}

function Write-PreflightReport {
    <#
        What the run is about to do, in the terms a person would object to:
        which drive, how much will be written, where, and what will be missing
        from the answer. Printed before consent and before the TUI takes the
        screen, so it survives in the scrollback either way.
    #>
    param(
        [Parameter(Mandatory)]$Disk, [Parameter(Mandatory)]$Volume,
        [Parameter(Mandatory)][hashtable]$Plan, [Parameter(Mandatory)][hashtable]$ToolState,
        [string[]]$Warnings = @(), [switch]$DryRun
    )

    $label = if ($Volume.Label) { '"' + $Volume.Label + '" ' } else { '' }
    Write-Host ''
    Write-Host "StorageBench $script:SbVersion   preset $($Plan.Name)   $($Plan.Estimate)"
    Write-Host ''
    Write-Host "  drive      $($Volume.Letter): $label$($Volume.FileSystem)"
    Write-Host "  disk       #$($Disk.DiskNumber) $($Disk.Model) [$($Disk.BusType), reports $($Disk.MediaType)]"
    Write-Host "  capacity   $(Format-Bytes -Bytes $Volume.SizeBytes) total, $(Format-Bytes -Bytes $Volume.FreeBytes) free"
    Write-Host "  writes     $(Format-Bytes -Bytes $Plan.NeedBytes) under $($Volume.Letter):\.storagebench-scratch\, removed afterwards"
    Write-Host "  reserve    $(Format-Bytes -Bytes $Plan.ReserveBytes) of free space is never touched"

    $phases = [System.Collections.Generic.List[string]]::new()
    $phases.Add('identity'); $phases.Add('classify')
    if ($Plan.DoSmart) { $phases.Add('health') }
    if ($Plan.DoBench) { $phases.Add('bench') }
    if ($Plan.DoIntegrity) { $phases.Add("integrity $(Format-Bytes -Bytes ([long]$Plan.IntegrityMB * 1MB))") }
    if ($Plan.DoSurface) { $phases.Add("surface $($Plan.SurfaceRegions) regions") }
    Write-Host "  phases     $($phases -join ' -> ')"

    foreach ($n in @($Plan.Notes)) { Write-Host "  note       $n" }
    foreach ($w in @($ToolState.Warnings)) { Write-Host "  degraded   $w" }
    foreach ($w in @($Warnings)) { Write-Host "  degraded   $w" }
    if ($DryRun) { Write-Host '  dry run    nothing will be written; this is the plan only' }
    Write-Host ''
}

function Confirm-Run {
    <#
        A write test on someone's drive asks first. -Yes skips the question; a
        redirected stdin refuses rather than hanging a script on a prompt nobody
        can answer.
    #>
    [OutputType([bool])]
    param([switch]$Yes)
    if ($Yes) { return $true }
    if ([Console]::IsInputRedirected) {
        Write-Host 'Refusing to start: stdin is redirected, so consent cannot be asked for. Re-run with -Yes.'
        return $false
    }
    (Read-Host 'Proceed? [y/N]') -match '^(y|yes)$'
}

function Invoke-StorageBenchRun {
    <#
        The orchestration. Each phase is wrapped so that a phase which throws
        records an error and lets the rest of the run continue - a drive that
        fails mid-benchmark is exactly the drive whose report matters most.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][char]$Drive,
        [Parameter(Mandatory)][string]$Preset,
        [switch]$Yes, [switch]$NoNet, [switch]$FetchTools, [switch]$Plain,
        [switch]$DryRun, [switch]$Force, [int]$IntegritySizeGB = 0,
        [switch]$SkipIntegrity, [switch]$SkipBench, [switch]$SkipSmart, [switch]$NoClean
    )

    $letter = ([string]$Drive).ToUpperInvariant()[0]
    $errors = [System.Collections.Generic.List[string]]::new()
    $started = [datetime]::Now

    # ---- identity, before a single byte is written --------------------------
    $volume = Get-VolumeInfo -Drive $letter
    if (-not $volume -or -not $volume.Ready) {
        $why = if ($volume -and $volume.Reason) { $volume.Reason } else { 'the volume did not respond' }
        Write-Host "Cannot test ${letter}: - $why"
        return @{ ExitCode = 2 }
    }

    $disk = Resolve-TargetDisk -Drive $letter -Volume $volume
    if (-not $disk) {
        Write-Host "Cannot test ${letter}: - no physical disk could be matched to that letter."
        return @{ ExitCode = 2 }
    }

    $geometry = Get-VolumeGeometry -Drive $letter
    # A dry run writes nothing, so a protected volume is reported rather than
    # refused - you can always ask what a run would do.
    $writable = Test-VolumeWritableForTest -DiskInfo $disk -Drive $letter -Force:$Force
    if (-not $writable.Ok -and -not $DryRun) {
        Write-Host "Refusing to write to ${letter}: - $($writable.Reason)"
        return @{ ExitCode = 2 }
    }

    # ---- tools --------------------------------------------------------------
    $toolState = Get-ToolState
    if ($FetchTools -and $NoNet) {
        $toolState.Warnings += '-FetchTools was ignored because -NoNet forbids network access'
    } elseif ($FetchTools -and -not $DryRun) {
        foreach ($t in 'Smartctl', 'DiskSpd') {
            if (-not $toolState[$t].Ok) { $null = Invoke-ToolFetch -Tool $t -Consented }
        }
        $toolState = Get-ToolState
    }

    # ---- plan and consent ---------------------------------------------------
    $plan = Get-PresetPlan -Preset $Preset -VolumeBytes $volume.SizeBytes -FreeBytes $volume.FreeBytes `
        -IntegritySizeGB $IntegritySizeGB -SkipBench:$SkipBench -SkipIntegrity:$SkipIntegrity -SkipSmart:$SkipSmart

    $pre = [System.Collections.Generic.List[string]]::new()
    $reserve = Test-Reserve -Drive $letter -NeedBytes $plan.NeedBytes
    if (-not $reserve.Ok) { $pre.Add("space is tight: $($reserve.Reason)") }
    $orphans = @(Find-OrphanedScratch -Drive $letter)
    if ($orphans.Count -gt 0) { $pre.Add("$($orphans.Count) scratch folder(s) from an interrupted run are still on ${letter}: and will be removed") }
    if ($writable.Reason) { $pre.Add($writable.Reason) }

    Write-PreflightReport -Disk $disk -Volume $volume -Plan $plan -ToolState $toolState -Warnings $pre -DryRun:$DryRun

    if ($DryRun) {
        Write-Host 'Dry run complete. No bytes were written.'
        return @{ ExitCode = 0 }
    }
    if (-not $reserve.Ok) {
        Write-Host "Refusing to start: $($reserve.Reason)"
        return @{ ExitCode = 2 }
    }
    if (-not (Confirm-Run -Yes:$Yes)) {
        Write-Host 'Cancelled. Nothing was written.'
        return @{ ExitCode = 3 }
    }
    foreach ($o in $orphans) { $null = Remove-OrphanedScratch -Path $o }

    # ---- the writing part ---------------------------------------------------
    $ui = New-Ui -Mode $(if ($Plain) { 'plain' } else { 'auto' })
    $session = $null
    $classification = $null; $rvm = $null; $smart = $null
    $bench = $null; $perf = $null; $integrity = $null; $surface = $null
    $benchFile = ''

    try {
        $ui.Enter()
        $ui.ShowHeader("StorageBench $script:SbVersion   $($disk.Model)   ${letter}:   preset $($plan.Name)")

        $session = Initialize-Scratch -Drive $letter
        $ui.Note("scratch $($session.Root)")

        $ui.Phase('Identity')
        $ui.Metric('Model', $disk.Model, 'ok')
        $ui.Metric('Serial', $(if ($disk.SerialNumber) { $disk.SerialNumber } else { 'not reported by the bus' }), $(if ($disk.SerialNumber) { 'ok' } else { 'warn' }))
        $ui.Metric('Bus', "$($disk.BusType) - reports $($disk.MediaType)", 'ok')
        $ui.Metric('Capacity', "$(Format-Bytes -Bytes $volume.SizeBytes), $(Format-Bytes -Bytes $volume.FreeBytes) free", 'ok')
        if ($geometry) {
            $ui.Metric('Sectors', "$($geometry.PhysicalSectorBytes) physical / $($geometry.LogicalSectorBytes) logical, $($geometry.ClusterBytes) cluster", 'ok')
            $ui.Metric('TRIM', $(if ($geometry.TrimEnabled) { 'enabled' } else { 'not enabled' }), 'ok')
        }

        if (-not (Test-SbCancelled)) {
            $ui.Phase('Classify media')
            try {
                $classification = Invoke-MediaClassification -Drive $letter -Session $session `
                    -FileBytes $plan.ClassifyBytes -Samples $plan.ClassifySamples `
                    -ProgressCb (New-ProgressCallback -Ui $ui -Label 'random read probe')
                $ui.EndProgress()
                if ($classification.Ok) {
                    $rpm = if ($classification.RPM) { ", about $($classification.RPM) RPM" } else { '' }
                    $ui.Metric('Measured', "$($classification.Class)$rpm", 'ok')
                    $ui.Metric('Latency', "avg $(Format-Ms -Ms $classification.Latency.AvgMs), p99 $(Format-Ms -Ms $classification.Latency.P99), seek slope $([math]::Round([double]$classification.Latency.SeekSlopeMsPerGB, 4)) ms/GB", 'ok')
                    $ui.Metric('Confidence', $classification.Confidence, $(if ($classification.Confidence -in @('low', 'none')) { 'warn' } else { 'ok' }))
                    $rvm = Compare-ReportedVsMeasured -DiskInfo $disk -Classification $classification
                    if ($rvm -and -not $rvm.Agrees) { $ui.Warn($rvm.Note) }

                    # The drive has now told us what it is, so the rest of the
                    # run is retuned to suit it before a byte of it happens.
                    $before = @($plan.Notes).Count
                    $plan = Update-PlanForClass -Plan $plan -MeasuredClass ([string]$classification.Class) -BusType ([string]$disk.BusType)
                    $ui.Metric('Method', "tuned for $($plan.Method)", 'ok')
                    foreach ($n in @($plan.Notes) | Select-Object -Skip $before) { $ui.Note($n) }
                } else {
                    $ui.Warn("classification could not run: $($classification.Reason)")
                }
            } catch { $errors.Add("classify: $($_.Exception.Message)"); $ui.Warn("classify failed: $($_.Exception.Message)") }
        }

        if ($plan.DoSmart -and -not (Test-SbCancelled)) {
            $ui.Phase('Health (SMART)')
            try {
                $smart = Get-SmartReport -DiskInfo $disk -ToolState $toolState -IsAdmin (Get-IsAdmin)
                $ui.Metric('Status', "$($smart.Status) via $($smart.Source)", $(if ($smart.Status -eq 'Verified') { 'ok' } else { 'warn' }))
                if ($null -ne $smart.Temperature) { $ui.Metric('Temperature', "$($smart.Temperature) C", 'ok') }
                if ($null -ne $smart.PowerOnHours) { $ui.Metric('Power-on', "$($smart.PowerOnHours) hours", 'ok') }
                foreach ($f in @($smart.Failures)) { $ui.Warn($f) }
                foreach ($n in @($smart.Notes)) { $ui.Note($n) }
            } catch { $errors.Add("smart: $($_.Exception.Message)"); $ui.Warn("health read failed: $($_.Exception.Message)") }
        }

        if ($plan.DoBench -and -not (Test-SbCancelled)) {
            $ui.Phase('Benchmark')
            $bench = @{ SeqRead = $null; SeqWrite = $null; RndQd1 = $null; RndQdN = $null; Sustained = $null; Zones = $null }
            try {
                $mk = New-BenchFile -Session $session -Name 'bench.bin' -Bytes $plan.BenchBytes `
                    -ProgressCb (New-ProgressCallback -Ui $ui -Label 'laying down the test file')
                $ui.EndProgress()
                if (-not $mk.Ok) { throw "the test file could not be created: $($mk.Reason)" }
                $benchFile = $mk.Path

                $bench.SeqWrite = Measure-Sequential -File $benchFile -OpMode 'Write' -BytesPerRun $plan.BenchBytes -Block 1MB `
                    -ProgressCb (New-ProgressCallback -Ui $ui -Label 'sequential write')
                $ui.EndProgress()
                $ui.Metric('Sequential write', (Format-Mbps -MBps $bench.SeqWrite.MBps), 'ok')

                $bench.SeqRead = Measure-Sequential -File $benchFile -OpMode 'Read' -BytesPerRun $plan.BenchBytes -Block 1MB `
                    -ProgressCb (New-ProgressCallback -Ui $ui -Label 'sequential read')
                $ui.EndProgress()
                $ui.Metric('Sequential read', (Format-Mbps -MBps $bench.SeqRead.MBps), 'ok')

                if ($plan.Qd1Samples -gt 0 -and -not (Test-SbCancelled)) {
                    $bench.RndQd1 = Measure-RandomQd1 -File $benchFile -Samples $plan.Qd1Samples -Block 4096 `
                        -ProgressCb (New-ProgressCallback -Ui $ui -Label 'random 4K QD1')
                    $ui.EndProgress()
                    $ui.Metric('Random 4K QD1', "$(Format-IOPS -Iops $bench.RndQd1.IOPS), avg $(Format-Ms -Ms $bench.RndQd1.AvgMs)", 'ok')
                }

                if ($plan.QdNSamples -gt 0 -and -not (Test-SbCancelled)) {
                    $bench.RndQdN = Measure-RandomQdN -File $benchFile -QueueDepth $plan.QueueDepth -Samples $plan.QdNSamples -Block 4096 `
                        -ProgressCb (New-ProgressCallback -Ui $ui -Label "random 4K QD$($plan.QueueDepth)")
                    $ui.EndProgress()
                    $ui.Metric("Random 4K QD$($plan.QueueDepth)", (Format-IOPS -Iops $bench.RndQdN.IOPS), 'ok')
                }

                if ($plan.SustainedBytes -gt 0 -and -not (Test-SbCancelled)) {
                    $sustainedPath = Join-Path $session.Root 'sustained.bin'
                    Register-ScratchFile -Session $session -Path $sustainedPath
                    $bench.Sustained = Measure-SustainedWrite -File $sustainedPath -TotalBytes $plan.SustainedBytes `
                        -IntervalSec 1.0 -Block 4MB -SampleCb (New-ProgressCallback -Ui $ui -Label 'sustained write')
                    $ui.EndProgress()
                    $ui.Sparkline(@($bench.Sustained.SeriesMBps), 'sustained MB/s')
                    if ($bench.Sustained.CliffDetected) {
                        $ui.Warn("write speed fell away after $($bench.Sustained.CliffAtMB) MB - the cache is spent, sustained rate $(Format-Mbps -MBps $bench.Sustained.FinalMBps)")
                    }
                }

                if ($plan.Zones -gt 0 -and -not (Test-SbCancelled)) {
                    $bench.Zones = Measure-ZoneProfile -File $benchFile -Block 1MB -Zones $plan.Zones -BlocksPerZone 16 `
                        -ProgressCb (New-ProgressCallback -Ui $ui -Label 'zone profile')
                    $ui.EndProgress()
                    $ui.Sparkline(@($bench.Zones.ZoneMBps), 'MB/s by zone, outer to inner')
                }
            } catch { $errors.Add("bench: $($_.Exception.Message)"); $ui.Warn("benchmark failed: $($_.Exception.Message)") }
        }

        if ($plan.DoIntegrity -and -not (Test-SbCancelled)) {
            $ui.Phase("Integrity $(Format-Bytes -Bytes ([long]$plan.IntegrityMB * 1MB))")
            try {
                $integrity = Invoke-IntegrityScan -Volume $volume -Session $session -SizeMB $plan.IntegrityMB `
                    -Mode $plan.IntegrityMode -ProgressCb (New-ProgressCallback -Ui $ui -Label 'write and verify')
                $ui.EndProgress()
                $ui.Metric('Verified', "$(Format-Bytes -Bytes ([long]$integrity.VerifiedMB * 1MB)) - $($integrity.CoveragePct)% of the volume", $(if ($integrity.Ok) { 'ok' } else { 'fail' }))
                if (@($integrity.Errors).Count -gt 0) { $ui.Warn("$(@($integrity.Errors).Count) block(s) did not read back as written") }
                if ($integrity.CounterfeitSuspected) { $ui.Warn('distant blocks returned identical content - this drive may not hold the capacity it claims') }
                if (-not $integrity.Ok -and $integrity.Reason) { $ui.Warn($integrity.Reason) }
            } catch { $errors.Add("integrity: $($_.Exception.Message)"); $ui.Warn("integrity scan failed: $($_.Exception.Message)") }
        }

        if ($plan.DoSurface -and -not (Test-SbCancelled)) {
            $ui.Phase("Surface map, $($plan.SurfaceRegions) regions")
            try {
                $surface = Invoke-SurfaceScan -Volume $volume -Session $session -Regions $plan.SurfaceRegions `
                    -ExistingFile $benchFile -ProgressCb (New-ProgressCallback -Ui $ui -Label 'reading regions')
                $ui.EndProgress()
                $ui.BlockMap(@($surface.Regions), $true)
                $ui.Metric('Regions', "$(@($surface.Regions).Count) read, $($surface.WeakCount) weak, $(@($surface.Errors).Count) unreadable",
                    $(if (@($surface.Errors).Count -gt 0) { 'fail' } elseif ($surface.WeakCount -gt 0) { 'warn' } else { 'ok' }))
            } catch { $errors.Add("surface: $($_.Exception.Message)"); $ui.Warn("surface scan failed: $($_.Exception.Message)") }
        }

        if (Test-SbCancelled) { $errors.Add('the run was interrupted before every phase finished') }

        # ---- score, grade, report -------------------------------------------
        $ui.Phase('Verdict')
        $class = Get-DriveClass -Classification $classification -BusType ([string]$disk.BusType) `
            -SeqReadMBps $(if ($bench -and $bench.SeqRead) { $bench.SeqRead.MBps } else { $null })
        $perf = Get-PerformanceScore -BenchResults $bench -Class $class

        # Grade reads a view of the run rather than the run record itself: its
        # Performance is the class-relative score, while the record keeps the raw
        # numbers under Performance and the score under PerformanceScore, which
        # is the shape the JSON and HTML reports are built against.
        $grade = Invoke-Grade -Results @{
            Smart          = $smart
            Integrity      = $integrity
            Surface        = $surface
            Performance    = $perf
            Classification = $classification
            ToolState      = $toolState
            Errors         = @($errors)
        }

        $finished = [datetime]::Now
        $record = [ordered]@{
            Meta               = [ordered]@{
                Tool        = 'StorageBench'; Version = $script:SbVersion
                RunId       = $session.RunId
                StartedAt   = $started.ToString('o'); FinishedAt = $finished.ToString('o')
                DurationSec = [math]::Round(($finished - $started).TotalSeconds, 1)
                Preset      = $plan.Name; Drive = ([string]$letter)
                Machine     = [Environment]::MachineName
                PSVersion   = $PSVersionTable.PSVersion.ToString()
                Elevated    = (Get-IsAdmin); Interrupted = (Test-SbCancelled)
            }
            Disk               = $disk
            Volume             = $volume
            Geometry           = $geometry
            Plan               = $plan
            Classification     = $classification
            ReportedVsMeasured = $rvm
            Smart              = $smart
            Performance        = $bench
            PerformanceScore   = $perf
            Integrity          = $integrity
            Surface            = $surface
            Grade              = $grade
            ToolState          = $toolState
            Errors             = @($errors)
        }

        # A reader looks for the cluster size on the volume, so geometry is
        # merged in as well as kept whole.
        if ($geometry -and $record.Volume -is [System.Collections.IDictionary]) {
            foreach ($k in 'ClusterBytes', 'PhysicalSectorBytes', 'LogicalSectorBytes', 'TrimEnabled') {
                if ($geometry.Contains($k)) { $record.Volume[$k] = $geometry[$k] }
            }
        }

        $ui.ResultPanel($grade)

        $outDir = Join-Path $script:SbHome 'reports'
        try {
            $jsonPath = Export-RunJson -Results $record -OutDir $outDir
            $htmlPath = Export-RunHtml -Results $record -OutDir $outDir
            Update-History -Serial ([string]$disk.SerialNumber) -Line ([ordered]@{
                    RunId           = $session.RunId; Preset = $plan.Name; Drive = ([string]$letter)
                    Grade           = $grade.Letter; Score01 = $grade.Score01; Class = $class
                    SeqReadMBps     = $(if ($bench -and $bench.SeqRead) { $bench.SeqRead.MBps } else { $null })
                    SeqWriteMBps    = $(if ($bench -and $bench.SeqWrite) { $bench.SeqWrite.MBps } else { $null })
                    Qd1IOPS         = $(if ($bench -and $bench.RndQd1) { $bench.RndQd1.IOPS } else { $null })
                    SmartStatus     = $(if ($smart) { $smart.Status } else { 'not read' })
                    IntegrityMB     = $(if ($integrity) { $integrity.VerifiedMB } else { 0 })
                    IntegrityErrors = $(if ($integrity) { @($integrity.Errors).Count } else { 0 })
                })
            $ui.Note("json  $jsonPath")
            $ui.Note("html  $htmlPath")
        } catch {
            $errors.Add("report: $($_.Exception.Message)")
            $ui.Warn("the reports could not be written: $($_.Exception.Message)")
        }

        $ui.Footer()
        return @{ ExitCode = (Get-RunExitCode -Grade $grade -Aborted:(Test-SbCancelled)); Grade = $grade; Record = $record }
    } finally {
        try { $ui.Close() } catch { }
        if ($session) {
            if ($NoClean) {
                Write-Host "Scratch kept at $($session.Root) because -NoClean was given. Delete it when you are done."
            } else {
                try {
                    $cleaned = Clear-Scratch -Session $session
                    if ($cleaned.Failed -gt 0) {
                        Write-Host "Warning: $($cleaned.Failed) scratch file(s) could not be removed from $($session.Root)."
                        foreach ($e in @($cleaned.Errors)) { Write-Host "  $e" }
                    }
                } catch { Write-Host "Warning: scratch cleanup failed - remove $($session.Root) by hand. $($_.Exception.Message)" }
            }
        }
    }
}

# --------------------------------------------------------------------- entry

# Dot-sourcing this file (the tests do) defines the functions and stops there.
if ($MyInvocation.InvocationName -ne '.') {
    $sbFlagsRef = $script:SbFlags
    $sbHandler = $null
    try {
        $sbHandler = [ConsoleCancelEventHandler] {
            param($source, $eventArgs)
            # Cancel the kill so the finally block still gets to clean up.
            $eventArgs.Cancel = $true
            $sbFlagsRef['Cancelled'] = $true
            Write-Host ''
            Write-Host 'Interrupt received - finishing the current step, then cleaning up.'
        }.GetNewClosure()
        [Console]::add_CancelKeyPress($sbHandler)
    } catch { $sbHandler = $null }

    $sbExit = 3
    try {
        $sbResult = Invoke-StorageBenchRun -Drive $Drive -Preset $Preset -Yes:$Yes -NoNet:$NoNet `
            -FetchTools:$FetchTools -Plain:$Plain -DryRun:$DryRun -Force:$Force `
            -IntegritySizeGB $IntegritySizeGB -SkipIntegrity:$SkipIntegrity -SkipBench:$SkipBench `
            -SkipSmart:$SkipSmart -NoClean:$NoClean
        $sbExit = [int]$sbResult.ExitCode
    } catch {
        Write-Host "StorageBench stopped: $($_.Exception.Message)"
        if ($_.ScriptStackTrace) { Write-Verbose $_.ScriptStackTrace }
        $sbExit = 3
    } finally {
        if ($sbHandler) { try { [Console]::remove_CancelKeyPress($sbHandler) } catch { } }
    }
    exit $sbExit
}
