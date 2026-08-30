<#
    Core.ps1 - pure helpers for StorageBench.

    Contract: this file is dot-sourced. It defines functions only and has no
    side effects at load time (no output, no state mutation, no auto-run).
#>

# CRC-32 lookup table, filled by Get-Crc32 on first use.
$script:SbCrcTable = $null

if (-not ('StorageBench.PatternHelper' -as [type])) {
    Add-Type -TypeDefinition @'
namespace StorageBench
{
    using System;

    public static class PatternHelper
    {
        private static readonly byte[] Magic = new byte[] { 0x53, 0x42, 0x4B, 0x31 };
        public static readonly uint[] CrcTable = new uint[] {
            0u, 4138519913u, 906464791u, 3232449406u, 1812929582u, 2594427207u, 1510511161u, 2896453456u,
            3625859164u, 783480117u, 3994662475u, 414546722u, 3021022322u, 1119742235u, 2182523493u, 1958373132u,
            1801610365u, 2647566612u, 1566960234u, 2882086659u, 124614739u, 4056003898u, 829093444u, 3351657261u,
            3011271713u, 1171296584u, 2239484470u, 1943478111u, 3748872207u, 702516582u, 3916746264u, 534250353u,
            3603220730u, 543688083u, 3770894061u, 376408964u, 3133920468u, 1281825213u, 2362202819u, 2053150634u,
            249229478u, 4168498639u, 954039985u, 3463558104u, 1658186888u, 2490966497u, 1423073951u, 2726211574u,
            3181816967u, 1258971630u, 2342593168u, 2098065401u, 3517558953u, 654671296u, 3886956222u, 285406167u,
            1706595547u, 2467584434u, 1405033164u, 2769541029u, 163023093u, 4279977372u, 1068500706u, 3374107531u,
            1993835825u, 2155563096u, 1087376166u, 3061630543u, 450402591u, 3967046774u, 752817928u, 3665025633u,
            2932456813u, 1483042820u, 2563650426u, 1851981331u, 3267797315u, 879389738u, 4106301268u, 40755773u,
            498458956u, 3944295461u, 733114203u, 3709772338u, 1908079970u, 2266378251u, 1203598197u, 2970730012u,
            3316373776u, 856102009u, 4088157959u, 83925614u, 2846147902u, 1594361943u, 2678278953u, 1762625088u,
            2685619659u, 1455390882u, 2517943260u, 1622675125u, 3424408037u, 984652940u, 4196130802u, 213324443u,
            2014147991u, 2392963326u, 1309342592u, 3097900777u, 335702457u, 3803096272u, 570812334u, 3567856327u,
            3413191094u, 1037952223u, 4252411809u, 198863560u, 2810066328u, 1372780785u, 2440674191u, 1742042854u,
            326046186u, 3854818435u, 627613693u, 3552858772u, 2137001412u, 2311897261u, 1231520723u, 3217772218u,
            3987671650u, 453232395u, 3685254261u, 755255580u, 2174752332u, 1997331237u, 3081214043u, 1091261746u,
            900805182u, 3273523031u, 62307369u, 4112150848u, 1505635856u, 2937250681u, 1874436103u, 2568318318u,
            2261610015u, 1885447030u, 2966085640u, 1181101409u, 3938611761u, 477019992u, 3703962662u, 711536975u,
            1590908483u, 2826935082u, 1758779476u, 2658669885u, 853297773u, 3295708932u, 81511546u, 4067887379u,
            996917912u, 3452375025u, 225201295u, 4223697382u, 1466228406u, 2714244063u, 1633898657u, 2546965960u,
            3816159940u, 366557101u, 3581048019u, 601799098u, 2407196394u, 2044078979u, 3112003837u, 1339139476u,
            1342809829u, 2795858828u, 1712204018u, 2426594715u, 1007073995u, 3400169378u, 167851228u, 4239260085u,
            2283249337u, 2126205904u, 3188723886u, 1220337095u, 3826811543u, 313806846u, 3525250176u, 615760361u,
            2608369491u, 1842627130u, 2910781764u, 1540607021u, 4151808893u, 31153684u, 3245350250u, 937218051u,
            1130805007u, 3049945702u, 1969305880u, 2211312753u, 795454241u, 3653592648u, 426648886u, 4022528095u,
            4028295982u, 112600647u, 3323815225u, 816949328u, 2618685184u, 1790524009u, 2853337367u, 1556001918u,
            671404914u, 3735559707u, 503536997u, 3903819788u, 1141624668u, 2997289525u, 1913405771u, 2225114146u,
            1304184745u, 3138423488u, 2075904446u, 2367096023u, 565402503u, 3609171694u, 397727120u, 3776452857u,
            2510454773u, 1661907612u, 2745561570u, 1426668683u, 4188890075u, 251768498u, 3484085708u, 956702885u,
            652092372u, 3497193149u, 282701251u, 3866452138u, 1255227386u, 3162370707u, 2094445037u, 2323283076u,
            4274002824u, 141350625u, 3368523167u, 1047222518u, 2463041446u, 1684261583u, 2764605873u, 1382302936u
        };

        public static uint ComputeCrc32(byte[] bytes, int offset, int count)
        {
            if (bytes == null || count <= 0 || offset < 0 || offset + count > bytes.Length) return 0;
            uint crc = 0xFFFFFFFF;
            int end = offset + count;
            for (int i = offset; i < end; i++)
            {
                int idx = (int)((crc ^ bytes[i]) & 0xFF);
                crc = CrcTable[idx] ^ (crc >> 8);
            }
            return crc ^ 0xFFFFFFFF;
        }

        public static void FillCtrCounters(byte[] buffer, int fileIdx, long blockIndex, int blocks)
        {
            byte[] fi = BitConverter.GetBytes(fileIdx);
            byte[] bi = BitConverter.GetBytes(blockIndex);
            for (int i = 0; i < blocks; i++)
            {
                int o = i * 16;
                Buffer.BlockCopy(fi, 0, buffer, o, 4);
                Buffer.BlockCopy(bi, 0, buffer, o + 4, 8);
                byte[] ci = BitConverter.GetBytes(i);
                Buffer.BlockCopy(ci, 0, buffer, o + 12, 4);
            }
        }

        public static void FillRandomCounters(byte[] buffer, ulong startCounter, int blocks)
        {
            for (int b = 0; b < blocks; b++)
            {
                ulong c = startCounter + (ulong)b;
                byte[] cb = BitConverter.GetBytes(c);
                Buffer.BlockCopy(cb, 0, buffer, b * 16, 8);
            }
        }

        public static void StampHeader(byte[] buffer, int at, byte[] runIdBytes, int fileIdx, long offset)
        {
            Buffer.BlockCopy(runIdBytes, 0, buffer, at, 16);
            byte[] fi = BitConverter.GetBytes((long)fileIdx);
            Buffer.BlockCopy(fi, 0, buffer, at + 16, 8);
            byte[] offBytes = BitConverter.GetBytes(offset);
            Buffer.BlockCopy(offBytes, 0, buffer, at + 24, 8);
            for (int k = 0; k < 4; k++) buffer[at + 32 + k] = 0;
            Buffer.BlockCopy(Magic, 0, buffer, at + 36, 4);

            byte[] head = new byte[40];
            Buffer.BlockCopy(buffer, at, head, 0, 40);
            uint crc = ComputeCrc32(head, 0, 40);
            byte[] crcBytes = BitConverter.GetBytes(crc);
            Buffer.BlockCopy(crcBytes, 0, buffer, at + 32, 4);
        }

        public static void StampHeaders(byte[] buffer, byte[] runIdBytes, int fileIdx, long startOffset, int blockCount, int blockSize)
        {
            for (int b = 0; b < blockCount; b++)
            {
                int at = b * blockSize;
                long offset = startOffset + (long)b * blockSize;
                StampHeader(buffer, at, runIdBytes, fileIdx, offset);
            }
        }

        public static bool ByteArraysEqual(byte[] a, byte[] b, int count)
        {
            if (a == null || b == null || count <= 0) return false;
            if (a.Length < count || b.Length < count) return false;
            for (int i = 0; i < count; i++)
            {
                if (a[i] != b[i]) return false;
            }
            return true;
        }
    }
}
'@
}

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
        CRC-32 (IEEE 802.3 poly 0xEDB88320).
        Used by the integrity pattern to stamp each 4 KiB block with its position.
    #>
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [int]$Offset = 0,
        [int]$Count = -1
    )
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
        [StorageBench.PatternHelper]::CrcTable = $tbl
    }
    [StorageBench.PatternHelper]::ComputeCrc32($Bytes, $Offset, $Count)
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
        [StorageBench.PatternHelper]::FillRandomCounters($inBuf, $this.Counter, $blocks)
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
