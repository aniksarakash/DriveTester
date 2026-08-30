<#
    Surface.ps1 - a read map of the media, region by region.

    A real surface scan on Windows would open the raw device and walk every
    sector. That needs elevation, and it is one typo away from a destroyed
    partition table, so this toolkit does not do it. What it does instead is
    honest and safe: sweep the scratch region that the write phases just laid
    down across free space, time every region, and mark the ones that are slow
    or unreadable.

    That catches what matters on a used drive - a weak area where the head has
    to retry, a block the controller is quietly remapping - because a sector
    that needs three retries takes tens of milliseconds, and it shows up here as
    a black square on the map even when it eventually returns the right bytes.

    Regions are reported with a glyph so the caller can print them as a block
    map. Coverage is honestly limited to whatever free space was available;
    Mode says which region of the media was actually looked at.
#>

function Get-RegionStatus {
    <#
        Region verdict from its read rate relative to the run's own median.
        Absolute thresholds cannot work here: 40 MB/s is a catastrophe on NVMe
        and excellent on USB 2.0. Comparing a region against its neighbours is
        the only way to spot a weak area on an unknown drive.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$MBps,
        [Parameter(Mandatory)][AllowNull()][object]$MedianMBps
    )

    if ($null -eq $MBps) { return @{ Status = 'error'; Glyph = 'X'; Ok = $false } }
    if ($null -eq $MedianMBps -or $MedianMBps -le 0) { return @{ Status = 'ok'; Glyph = [char]0x2588; Ok = $true } }

    $ratio = [double]$MBps / [double]$MedianMBps
    if ($ratio -ge 0.80) { return @{ Status = 'ok'; Glyph = [char]0x2588; Ok = $true } }         # full block
    if ($ratio -ge 0.50) { return @{ Status = 'fair'; Glyph = [char]0x2593; Ok = $true } }       # dark shade
    if ($ratio -ge 0.25) { return @{ Status = 'slow'; Glyph = [char]0x2592; Ok = $true } }       # medium shade
    @{ Status = 'weak'; Glyph = [char]0x2591; Ok = $true }                                       # light shade
}

function Invoke-SurfaceScan {
    <#
        Reads the volume's scratch area in $Regions equal slices and reports one
        record per slice.

        Returns @{Mode;Regions;Errors;CoveredBytes;CoveragePct;MedianMBps;
                  MinMBps;MaxMBps;WeakCount;Reason}

        Each region: @{Index;Offset;Bytes;Ms;MBps;Status;Glyph;Ok;Detail}

        Mode is 'scratch-file' when an existing test file was swept, 'created'
        when this function had to lay one down itself, or 'none' when there was
        no room to scan anything.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$Volume,
        [Parameter(Mandatory)][hashtable]$Session,
        [int]$Regions = 64,
        [scriptblock]$ProgressCb,
        [long]$FileBytes = 0,
        [string]$ExistingFile = '',
        [int]$Block = 1MB
    )

    $res = @{
        Mode = 'none'; Regions = @(); Errors = @(); CoveredBytes = 0L
        CoveragePct = 0.0; MedianMBps = $null; MinMBps = $null; MaxMBps = $null
        WeakCount = 0; Reason = ''
    }

    if ($Regions -lt 2) { $Regions = 2 }

    # Prefer a file the benchmarks already wrote: it is already spread across
    # free space, and re-reading it costs nothing extra in wear.
    $path = ''
    if ($ExistingFile -and (Test-Path -LiteralPath $ExistingFile)) {
        $path = $ExistingFile
        $res.Mode = 'scratch-file'
    } else {
        $want = if ($FileBytes -gt 0) { $FileBytes } else { 1GB }
        $reserve = Test-Reserve -Drive ([char]$Session.Drive) -NeedBytes $want
        if (-not $reserve.Ok) {
            $want = [long]($want / 4)
            $reserve = Test-Reserve -Drive ([char]$Session.Drive) -NeedBytes $want
            if (-not $reserve.Ok) { $res.Reason = $reserve.Reason; return $res }
        }
        $mk = New-BenchFile -Session $Session -Name 'surface.bin' -Bytes $want -Block $Block -ProgressCb $ProgressCb
        if (-not $mk.Ok) { $res.Reason = $mk.Reason; return $res }
        $path = $mk.Path
        $res.Mode = 'created'
    }

    $open = New-BenchStream -Path $path -Access Read -Mode Open
    if (-not $open.Stream) { $res.Reason = $open.Reason; $res.Mode = 'none'; return $res }

    $buf = New-BenchBuffer -Size $Block
    $recs = [System.Collections.ArrayList]::new()
    $errs = [System.Collections.ArrayList]::new()
    $rates = [System.Collections.Generic.List[double]]::new()
    $sw = [System.Diagnostics.Stopwatch]::new()
    $covered = 0L

    try {
        $len = $open.Stream.Length
        # Region size, floored to a whole number of blocks so unbuffered reads
        # stay sector-aligned.
        $regionBytes = [long]([math]::Floor(($len / $Regions) / $Block) * $Block)
        if ($regionBytes -lt $Block) { $regionBytes = $Block }
        $count = [int][math]::Min([long]$Regions, [long][math]::Floor($len / $regionBytes))
        if ($count -lt 1) { $count = 1 }

        for ($i = 0; $i -lt $count; $i++) {
            $off = [long]$i * $regionBytes
            $rec = @{
                Index = $i; Offset = $off; Bytes = 0L; Ms = $null; MBps = $null
                Status = 'error'; Glyph = 'X'; Ok = $false; Detail = ''
            }
            try {
                $open.Stream.Position = $off
                $got = 0L
                $sw.Restart()
                while ($got -lt $regionBytes) {
                    $chunk = [int][math]::Min([long]$Block, $regionBytes - $got)
                    if ($chunk -lt $Block) { break }   # keep alignment; trailing slack is skipped
                    $n = $open.Stream.Read($buf, 0, $chunk)
                    if ($n -le 0) { break }
                    $got += $n
                }
                $sw.Stop()

                if ($got -le 0) {
                    $rec.Detail = 'read returned nothing'
                    [void]$errs.Add([pscustomobject]@{ Index = $i; Offset = $off; Kind = 'empty'; Detail = $rec.Detail })
                } else {
                    $secs = [math]::Max($sw.Elapsed.TotalSeconds, 0.000001)
                    $rec.Bytes = $got
                    $rec.Ms = [double]$sw.Elapsed.TotalMilliseconds
                    $rec.MBps = [double](($got / 1MB) / $secs)
                    $rates.Add($rec.MBps)
                    $covered += $got
                }
            } catch {
                $rec.Detail = $_.Exception.Message
                [void]$errs.Add([pscustomobject]@{ Index = $i; Offset = $off; Kind = 'read'; Detail = $rec.Detail })
            }
            [void]$recs.Add($rec)
            if ($ProgressCb) { & $ProgressCb ($i + 1) $count }
        }
    } catch {
        $res.Reason = $_.Exception.Message
    } finally {
        try { $open.Stream.Dispose() } catch { }
    }

    # Second pass: classify each region against the run's own median.
    $median = if ($rates.Count -gt 0) { Get-Percentile -Values $rates -P 50 } else { $null }
    $weak = 0
    foreach ($r in $recs) {
        $v = Get-RegionStatus -MBps $r.MBps -MedianMBps $median
        $r.Status = $v.Status
        $r.Glyph = $v.Glyph
        $r.Ok = $v.Ok
        if ($r.Status -eq 'weak' -or $r.Status -eq 'slow') { $weak++ }
    }

    $res.Regions = @($recs | ForEach-Object { [pscustomobject]$_ })
    $res.Errors = @($errs)
    $res.CoveredBytes = $covered
    $res.MedianMBps = $median
    if ($rates.Count -gt 0) {
        $res.MinMBps = [double](($rates | Measure-Object -Minimum).Minimum)
        $res.MaxMBps = [double](($rates | Measure-Object -Maximum).Maximum)
    }
    $res.WeakCount = $weak

    $volSize = if ($Volume -and $Volume.SizeBytes) { [long]$Volume.SizeBytes } else { 0L }
    if ($volSize -gt 0) { $res.CoveragePct = [double][math]::Round(($covered / $volSize) * 100.0, 3) }

    $res
}
