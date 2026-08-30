<#
    Expectations.ps1 - what should this drive be doing?

    A number on its own means nothing. 90 MB/s is a dying SSD and a perfectly
    healthy USB hard disk. So every measurement is scored against the class of
    device the drive actually behaves like - never against the class printed on
    its box.

    Each class carries three points per metric:

        Min  the floor a working example of this class clears
        Typ  what a healthy, unremarkable example does
        Max  the best the interface allows - the point beyond which more
             is not evidence of anything

    Scores map Min -> 0.35, Typ -> 0.70, Max -> 1.00, so a drive that merely
    works scores a third, a normal drive scores a solid pass, and only genuinely
    fast hardware approaches 1. Nothing is scored on a curve against other
    drives; the yardstick is fixed and published here so a reader can disagree
    with it.
#>

$script:SbExpectations = @{
    'NVMe-Gen5' = @{
        Label = 'PCIe 5.0 NVMe SSD'
        SeqReadMBps  = @{ Min = 6000; Typ = 11000; Max = 14500 }
        SeqWriteMBps = @{ Min = 4000; Typ = 9000; Max = 13000 }
        RndQd1IOPS   = @{ Min = 12000; Typ = 18000; Max = 26000 }
        RndQdNIOPS   = @{ Min = 150000; Typ = 600000; Max = 1500000 }
        LatencyMs    = @{ Min = 0.12; Typ = 0.055; Max = 0.025 }
    }
    'NVMe-Gen4' = @{
        Label = 'PCIe 4.0 NVMe SSD'
        SeqReadMBps  = @{ Min = 3200; Typ = 6800; Max = 7500 }
        SeqWriteMBps = @{ Min = 2200; Typ = 5000; Max = 7000 }
        RndQd1IOPS   = @{ Min = 10000; Typ = 16000; Max = 23000 }
        RndQdNIOPS   = @{ Min = 100000; Typ = 400000; Max = 800000 }
        LatencyMs    = @{ Min = 0.14; Typ = 0.062; Max = 0.030 }
    }
    'NVMe-Gen3' = @{
        Label = 'PCIe 3.0 NVMe SSD'
        SeqReadMBps  = @{ Min = 1400; Typ = 3200; Max = 3700 }
        SeqWriteMBps = @{ Min = 900; Typ = 2600; Max = 3400 }
        RndQd1IOPS   = @{ Min = 7000; Typ = 13000; Max = 20000 }
        RndQdNIOPS   = @{ Min = 60000; Typ = 250000; Max = 450000 }
        LatencyMs    = @{ Min = 0.20; Typ = 0.077; Max = 0.040 }
    }
    'SATA-SSD' = @{
        Label = 'SATA solid-state drive'
        SeqReadMBps  = @{ Min = 380; Typ = 530; Max = 565 }
        SeqWriteMBps = @{ Min = 300; Typ = 490; Max = 545 }
        RndQd1IOPS   = @{ Min = 4000; Typ = 9000; Max = 15000 }
        RndQdNIOPS   = @{ Min = 25000; Typ = 70000; Max = 98000 }
        LatencyMs    = @{ Min = 0.30; Typ = 0.111; Max = 0.060 }
    }
    'USB-SSD' = @{
        Label = 'external solid-state drive'
        SeqReadMBps  = @{ Min = 200; Typ = 900; Max = 1080 }
        SeqWriteMBps = @{ Min = 160; Typ = 800; Max = 1030 }
        RndQd1IOPS   = @{ Min = 1500; Typ = 6000; Max = 13000 }
        RndQdNIOPS   = @{ Min = 6000; Typ = 30000; Max = 70000 }
        LatencyMs    = @{ Min = 0.80; Typ = 0.166; Max = 0.070 }
    }
    'HDD-7200' = @{
        Label = '7200 RPM hard disk'
        SeqReadMBps  = @{ Min = 80; Typ = 180; Max = 270 }
        SeqWriteMBps = @{ Min = 75; Typ = 170; Max = 255 }
        RndQd1IOPS   = @{ Min = 55; Typ = 110; Max = 200 }
        RndQdNIOPS   = @{ Min = 70; Typ = 160; Max = 320 }
        LatencyMs    = @{ Min = 18.0; Typ = 9.0; Max = 5.0 }
    }
    'HDD-5400' = @{
        Label = '5400 RPM hard disk'
        SeqReadMBps  = @{ Min = 55; Typ = 120; Max = 190 }
        SeqWriteMBps = @{ Min = 50; Typ = 110; Max = 180 }
        RndQd1IOPS   = @{ Min = 38; Typ = 85; Max = 145 }
        RndQdNIOPS   = @{ Min = 50; Typ = 120; Max = 230 }
        LatencyMs    = @{ Min = 26.0; Typ = 11.8; Max = 6.9 }
    }
    'USB-HDD' = @{
        Label = 'external hard disk'
        SeqReadMBps  = @{ Min = 30; Typ = 95; Max = 145 }
        SeqWriteMBps = @{ Min = 28; Typ = 90; Max = 140 }
        RndQd1IOPS   = @{ Min = 33; Typ = 80; Max = 135 }
        RndQdNIOPS   = @{ Min = 42; Typ = 110; Max = 210 }
        LatencyMs    = @{ Min = 30.0; Typ = 12.5; Max = 7.4 }
    }
}

# Relative importance inside the performance score. Random access is weighted
# as heavily as streaming because it is what makes a drive feel fast, and
# consistency is scored separately so a drive that starts fast and collapses
# cannot hide behind its first ten seconds.
$script:SbPerfWeights = @{
    SeqReadMBps  = 0.25
    SeqWriteMBps = 0.25
    RndQd1IOPS   = 0.25
    RndQdNIOPS   = 0.15
    Consistency  = 0.10
}

function Get-DriveClass {
    <#
        Which yardstick applies. Driven by measured behaviour first and bus type
        second; the reported MediaType is never consulted.

        Returns one of: NVMe-Gen5 NVMe-Gen4 NVMe-Gen3 SATA-SSD USB-SSD
                        HDD-7200 HDD-5400 USB-HDD
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$Classification,
        [Parameter(Mandatory)][AllowNull()][string]$BusType,
        [AllowNull()][object]$SeqReadMBps = $null
    )

    $measured = if ($Classification -and $Classification.Class) { [string]$Classification.Class } else { 'Unknown' }
    $rpm = if ($Classification -and $Classification.RPM) { [int]$Classification.RPM } else { 0 }
    $bus = if ($BusType) { [string]$BusType } else { '' }
    $external = ($bus -match 'USB|1394|SD$|MMC')

    if ($measured -eq 'HDD') {
        if ($external) { return 'USB-HDD' }
        if ($rpm -ge 7200) { return 'HDD-7200' }
        return 'HDD-5400'
    }

    if ($measured -eq 'NVMe' -or ($bus -eq 'NVMe' -and $measured -ne 'HDD')) {
        # Generation is only knowable from throughput, so an unmeasured drive is
        # held to the Gen3 bar: the lowest, least flattering of the three.
        if ($null -ne $SeqReadMBps) {
            $r = [double]$SeqReadMBps
            if ($r -ge 8000) { return 'NVMe-Gen5' }
            if ($r -ge 4200) { return 'NVMe-Gen4' }
        }
        return 'NVMe-Gen3'
    }

    if ($measured -eq 'SSD') {
        if ($external) { return 'USB-SSD' }
        return 'SATA-SSD'
    }

    # Nothing conclusive. Judge it by where it is plugged in, which at least
    # cannot flatter it.
    if ($external) { return 'USB-HDD' }
    if ($bus -match 'SATA|ATA|SAS|SCSI|RAID') { return 'SATA-SSD' }
    'HDD-7200'
}

function Get-ExpectedRange {
    <# The published Min/Typ/Max table for one class, plus its human label. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Class)

    if ($script:SbExpectations.ContainsKey($Class)) { return $script:SbExpectations[$Class] }
    $script:SbExpectations['HDD-7200']
}

function Get-MetricScore {
    <#
        One metric against its band. Returns 0..1.

        Min -> 0.35, Typ -> 0.70, Max -> 1.00, clamped at both ends. When
        $LowerIsBetter the band runs downwards (latency), and the same anchors
        apply in reverse.
    #>
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][hashtable]$Band,
        [switch]$LowerIsBetter
    )

    if ($null -eq $Value) { return 0.0 }
    $v = [double]$Value
    $min = [double]$Band.Min
    $typ = [double]$Band.Typ
    $max = [double]$Band.Max

    if ($LowerIsBetter) {
        # Reflect the scale so the same arithmetic works.
        $v = -$v; $min = -$min; $typ = -$typ; $max = -$max
    }

    if ($v -ge $max) { return 1.0 }
    if ($v -ge $typ) {
        $span = $max - $typ
        if ($span -le 0) { return 1.0 }
        return [double](0.70 + 0.30 * (($v - $typ) / $span))
    }
    if ($v -ge $min) {
        $span = $typ - $min
        if ($span -le 0) { return 0.70 }
        return [double](0.35 + 0.35 * (($v - $min) / $span))
    }
    # Below the floor: scale linearly to zero so "half the minimum" still
    # scores something and a dead result scores nothing.
    if ($min -eq 0) { return 0.0 }
    $frac = if ($LowerIsBetter) { $min / [math]::Max([double]$Value, 0.000001) } else { $v / $min }
    [double][math]::Max(0.0, [math]::Min(0.35, 0.35 * $frac))
}

function Get-ConsistencyScore {
    <#
        Does the drive hold its speed? Returns @{Score01;Note}.

        A sustained-write cliff is normal on consumer flash and is reported, not
        punished to zero - but a drive that keeps only a third of its opening
        speed will feel slow in real use, and the score says so. Mechanical
        drives have no SLC cache, so a flat line here is expected rather than
        impressive.
    #>
    [OutputType([hashtable])]
    param([AllowNull()][hashtable]$Sustained, [AllowNull()][hashtable]$Zones)

    $parts = [System.Collections.Generic.List[double]]::new()
    $notes = [System.Collections.ArrayList]::new()

    if ($Sustained -and $null -ne $Sustained.FinalMBps -and $Sustained.SeriesMBps -and @($Sustained.SeriesMBps).Count -gt 0) {
        $series = @($Sustained.SeriesMBps)
        $head = [double]$series[0]
        if ($head -gt 0) {
            $ratio = [double]$Sustained.FinalMBps / $head
            $parts.Add([double][math]::Max(0.0, [math]::Min(1.0, $ratio)))
            if ($Sustained.CliffDetected) {
                $atMB = if ($null -ne $Sustained.CliffAtMB) { [int]$Sustained.CliffAtMB } else { 0 }
                [void]$notes.Add("write speed fell off after about $atMB MB, ending at $([math]::Round($ratio * 100))% of its opening rate")
            } else {
                [void]$notes.Add('write speed held steady for the whole run')
            }
        }
    }

    if ($Zones -and $null -ne $Zones.FalloffFrac) {
        # Outer-to-inner falloff: expected on a platter, meaningless on flash.
        $keep = 1.0 - [double]$Zones.FalloffFrac
        $parts.Add([double][math]::Max(0.0, [math]::Min(1.0, $keep)))
        [void]$notes.Add("end-of-media read speed is $([math]::Round($keep * 100))% of start-of-media")
    }

    if ($parts.Count -eq 0) { return @{ Score01 = $null; Note = 'not measured' } }
    @{ Score01 = [double](($parts | Measure-Object -Average).Average); Note = (($notes) -join '; ') }
}

function Get-PerformanceScore {
    <#
        Weighted performance score for a bench aggregate.

        $BenchResults is @{SeqRead;SeqWrite;RndQd1;RndQdN;Sustained;Zones} with
        $null for any phase that did not run. Missing phases are dropped and the
        remaining weights renormalised, so a Quick run is scored on what it
        actually measured rather than penalised for what it skipped.

        Returns @{Score01;Metrics;Class;Label;Weights;Note}
        where Metrics is one record per scored metric:
            @{Name;Value;Unit;Min;Typ;Max;Score01;Weight;Verdict}
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$BenchResults,
        [Parameter(Mandatory)][string]$Class
    )

    $exp = Get-ExpectedRange -Class $Class
    $out = @{
        Score01 = $null; Metrics = @(); Class = $Class
        Label = [string]$exp.Label; Weights = @{}; Note = ''
    }
    if ($null -eq $BenchResults) { $out.Note = 'no benchmark results'; return $out }

    $metrics = [System.Collections.ArrayList]::new()

    $add = {
        param($name, $unit, $value, $bandKey, $weightKey, $lower)
        $band = $exp[$bandKey]
        $score = if ($lower) { Get-MetricScore -Value $value -Band $band -LowerIsBetter }
        else { Get-MetricScore -Value $value -Band $band }
        $verdict = if ($null -eq $value) { 'not measured' }
        elseif ($score -ge 0.70) { 'at or above expectation' }
        elseif ($score -ge 0.35) { 'below typical but within range' }
        else { 'below the floor for this class' }
        [void]$metrics.Add([pscustomobject]@{
                Name    = $name
                Value   = $value
                Unit    = $unit
                Min     = $band.Min
                Typ     = $band.Typ
                Max     = $band.Max
                Score01 = [double]$score
                Weight  = [double]$script:SbPerfWeights[$weightKey]
                Verdict = $verdict
                Scored  = ($null -ne $value)
            })
    }

    $seqRead = if ($BenchResults.SeqRead) { $BenchResults.SeqRead.MBps } else { $null }
    $seqWrite = if ($BenchResults.SeqWrite) { $BenchResults.SeqWrite.MBps } else { $null }
    $qd1 = if ($BenchResults.RndQd1) { $BenchResults.RndQd1.IOPS } else { $null }
    $qdN = if ($BenchResults.RndQdN) { $BenchResults.RndQdN.IOPS } else { $null }

    & $add 'Sequential read' 'MB/s' $seqRead 'SeqReadMBps' 'SeqReadMBps' $false
    & $add 'Sequential write' 'MB/s' $seqWrite 'SeqWriteMBps' 'SeqWriteMBps' $false
    & $add 'Random read 4K QD1' 'IOPS' $qd1 'RndQd1IOPS' 'RndQd1IOPS' $false
    & $add 'Random read 4K QD32' 'IOPS' $qdN 'RndQdNIOPS' 'RndQdNIOPS' $false

    $cons = Get-ConsistencyScore -Sustained $BenchResults.Sustained -Zones $BenchResults.Zones
    [void]$metrics.Add([pscustomobject]@{
            Name    = 'Consistency'
            Value   = if ($null -ne $cons.Score01) { [double][math]::Round($cons.Score01 * 100, 1) } else { $null }
            Unit    = '% of opening speed retained'
            Min     = 35; Typ = 70; Max = 100
            Score01 = if ($null -ne $cons.Score01) { [double]$cons.Score01 } else { 0.0 }
            Weight  = [double]$script:SbPerfWeights['Consistency']
            Verdict = $cons.Note
            Scored  = ($null -ne $cons.Score01)
        })

    $scored = @($metrics | Where-Object { $_.Scored })
    if ($scored.Count -eq 0) { $out.Metrics = @($metrics); $out.Note = 'nothing measurable'; return $out }

    $wsum = ($scored | Measure-Object -Property Weight -Sum).Sum
    $acc = 0.0
    foreach ($m in $scored) { $acc += $m.Score01 * ($m.Weight / $wsum) }

    foreach ($m in $scored) { $out.Weights[$m.Name] = [double][math]::Round($m.Weight / $wsum, 4) }
    $out.Metrics = @($metrics)
    $out.Score01 = [double][math]::Max(0.0, [math]::Min(1.0, $acc))
    $out.Note = "scored against $($exp.Label) expectations"
    $out
}
