<#
    Bench.ps1 - the I/O engine.

    Every measurement here goes through New-BenchStream, which asks Windows for
    FILE_FLAG_NO_BUFFERING (FileOptions 0x20000000). That flag is the whole point:
    without it the OS file cache answers most requests and the "drive" you measure
    is DDR. With it, each read and write reaches the device.

    Unbuffered I/O carries hard rules - offsets, counts and buffer sizes must all
    be multiples of the volume's physical sector size - so callers pass sector
    multiples and New-BenchStream degrades honestly (recording the mode it got)
    rather than silently producing cache-flavoured numbers.

    These primitives are shared: Classify, Integrity and Surface all open their
    streams here.
#>

$script:SbNoBuffering = [System.IO.FileOptions]0x20000000
$script:SbDefaultBlock = 1MB

function New-BenchStream {
    <#
        Opens a FileStream for device-truth I/O.
        Returns @{Stream;Mode;Reason} where Mode is 'unbuffered', 'writethrough'
        or 'buffered'. Never returns a half-open handle: on total failure Stream
        is $null and Reason says why.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Read', 'Write', 'ReadWrite')][string]$Access = 'Read',
        [ValidateSet('Open', 'Create', 'OpenOrCreate')][string]$Mode = 'Open',
        [int]$BufferSize = 0,
        [switch]$Async,
        [switch]$AllowBuffered
    )

    $fm = [System.IO.FileMode]::$Mode
    $fa = [System.IO.FileAccess]::$Access
    $share = [System.IO.FileShare]::Read

    # FileStream demands bufferSize >= 1; 1 means "no extra managed buffer",
    # which is exactly right when the OS cache is already out of the picture.
    $bs = if ($BufferSize -gt 0) { $BufferSize } else { 1 }

    $attempts = @(
        @{ Name = 'unbuffered'; Options = $script:SbNoBuffering -bor [System.IO.FileOptions]::WriteThrough }
        @{ Name = 'writethrough'; Options = [System.IO.FileOptions]::WriteThrough }
    )
    if ($AllowBuffered) { $attempts += @{ Name = 'buffered'; Options = [System.IO.FileOptions]::None } }

    $lastErr = ''
    foreach ($a in $attempts) {
        $opts = $a.Options
        if ($Async) { $opts = $opts -bor [System.IO.FileOptions]::Asynchronous }
        try {
            $fs = [System.IO.FileStream]::new($Path, $fm, $fa, $share, $bs, $opts)
            return @{ Stream = $fs; Mode = $a.Name; Reason = '' }
        } catch {
            $lastErr = $_.Exception.Message
        }
    }
    @{ Stream = $null; Mode = 'none'; Reason = $lastErr }
}

function New-BenchBuffer {
    <#
        Pinned buffer of incompressible bytes. Pinned because unbuffered I/O
        wants a stable, aligned address; incompressible because a controller that
        compresses zeroes would report a fantasy write speed.
    #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][int]$Size,
        [int]$Seed = 0x5B0BEEF
    )
    $buf = [System.GC]::AllocateArray[byte]($Size, $true)
    $rs = New-RandomStream -Seed $Seed
    try { $rs.NextBytes($buf) } finally { $rs.Dispose() }
    $buf
}

function New-BenchFile {
    <#
        Creates (or reuses) a scratch test file of exactly $Bytes, filled with
        incompressible data. Registers with the safety manifest before creating.
        Returns @{Ok;Path;Bytes;Mode;Reason}.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][long]$Bytes,
        [int]$Block = 0,
        [scriptblock]$ProgressCb
    )

    $block = if ($Block -gt 0) { $Block } else { $script:SbDefaultBlock }
    $path = Register-ScratchFile -Session $Session -Path (Join-Path $Session.Root $Name)

    if (Test-Path -LiteralPath $path) {
        try {
            $existing = (Get-Item -LiteralPath $path).Length
            if ($existing -ge $Bytes) { return @{ Ok = $true; Path = $path; Bytes = $existing; Mode = 'reused'; Reason = '' } }
        } catch { }
    }

    $open = New-BenchStream -Path $path -Access Write -Mode Create
    if (-not $open.Stream) { return @{ Ok = $false; Path = $path; Bytes = 0L; Mode = 'none'; Reason = $open.Reason } }

    $buf = New-BenchBuffer -Size $block
    $written = 0L
    try {
        while ($written -lt $Bytes) {
            $chunk = [int][math]::Min([long]$block, $Bytes - $written)
            if ($chunk -lt $block) { $chunk = $block }   # keep writes sector-aligned; trailing slack is harmless
            $open.Stream.Write($buf, 0, $chunk)
            $written += $chunk
            if ($ProgressCb) { & $ProgressCb $written $Bytes }
        }
        $open.Stream.Flush($true)
    } catch {
        return @{ Ok = $false; Path = $path; Bytes = $written; Mode = $open.Mode; Reason = $_.Exception.Message }
    } finally {
        try { $open.Stream.Dispose() } catch { }
    }

    @{ Ok = $true; Path = $path; Bytes = $written; Mode = $open.Mode; Reason = '' }
}

function Measure-Sequential {
    <#
        Straight-line throughput. Returns @{MBps;Seconds;Bytes;PeakMBps;Mode}.
        PeakMBps is the best 1-second window - the number a drive's box quotes,
        kept separate from the honest average.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][ValidateSet('Read', 'Write')][string]$OpMode,
        [Parameter(Mandatory)][long]$BytesPerRun,
        [int]$Block = 0,
        [scriptblock]$ProgressCb
    )

    $block = if ($Block -gt 0) { $Block } else { $script:SbDefaultBlock }
    $access = if ($OpMode -eq 'Read') { 'Read' } else { 'Write' }
    $fileMode = if ($OpMode -eq 'Read') { 'Open' } else { 'OpenOrCreate' }

    $open = New-BenchStream -Path $File -Access $access -Mode $fileMode
    if (-not $open.Stream) {
        return @{ MBps = $null; Seconds = 0.0; Bytes = 0L; PeakMBps = $null; Mode = 'none'; Reason = $open.Reason }
    }

    $buf = New-BenchBuffer -Size $block
    $total = 0L
    $peak = 0.0
    $windowBytes = 0L
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $windowSw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $limit = $BytesPerRun
        if ($OpMode -eq 'Read') {
            $len = $open.Stream.Length
            if ($len -lt $limit) { $limit = $len }
        }
        while ($total -lt $limit) {
            if ($OpMode -eq 'Read') {
                $n = $open.Stream.Read($buf, 0, $block)
                if ($n -le 0) { break }
                $total += $n
                $windowBytes += $n
            } else {
                $open.Stream.Write($buf, 0, $block)
                $total += $block
                $windowBytes += $block
            }

            if ($windowSw.Elapsed.TotalSeconds -ge 1.0) {
                $wmb = ($windowBytes / 1MB) / $windowSw.Elapsed.TotalSeconds
                if ($wmb -gt $peak) { $peak = $wmb }
                $windowBytes = 0L
                $windowSw.Restart()
            }
            if ($ProgressCb) { & $ProgressCb $total $limit }
        }
        if ($OpMode -eq 'Write') { $open.Stream.Flush($true) }
    } catch {
        $sw.Stop()
        return @{ MBps = $null; Seconds = $sw.Elapsed.TotalSeconds; Bytes = $total; PeakMBps = $null; Mode = $open.Mode; Reason = $_.Exception.Message }
    } finally {
        try { $open.Stream.Dispose() } catch { }
    }

    $sw.Stop()
    $secs = [math]::Max($sw.Elapsed.TotalSeconds, 0.000001)
    if ($peak -le 0) { $peak = ($total / 1MB) / $secs }

    @{
        MBps     = [double](($total / 1MB) / $secs)
        Seconds  = [double]$secs
        Bytes    = [long]$total
        PeakMBps = [double]$peak
        Mode     = $open.Mode
        Reason   = ''
    }
}

function Get-AlignedOffsets {
    <#
        Random sector-aligned offsets inside a file, drawn from the deterministic
        stream so a re-run of the same drive is comparable.
    #>
    [OutputType([long[]])]
    param(
        [Parameter(Mandatory)][long]$FileBytes,
        [Parameter(Mandatory)][int]$Block,
        [Parameter(Mandatory)][int]$Count,
        [int]$Seed = 0x0FF5E7
    )
    $slots = [long][math]::Floor($FileBytes / $Block)
    if ($slots -lt 1) { return @(0L) }
    $rs = New-RandomStream -Seed $Seed
    try {
        $out = [long[]]::new($Count)
        for ($i = 0; $i -lt $Count; $i++) {
            $r = $rs.NextUInt64()
            $out[$i] = [long](($r % [uint64]$slots) * [uint64]$Block)
        }
        return $out
    } finally { $rs.Dispose() }
}

function Measure-RandomQd1 {
    <#
        One outstanding request at a time - the pure access-latency test, and the
        measurement that tells mechanical from solid state.
        Returns @{IOPS;AvgMs;P50;P95;P99;MaxMs;Samples;Mode}.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][int]$Samples,
        [int]$Block = 4096,
        [scriptblock]$ProgressCb
    )

    $open = New-BenchStream -Path $File -Access Read -Mode Open
    if (-not $open.Stream) {
        return @{ IOPS = $null; AvgMs = $null; P50 = $null; P95 = $null; P99 = $null; MaxMs = $null; Samples = @(); Mode = 'none'; Reason = $open.Reason }
    }

    $buf = New-BenchBuffer -Size $Block
    $lat = [System.Collections.Generic.List[double]]::new()
    $sw = [System.Diagnostics.Stopwatch]::new()
    $wall = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $offsets = Get-AlignedOffsets -FileBytes $open.Stream.Length -Block $Block -Count $Samples
        for ($i = 0; $i -lt $Samples; $i++) {
            $open.Stream.Position = $offsets[$i]
            $sw.Restart()
            [void]$open.Stream.Read($buf, 0, $Block)
            $sw.Stop()
            $lat.Add($sw.Elapsed.TotalMilliseconds)
            if ($ProgressCb -and ($i % 16) -eq 0) { & $ProgressCb ($i + 1) $Samples }
        }
    } catch {
        return @{ IOPS = $null; AvgMs = $null; P50 = $null; P95 = $null; P99 = $null; MaxMs = $null; Samples = @($lat); Mode = $open.Mode; Reason = $_.Exception.Message }
    } finally {
        try { $open.Stream.Dispose() } catch { }
        $wall.Stop()
    }

    if ($lat.Count -eq 0) {
        return @{ IOPS = $null; AvgMs = $null; P50 = $null; P95 = $null; P99 = $null; MaxMs = $null; Samples = @(); Mode = $open.Mode; Reason = 'no samples' }
    }

    $avg = ($lat | Measure-Object -Average).Average
    @{
        IOPS      = [double]($lat.Count / [math]::Max($wall.Elapsed.TotalSeconds, 0.000001))
        AvgMs     = [double]$avg
        P50       = Get-Percentile -Values $lat -P 50
        P95       = Get-Percentile -Values $lat -P 95
        P99       = Get-Percentile -Values $lat -P 99
        MaxMs     = [double](($lat | Measure-Object -Maximum).Maximum)
        Samples   = @($lat)
        BlockSize = $Block
        Mode      = $open.Mode
        Reason    = ''
    }
}

function Measure-RandomQdN {
    <#
        Deep queue via overlapped async reads. An SSD's controller has many
        channels and scales here; a mechanical drive has one head and barely
        moves, so the QD1-to-QDN ratio is itself a media fingerprint.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][int]$QueueDepth,
        [Parameter(Mandatory)][int]$Samples,
        [int]$Block = 4096,
        [scriptblock]$ProgressCb
    )

    $open = New-BenchStream -Path $File -Access Read -Mode Open -Async
    if (-not $open.Stream) {
        return @{ IOPS = $null; AvgMs = $null; P95 = $null; QueueDepth = $QueueDepth; Mode = 'none'; Reason = $open.Reason }
    }

    $offsets = Get-AlignedOffsets -FileBytes $open.Stream.Length -Block $Block -Count $Samples -Seed 0x0FF5E8
    # Built in a loop, not a pipeline: `@(1..n | ForEach-Object { [byte[]] })`
    # unrolls each array into its individual bytes, so what looks like N buffers
    # of $Block is really one flat array of N*$Block singles - and every read
    # then goes out with a one-byte buffer, which an unbuffered handle refuses.
    $buffers = [System.Collections.Generic.List[byte[]]]::new()
    for ($b = 0; $b -lt $QueueDepth; $b++) {
        $buffers.Add([System.GC]::AllocateArray[byte]($Block, $true))
    }

    # Reads go through RandomAccess on the raw handle, not through the stream.
    # A FileStream carries one shared file position, so N concurrent ReadAsync
    # calls race for it and hand the driver an offset nobody aligned - which an
    # unbuffered handle rejects outright with "the parameter is incorrect".
    # RandomAccess takes the offset per call, so each request is independently
    # aligned, and the reads land where Get-AlignedOffsets put them instead of
    # walking the file in order.
    $handle = $open.Stream.SafeFileHandle
    $batchLat = [System.Collections.Generic.List[double]]::new()
    $wall = [System.Diagnostics.Stopwatch]::StartNew()
    $done = 0

    try {
        $i = 0
        while ($i -lt $Samples) {
            $n = [math]::Min($QueueDepth, $Samples - $i)
            $tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            for ($q = 0; $q -lt $n; $q++) {
                $mem = [System.Memory[byte]]::new($buffers[$q])
                $tasks.Add([System.IO.RandomAccess]::ReadAsync($handle, $mem, $offsets[$i + $q]).AsTask())
            }
            [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray())
            $sw.Stop()
            $batchLat.Add($sw.Elapsed.TotalMilliseconds / $n)
            $done += $n
            $i += $n
            if ($ProgressCb) { & $ProgressCb $done $Samples }
        }
    } catch {
        return @{ IOPS = $null; AvgMs = $null; P95 = $null; QueueDepth = $QueueDepth; Mode = $open.Mode; Reason = $_.Exception.Message }
    } finally {
        try { $open.Stream.Dispose() } catch { }
        $wall.Stop()
    }

    if ($done -eq 0) {
        return @{ IOPS = $null; AvgMs = $null; P95 = $null; QueueDepth = $QueueDepth; Mode = $open.Mode; Reason = 'no samples' }
    }

    @{
        IOPS       = [double]($done / [math]::Max($wall.Elapsed.TotalSeconds, 0.000001))
        AvgMs      = [double](($batchLat | Measure-Object -Average).Average)
        P95        = Get-Percentile -Values $batchLat -P 95
        QueueDepth = $QueueDepth
        Completed  = $done
        BlockSize  = $Block
        Mode       = $open.Mode
        Reason     = ''
    }
}

function Measure-SustainedWrite {
    <#
        Long write with periodic sampling, to find the SLC-cache cliff: consumer
        SSDs absorb the first few GB at full speed, then collapse to native TLC
        or QLC speed. A drive that never drops is either very good or mechanical.

        Returns @{SeriesMBps;CliffDetected;CliffAtMB;FinalMBps;AvgMBps;Mode}.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][long]$TotalBytes,
        [double]$IntervalSec = 1.0,
        [int]$Block = 0,
        [scriptblock]$SampleCb
    )

    $block = if ($Block -gt 0) { $Block } else { $script:SbDefaultBlock }
    $open = New-BenchStream -Path $File -Access Write -Mode OpenOrCreate
    if (-not $open.Stream) {
        return @{ SeriesMBps = @(); CliffDetected = $false; CliffAtMB = $null; FinalMBps = $null; AvgMBps = $null; Mode = 'none'; Reason = $open.Reason }
    }

    $buf = New-BenchBuffer -Size $block -Seed 0x51CAC4E
    $series = [System.Collections.Generic.List[double]]::new()
    $marks = [System.Collections.Generic.List[double]]::new()
    $total = 0L
    $windowBytes = 0L
    $wall = [System.Diagnostics.Stopwatch]::StartNew()
    $win = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while ($total -lt $TotalBytes) {
            $open.Stream.Write($buf, 0, $block)
            $total += $block
            $windowBytes += $block
            if ($win.Elapsed.TotalSeconds -ge $IntervalSec) {
                $mb = ($windowBytes / 1MB) / $win.Elapsed.TotalSeconds
                $series.Add($mb)
                $marks.Add([double]($total / 1MB))
                if ($SampleCb) { & $SampleCb @{ MBps = $mb; WrittenBytes = $total; TotalBytes = $TotalBytes; ElapsedSec = $wall.Elapsed.TotalSeconds } }
                $windowBytes = 0L
                $win.Restart()
            }
        }
        $open.Stream.Flush($true)
    } catch {
        return @{ SeriesMBps = @($series); CliffDetected = $false; CliffAtMB = $null; FinalMBps = $null; AvgMBps = $null; Mode = $open.Mode; Reason = $_.Exception.Message }
    } finally {
        try { $open.Stream.Dispose() } catch { }
        $wall.Stop()
    }

    $cliff = Find-WriteCliff -Series $series -MarksMB $marks
    $secs = [math]::Max($wall.Elapsed.TotalSeconds, 0.000001)

    @{
        SeriesMBps    = @($series)
        MarksMB       = @($marks)
        CliffDetected = [bool]$cliff.Detected
        CliffAtMB     = $cliff.AtMB
        CliffRatio    = $cliff.Ratio
        FinalMBps     = if ($series.Count -gt 0) { [double]$series[$series.Count - 1] } else { $null }
        AvgMBps       = [double](($total / 1MB) / $secs)
        Bytes         = [long]$total
        Seconds       = [double]$secs
        Mode          = $open.Mode
        Reason        = ''
    }
}

function Find-WriteCliff {
    <#
        A cliff is a lasting collapse, not a hiccup: the plateau after some point
        must sit below 65% of the opening plateau and stay there. Requires at
        least 6 samples, otherwise there is no plateau to compare.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object]$Series,
        [AllowEmptyCollection()][object]$MarksMB = @()
    )

    $s = @($Series | ForEach-Object { [double]$_ })
    $m = @($MarksMB | ForEach-Object { [double]$_ })
    if ($s.Count -lt 6) { return @{ Detected = $false; AtMB = $null; Ratio = $null } }

    $headCount = [math]::Max(2, [int][math]::Floor($s.Count * 0.2))
    $head = ($s[0..($headCount - 1)] | Measure-Object -Average).Average
    if ($head -le 0) { return @{ Detected = $false; AtMB = $null; Ratio = $null } }

    for ($i = $headCount; $i -lt ($s.Count - 2); $i++) {
        $tail = ($s[$i..($s.Count - 1)] | Measure-Object -Average).Average
        $ratio = $tail / $head
        if ($ratio -lt 0.65) {
            $atMB = if ($i -lt $m.Count) { $m[$i] } else { $null }
            return @{ Detected = $true; AtMB = $atMB; Ratio = [double]$ratio }
        }
    }
    @{ Detected = $false; AtMB = $null; Ratio = $null }
}

function Measure-ZoneProfile {
    <#
        Read speed at evenly spaced positions across the test file. On a
        mechanical drive the outer tracks are physically longer, so throughput
        falls from the start of the platter to the end - a clean staircase here
        is another mechanical fingerprint. Flash is flat.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$File,
        [int]$Block = 0,
        [int]$Zones = 8,
        [int]$BlocksPerZone = 16,
        [scriptblock]$ProgressCb
    )

    $block = if ($Block -gt 0) { $Block } else { $script:SbDefaultBlock }
    $open = New-BenchStream -Path $File -Access Read -Mode Open
    if (-not $open.Stream) { return @{ ZonePcts = @(); ZoneMBps = @(); Mode = 'none'; Reason = $open.Reason } }

    $buf = New-BenchBuffer -Size $block
    $pcts = [System.Collections.Generic.List[double]]::new()
    $rates = [System.Collections.Generic.List[double]]::new()

    try {
        $len = $open.Stream.Length
        $span = [long]($block * $BlocksPerZone)
        for ($z = 0; $z -lt $Zones; $z++) {
            $pct = ($z / [double][math]::Max(1, $Zones - 1)) * 100.0
            $start = [long][math]::Floor(($len - $span) * ($pct / 100.0))
            if ($start -lt 0) { $start = 0 }
            $start = [long]([math]::Floor($start / $block) * $block)

            $open.Stream.Position = $start
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $got = 0L
            for ($b = 0; $b -lt $BlocksPerZone; $b++) {
                $n = $open.Stream.Read($buf, 0, $block)
                if ($n -le 0) { break }
                $got += $n
            }
            $sw.Stop()
            $pcts.Add([double][math]::Round($pct, 1))
            $rates.Add([double](($got / 1MB) / [math]::Max($sw.Elapsed.TotalSeconds, 0.000001)))
            if ($ProgressCb) { & $ProgressCb ($z + 1) $Zones }
        }
    } catch {
        return @{ ZonePcts = @($pcts); ZoneMBps = @($rates); Mode = $open.Mode; Reason = $_.Exception.Message }
    } finally {
        try { $open.Stream.Dispose() } catch { }
    }

    $falloff = $null
    if ($rates.Count -ge 2 -and $rates[0] -gt 0) {
        $falloff = [double](1.0 - ($rates[$rates.Count - 1] / $rates[0]))
    }

    @{
        ZonePcts    = @($pcts)
        ZoneMBps    = @($rates)
        FalloffFrac = $falloff
        Mode        = $open.Mode
        Reason      = ''
    }
}
