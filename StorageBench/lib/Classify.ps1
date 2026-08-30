<#
    Classify.ps1 - decide what the drive really is.

    The bus can lie. On the machine this was built against, D: reports
    MediaType 'Unspecified' and SpindleSpeed $null through a USB bridge, while
    measuring 8.4 ms average random read and 117 IOPS at QD1 - numbers only a
    spinning 5400 RPM platter produces.

    So classification here is behavioural: measure access latency and how it
    grows with seek distance, then say what the physics implies. The reported
    MediaType is recorded as a claim, never used as an answer.
#>

function Measure-ReadLatency {
    <#
        Random-read latency, optionally at caller-chosen offsets so the caller
        can build a seek-distance curve.
        Returns @{AvgMs;P50;P95;P99;MaxMs;SeekSlopeMsPerGB;Samples;Points;Mode}.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [int]$Samples = 128,
        [int]$Block = 4096,
        [AllowNull()][AllowEmptyCollection()][long[]]$Positions,
        [scriptblock]$ProgressCb
    )

    $empty = @{
        AvgMs = $null; P50 = $null; P95 = $null; P99 = $null; MaxMs = $null
        SeekSlopeMsPerGB = 0.0; Samples = @(); Points = @(); Mode = 'none'; Reason = ''
    }

    $open = New-BenchStream -Path $FilePath -Access Read -Mode Open
    if (-not $open.Stream) { $empty.Reason = $open.Reason; return $empty }

    $buf = New-BenchBuffer -Size $Block
    $lat = [System.Collections.Generic.List[double]]::new()
    $points = [System.Collections.Generic.List[psobject]]::new()
    $sw = [System.Diagnostics.Stopwatch]::new()

    try {
        $len = $open.Stream.Length
        $offsets = if ($Positions -and $Positions.Count -gt 0) { $Positions }
        else { Get-AlignedOffsets -FileBytes $len -Block $Block -Count $Samples -Seed 0xC1A55 }

        $prev = 0L
        for ($i = 0; $i -lt $offsets.Count; $i++) {
            $off = [long]$offsets[$i]
            if ($off -ge $len) { $off = [long]([math]::Floor(($len - $Block) / $Block) * $Block) }
            if ($off -lt 0) { $off = 0 }

            $open.Stream.Position = $off
            $sw.Restart()
            [void]$open.Stream.Read($buf, 0, $Block)
            $sw.Stop()

            $ms = $sw.Elapsed.TotalMilliseconds
            $lat.Add($ms)
            $points.Add([pscustomobject]@{
                    Offset     = $off
                    DistanceGB = [double]([math]::Abs($off - $prev) / 1GB)
                    Ms         = [double]$ms
                })
            $prev = $off
            if ($ProgressCb -and ($i % 16) -eq 0) { & $ProgressCb ($i + 1) $offsets.Count }
        }
    } catch {
        $empty.Reason = $_.Exception.Message
        $empty.Mode = $open.Mode
        return $empty
    } finally {
        try { $open.Stream.Dispose() } catch { }
    }

    if ($lat.Count -eq 0) { $empty.Mode = $open.Mode; $empty.Reason = 'no samples'; return $empty }

    @{
        AvgMs            = [double](($lat | Measure-Object -Average).Average)
        P50              = Get-Percentile -Values $lat -P 50
        P95              = Get-Percentile -Values $lat -P 95
        P99              = Get-Percentile -Values $lat -P 99
        MaxMs            = [double](($lat | Measure-Object -Maximum).Maximum)
        SeekSlopeMsPerGB = Get-SeekSlope -Points $points
        Samples          = @($lat)
        Points           = @($points)
        BlockSize        = $Block
        Mode             = $open.Mode
        Reason           = ''
    }
}

function Classify-Latency {
    <#
        Turn a latency profile into a media verdict.
        Returns @{Class;RPM;Confidence;Evidence}.

        Class is one of NVMe, SSD, HDD, Unknown. The thresholds come from
        physics, not from a vendor string: flash has no moving parts, so its
        access time is flat and sub-millisecond; a platter must physically move
        a head, which costs milliseconds and grows with distance.

        Bands are calibrated for short-stroke access inside a test file, which is
        faster than a drive's full-stroke spec sheet figure.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowNull()][hashtable]$Latency)

    $unknown = @{ Class = 'Unknown'; RPM = $null; Confidence = 'none'; Evidence = @('no latency samples') }
    if ($null -eq $Latency -or $null -eq $Latency.AvgMs) { return $unknown }

    $avg = [double]$Latency.AvgMs
    $p95 = if ($null -ne $Latency.P95) { [double]$Latency.P95 } else { $avg }
    $slope = if ($null -ne $Latency.SeekSlopeMsPerGB) { [double]$Latency.SeekSlopeMsPerGB } else { 0.0 }
    $ev = [System.Collections.ArrayList]::new()
    [void]$ev.Add("avg random read {0:0.000} ms" -f $avg)
    [void]$ev.Add("p95 {0:0.000} ms" -f $p95)
    [void]$ev.Add("seek slope {0:0.0000} ms/GB" -f $slope)

    $class = 'Unknown'; $rpm = $null; $conf = 'low'

    if ($avg -lt 0.30) {
        $class = 'NVMe'; $conf = 'high'
        [void]$ev.Add('sub-0.3 ms access: only PCIe flash reaches this')
    } elseif ($avg -lt 1.50) {
        $class = 'SSD'; $conf = 'high'
        [void]$ev.Add('sub-1.5 ms access with no seek penalty: solid state')
    } elseif ($avg -lt 3.00) {
        if ($slope -gt 0.02) {
            $class = 'HDD'; $rpm = 7200; $conf = 'low'
            [void]$ev.Add('fast but seek-sensitive: short-stroked mechanical or cached platter')
        } else {
            $class = 'SSD'; $conf = 'medium'
            [void]$ev.Add('flat latency curve: solid state behind a slow bridge')
        }
    } else {
        $class = 'HDD'
        $rpm = if ($avg -ge 7.0) { 5400 } else { 7200 }
        $conf = if ($slope -gt 0.05 -or $p95 -gt ($avg * 1.5)) { 'high' } else { 'medium' }
        [void]$ev.Add("multi-millisecond access: a head is physically moving")
        [void]$ev.Add("latency band implies ~$rpm RPM")
    }

    @{ Class = $class; RPM = $rpm; Confidence = $conf; Evidence = @($ev) }
}

function Invoke-MediaClassification {
    <#
        Full behavioural probe on a volume. Creates a scratch file, measures
        random access and a seek ladder, and returns measured facts only:

            @{Ok;Class;RPM;Confidence;Evidence;Latency;Ladder;FileBytes;Reason}

        The reported-versus-measured comparison is the caller's job - this
        function deliberately never reads MediaType, so it cannot be fooled by it.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][char]$Drive,
        [Parameter(Mandatory)][hashtable]$Session,
        [long]$FileBytes = 512MB,
        [int]$Samples = 128,
        [scriptblock]$ProgressCb
    )

    $res = @{
        Ok = $false; Class = 'Unknown'; RPM = $null; Confidence = 'none'
        Evidence = @(); Latency = $null; Ladder = @(); FileBytes = 0L; Reason = ''
    }

    $reserve = Test-Reserve -Drive $Drive -NeedBytes $FileBytes
    if (-not $reserve.Ok) {
        # Try again at a quarter size before giving up - classification needs
        # far less room than the benchmarks do.
        $FileBytes = [long]($FileBytes / 4)
        $reserve = Test-Reserve -Drive $Drive -NeedBytes $FileBytes
        if (-not $reserve.Ok) { $res.Reason = $reserve.Reason; return $res }
    }

    $mk = New-BenchFile -Session $Session -Name 'classify.bin' -Bytes $FileBytes -ProgressCb $ProgressCb
    if (-not $mk.Ok) { $res.Reason = $mk.Reason; return $res }
    $res.FileBytes = $mk.Bytes

    $lat = Measure-ReadLatency -FilePath $mk.Path -Samples $Samples -Block 4096 -ProgressCb $ProgressCb
    if ($null -eq $lat.AvgMs) { $res.Reason = $lat.Reason; return $res }
    $res.Latency = $lat

    # Seek ladder: alternate between offset 0 and a growing distance, so each
    # measured latency is dominated by one known seek length.
    $ladder = [System.Collections.Generic.List[psobject]]::new()
    $fractions = @(0.02, 0.05, 0.10, 0.25, 0.50, 0.75, 1.00)
    $positions = [System.Collections.Generic.List[long]]::new()
    foreach ($f in $fractions) {
        $target = [long]([math]::Floor((($mk.Bytes - 4096) * $f) / 4096) * 4096)
        if ($target -lt 0) { $target = 0 }
        for ($rep = 0; $rep -lt 4; $rep++) {
            $positions.Add(0L)
            $positions.Add($target)
        }
    }
    $ladderLat = Measure-ReadLatency -FilePath $mk.Path -Block 4096 -Positions $positions.ToArray()
    if ($ladderLat.Points) {
        # Keep only the long-seek half of each pair.
        $idx = 0
        foreach ($p in $ladderLat.Points) {
            if (($idx % 2) -eq 1) { [void]$ladder.Add($p) }
            $idx++
        }
    }
    $res.Ladder = @($ladder)

    $verdict = Classify-Latency -Latency @{
        AvgMs            = $lat.AvgMs
        P95              = $lat.P95
        SeekSlopeMsPerGB = if ($ladder.Count -ge 2) { Get-SeekSlope -Points $ladder } else { $lat.SeekSlopeMsPerGB }
    }

    $res.Ok = $true
    $res.Class = $verdict.Class
    $res.RPM = $verdict.RPM
    $res.Confidence = $verdict.Confidence
    $res.Evidence = @($verdict.Evidence)
    $res
}

function Compare-ReportedVsMeasured {
    <#
        Did the bus tell the truth? Returns @{Mismatch;Reported;Measured;Note}.
        Used by the entry point so the report can call out a lying enclosure.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$DiskInfo,
        [Parameter(Mandatory)][AllowNull()][hashtable]$Classification
    )

    $reported = if ($DiskInfo -and $DiskInfo.MediaType) { [string]$DiskInfo.MediaType } else { 'Unspecified' }
    $measured = if ($Classification) { [string]$Classification.Class } else { 'Unknown' }

    $normReported = switch -Regex ($reported) {
        'SSD' { 'SSD' } 'HDD' { 'HDD' } 'NVMe' { 'NVMe' } default { 'Unspecified' }
    }
    if ($DiskInfo -and $DiskInfo.BusType -eq 'NVMe' -and $normReported -eq 'SSD') { $normReported = 'NVMe' }

    $mismatch = $false
    $note = ''
    if ($measured -eq 'Unknown') {
        $note = 'measurement inconclusive; reported type left unchallenged'
    } elseif ($normReported -eq 'Unspecified') {
        $mismatch = $true
        $note = "the bus reported no media type; measurement says $measured"
    } elseif ($normReported -ne $measured) {
        $mismatch = $true
        $note = "the bus reported $normReported but the drive behaves like $measured"
    } else {
        $note = "reported and measured agree: $measured"
    }

    @{ Mismatch = [bool]$mismatch; Reported = $reported; Measured = $measured; Note = $note }
}
