<#
    Core.ps1 - pure helpers for StorageBench.

    Contract: this file is dot-sourced. It defines functions only and has no
    side effects at load time (no output, no state mutation, no auto-run).
#>

# CRC-32 lookup table, filled by Get-Crc32 on first use.
$script:SbCrcTable = $null

function Format-Bytes {
    <# Binary units. 0 -> "0 B"; 320072933376 -> "298.1 GB". #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Bytes)

    if ($null -eq $Bytes) { return 'n/a' }
    $v = [double]$Bytes
    $neg = $v -lt 0
    $b = [math]::Abs($v)
    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $i = 0
    while ($b -ge 1024 -and $i -lt ($units.Count - 1)) { $b = $b / 1024; $i++ }
    $s = if ($i -eq 0) { '{0:0} {1}' -f $b, $units[$i] } else { '{0:0.0} {1}' -f $b, $units[$i] }
    if ($neg) { "-$s" } else { $s }
}

function Format-Duration {
    <# 45 -> "45s"; 90 -> "1m 30s"; 5400 -> "1h 30m 0s". #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Seconds)

    if ($null -eq $Seconds) { return 'n/a' }
    $s = [double]$Seconds
    if ($s -lt 0) { $s = 0 }
    $t = [TimeSpan]::FromSeconds([math]::Round($s))
    if ($t.TotalHours -ge 1) { '{0}h {1}m {2}s' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds }
    elseif ($t.TotalMinutes -ge 1) { '{0}m {1}s' -f [int][math]::Floor($t.TotalMinutes), $t.Seconds }
    else { '{0}s' -f [int]$t.TotalSeconds }
}

function Format-Mbps {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$MBps)
    if ($null -eq $MBps) { return 'n/a' }
    '{0:0.0} MB/s' -f [double]$MBps
}

function Format-IOPS {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Iops)
    if ($null -eq $Iops) { return 'n/a' }
    $v = [double]$Iops
    if ($v -ge 10000) { '{0:0.0}k IOPS' -f ($v / 1000) } else { '{0:0} IOPS' -f $v }
}

function Format-Ms {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Ms)
    if ($null -eq $Ms) { return 'n/a' }
    '{0:0.000} ms' -f [double]$Ms
}

function Get-ConsoleGeometry {
    <#
        Returns @{W;H}. MUST never throw.

        [Console]::WindowWidth throws "The handle is invalid" whenever output is
        redirected (confirmed on the target machine), so every read is guarded
        and falls back to 100x30.
    #>
    [OutputType([hashtable])]
    param()

    $w = 100; $h = 30
    try {
        $cw = [Console]::WindowWidth
        if ($cw -gt 0) { $w = [int]$cw }
    } catch { $w = 100 }
    try {
        $ch = [Console]::WindowHeight
        if ($ch -gt 0) { $h = [int]$ch }
    } catch { $h = 30 }

    if ($w -lt 40) { $w = 40 }
    if ($h -lt 10) { $h = 10 }
    @{ W = $w; H = $h }
}

function Test-OutputRedirected {
    [OutputType([bool])]
    param()
    try { return [Console]::IsOutputRedirected } catch { return $true }
}

function New-RunId {
    <# yyyyMMdd-HHmmss-<4 lowercase alnum>. Safety's orphan sweep greps this shape. #>
    [OutputType([string])]
    param()
    $alphabet = '0123456789abcdefghijklmnopqrstuvwxyz'
    $sb = [System.Text.StringBuilder]::new()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buf = [byte[]]::new(4)
        $rng.GetBytes($buf)
        foreach ($b in $buf) { [void]$sb.Append($alphabet[$b % $alphabet.Length]) }
    } finally { $rng.Dispose() }
    '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $sb.ToString()
}

function Get-Pct {
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Current,
        [Parameter(Mandatory)][AllowNull()][object]$Total
    )
    if ($null -eq $Total) { return 0.0 }
    $t = [double]$Total
    if ($t -le 0) { return 0.0 }
    $c = if ($null -eq $Current) { 0.0 } else { [double]$Current }
    $p = ($c / $t) * 100.0
    if ($p -lt 0) { return 0.0 }
    if ($p -gt 100) { return 100.0 }
    [double]$p
}

function Get-Percentile {
    <# Nearest-rank percentile over a numeric collection. P in 0..100. #>
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object]$Values,
        [Parameter(Mandatory)][double]$P
    )
    $a = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($a.Count -eq 0) { return 0.0 }
    $sorted = [double[]]($a | Sort-Object)
    if ($P -le 0) { return $sorted[0] }
    if ($P -ge 100) { return $sorted[$sorted.Count - 1] }
    $rank = [int][math]::Ceiling(($P / 100.0) * $sorted.Count) - 1
    if ($rank -lt 0) { $rank = 0 }
    if ($rank -ge $sorted.Count) { $rank = $sorted.Count - 1 }
    [double]$sorted[$rank]
}

function Get-SeekSlope {
    <#
        Ordinary least-squares slope of latency (ms) against seek distance (GB).
        $Points: objects with .DistanceGB and .Ms.
        Returns ms-per-GB; 0 when fewer than 2 points or zero variance in X.
    #>
    [OutputType([double])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object]$Points)

    $pts = @($Points | Where-Object { $null -ne $_ })
    if ($pts.Count -lt 2) { return 0.0 }

    $n = 0; $sx = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0
    foreach ($p in $pts) {
        $x = [double]$p.DistanceGB
        $y = [double]$p.Ms
        $n++; $sx += $x; $sy += $y; $sxx += ($x * $x); $sxy += ($x * $y)
    }
    if ($n -lt 2) { return 0.0 }
    $denom = ($n * $sxx) - ($sx * $sx)
    if ([math]::Abs($denom) -lt 1e-12) { return 0.0 }
    [double]((($n * $sxy) - ($sx * $sy)) / $denom)
}

function Get-LatencyLegend {
    <#
        Maps a region's read latency to a surface-map glyph.
        Bands: <3 fast | 3-6 ok | 6-12 slow | 12-30 very slow | >=30 or null/negative error.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowNull()][object]$Ms)

    if ($null -eq $Ms) { return @{ Glyph = [char]0x2717; Status = 'error'; Color = 'red' } }
    $v = [double]$Ms
    if ($v -lt 0) { return @{ Glyph = [char]0x2717; Status = 'error'; Color = 'red' } }
    if ($v -lt 3) { return @{ Glyph = [char]0x2588; Status = 'fast'; Color = 'green' } }
    if ($v -lt 6) { return @{ Glyph = [char]0x2593; Status = 'ok'; Color = 'greenyellow' } }
    if ($v -lt 12) { return @{ Glyph = [char]0x2592; Status = 'slow'; Color = 'yellow' } }
    if ($v -lt 30) { return @{ Glyph = [char]0x2591; Status = 'very slow'; Color = 'orange' } }
    @{ Glyph = [char]0x2717; Status = 'error'; Color = 'red' }
}

function Get-Crc32 {
    <#
        Standard CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320).

        The constants are written in decimal on purpose. PowerShell parses the
        hex literal 0xEDB88320 as Int32 -306674912 and 0xFFFFFFFF as Int32 -1,
        so the natural-looking [uint32]0xFFFFFFFF throws at runtime and the
        polynomial silently becomes a negative number. Decimal literals also
        keep this working on PowerShell 5.1, which has no "u" suffix.

        Verified against the published vectors: "" -> 0x00000000,
        "a" -> 0xE8B7BE43, "123456789" -> 0xCBF43926,
        "The quick brown fox jumps over the lazy dog" -> 0x414FA339.
    #>
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [int]$Offset = 0,
        [int]$Count = -1
    )
    $allOnes = [uint32]4294967295          # 0xFFFFFFFF
    if ($Count -lt 0) { $Count = $Bytes.Length - $Offset }
    if ($Count -le 0) { return [uint32]0 }

    # Built once, on first use. Declared at module scope below so StrictMode does
    # not fault on reading it before it exists.
    if (-not $script:SbCrcTable) {
        $poly = [uint32]3987671650         # 0xEDB88320
        $tbl = [uint32[]]::new(256)
        for ($i = 0; $i -lt 256; $i++) {
            $c = [uint32]$i
            for ($k = 0; $k -lt 8; $k++) {
                if (($c -band [uint32]1) -ne 0) { $c = [uint32]($poly -bxor ($c -shr 1)) }
                else { $c = [uint32]($c -shr 1) }
            }
            $tbl[$i] = $c
        }
        $script:SbCrcTable = $tbl
    }
    $t = $script:SbCrcTable
    $crc = $allOnes
    $end = $Offset + $Count
    for ($i = $Offset; $i -lt $end; $i++) {
        $idx = [int](($crc -bxor [uint32]$Bytes[$i]) -band [uint32]255)
        $crc = [uint32]($t[$idx] -bxor ($crc -shr 8))
    }
    [uint32]($crc -bxor $allOnes)
}

function New-RandomStream {
    <#
        Deterministic, incompressible pseudo-random byte source (AES-256-CTR over a
        counter, key = SHA-256(seed)). Chosen over System.Random because it is
        reproducible across runtimes and produces content a compressing storage
        controller cannot squeeze - which is what makes the write benchmarks honest.

        Exposes .NextBytes([byte[]]) and .NextUInt64().
    #>
    [OutputType([psobject])]
    param([Parameter(Mandatory)][int]$Seed)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $key = $sha.ComputeHash([System.BitConverter]::GetBytes([int64]$Seed)) }
    finally { $sha.Dispose() }

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
    $aes.KeySize = 256
    $aes.Key = $key

    $obj = [pscustomobject]@{
        Seed      = $Seed
        Encryptor = $aes.CreateEncryptor()
        Aes       = $aes
        Counter   = [uint64]0
    }

    $obj | Add-Member -MemberType ScriptMethod -Force -Name NextBytes -Value {
        param([byte[]]$Buffer)
        if ($null -eq $Buffer -or $Buffer.Length -eq 0) { return }
        $blocks = [int][math]::Ceiling($Buffer.Length / 16.0)
        $inBuf = [byte[]]::new($blocks * 16)
        for ($b = 0; $b -lt $blocks; $b++) {
            $cb = [System.BitConverter]::GetBytes([uint64]($this.Counter + [uint64]$b))
            [Array]::Copy($cb, 0, $inBuf, $b * 16, 8)
        }
        $outBuf = [byte[]]::new($inBuf.Length)
        [void]$this.Encryptor.TransformBlock($inBuf, 0, $inBuf.Length, $outBuf, 0)
        [Array]::Copy($outBuf, 0, $Buffer, 0, $Buffer.Length)
        $this.Counter = [uint64]($this.Counter + [uint64]$blocks)
    }

    $obj | Add-Member -MemberType ScriptMethod -Force -Name NextUInt64 -Value {
        $b = [byte[]]::new(8)
        $this.NextBytes($b)
        [System.BitConverter]::ToUInt64($b, 0)
    }

    $obj | Add-Member -MemberType ScriptMethod -Force -Name Dispose -Value {
        try { $this.Encryptor.Dispose() } catch { }
        try { $this.Aes.Dispose() } catch { }
    }

    $obj
}

function Get-DerivedBytes {
    <#
        Stateless deterministic expansion: SHA-256(label || counter) concatenated
        to $Count bytes. Used by Integrity so a block's filler can be regenerated
        for verification without replaying a stream.
    #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][byte[]]$Label,
        [Parameter(Mandatory)][int]$Count
    )
    $out = [byte[]]::new($Count)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $written = 0
        $ctr = 0
        while ($written -lt $Count) {
            $inBuf = [byte[]]::new($Label.Length + 4)
            [Array]::Copy($Label, 0, $inBuf, 0, $Label.Length)
            [Array]::Copy([System.BitConverter]::GetBytes([int32]$ctr), 0, $inBuf, $Label.Length, 4)
            $h = $sha.ComputeHash($inBuf)
            $take = [math]::Min($h.Length, $Count - $written)
            [Array]::Copy($h, 0, $out, $written, $take)
            $written += $take
            $ctr++
        }
    } finally { $sha.Dispose() }
    $out
}

function Get-IsAdmin {
    [OutputType([bool])]
    param()
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = [System.Security.Principal.WindowsPrincipal]::new($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
