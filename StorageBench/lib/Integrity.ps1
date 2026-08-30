<#
    Integrity.ps1 - does the drive give back exactly what it was given?

    This is the h2testw question, and it is the one that catches counterfeit
    flash: a card sold as 1 TB that is really 32 GB will happily accept every
    write, silently wrapping around and destroying what came before. Only
    writing a known pattern and reading it back reveals that.

    The pattern is a 4 KiB block whose first 40 bytes say where it belongs:

        0..15   run identity (SHA-256 of the run id, first 16 bytes)
        16..23  file index      (int64, little endian)
        24..31  byte offset     (int64, little endian)
        32..35  CRC32 of the header with this field zeroed
        36..39  magic 'SBK1'
        40..    AES-CTR keystream keyed by the run id - incompressible, so a
                controller cannot fake the write, and reproducible, so
                verification needs no stored copy

    A block that reads back with a *different* valid header is the fingerprint
    of address wrapping: the drive lied about its capacity.
#>

$script:SbBlock = 4096
$script:SbMagic = [byte[]]@(0x53, 0x42, 0x4B, 0x31)   # 'SBK1'
$script:SbPatternCtx = $null

function New-PatternContext {
    <# AES-CTR keystream generator for one run id. Cached: keying is not free. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RunId)

    if ($script:SbPatternCtx -and $script:SbPatternCtx.RunId -eq $RunId) { return $script:SbPatternCtx }
    if ($script:SbPatternCtx) { try { $script:SbPatternCtx.Aes.Dispose() } catch { } }

    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($RunId)
    $key = [System.Security.Cryptography.SHA256]::HashData($keyBytes)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None

    $script:SbPatternCtx = @{
        RunId      = $RunId
        Aes        = $aes
        Encryptor  = $aes.CreateEncryptor()
        RunIdBytes = $key[0..15]
    }
    $script:SbPatternCtx
}

function New-PatternKeystream {
    <#
        Deterministic incompressible bytes for a (fileIdx, blockIndex) span.
        Built as real AES-CTR: each 16-byte counter is
        [fileIdx:int32][blockIndex:int64][counter:int32], encrypted in one call.
    #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][int]$FileIdx,
        [Parameter(Mandatory)][long]$BlockIndex,
        [Parameter(Mandatory)][int]$ByteCount
    )

    $blocks = [int][math]::Ceiling($ByteCount / 16.0)
    $ctr = [byte[]]::new($blocks * 16)
    $fi = [System.BitConverter]::GetBytes([int]$FileIdx)
    $bi = [System.BitConverter]::GetBytes([long]$BlockIndex)
    for ($i = 0; $i -lt $blocks; $i++) {
        $o = $i * 16
        [System.Array]::Copy($fi, 0, $ctr, $o, 4)
        [System.Array]::Copy($bi, 0, $ctr, $o + 4, 8)
        [System.Array]::Copy([System.BitConverter]::GetBytes([int]$i), 0, $ctr, $o + 12, 4)
    }
    $out = $Ctx.Encryptor.TransformFinalBlock($ctr, 0, $ctr.Length)
    if ($out.Length -eq $ByteCount) { return $out }
    $trim = [byte[]]::new($ByteCount)
    [System.Array]::Copy($out, 0, $trim, 0, $ByteCount)
    $trim
}

function Set-PatternHeader {
    <# Stamps the 40-byte header into $Buffer at $At. #>
    param(
        [Parameter(Mandatory)][byte[]]$Buffer,
        [Parameter(Mandatory)][int]$At,
        [Parameter(Mandatory)][byte[]]$RunIdBytes,
        [Parameter(Mandatory)][int]$FileIdx,
        [Parameter(Mandatory)][long]$Offset
    )
    [System.Array]::Copy($RunIdBytes, 0, $Buffer, $At, 16)
    [System.Array]::Copy([System.BitConverter]::GetBytes([long]$FileIdx), 0, $Buffer, $At + 16, 8)
    [System.Array]::Copy([System.BitConverter]::GetBytes([long]$Offset), 0, $Buffer, $At + 24, 8)
    for ($i = 0; $i -lt 4; $i++) { $Buffer[$At + 32 + $i] = 0 }
    [System.Array]::Copy($script:SbMagic, 0, $Buffer, $At + 36, 4)

    $head = [byte[]]::new(40)
    [System.Array]::Copy($Buffer, $At, $head, 0, 40)
    $crc = Get-Crc32 -Bytes $head
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]$crc), 0, $Buffer, $At + 32, 4)
}

function Read-PatternHeader {
    <#
        Parses a header if one is there. Returns
        @{Valid;RunIdBytes;FileIdx;Offset;Crc;CrcOk}. Used to tell "garbage"
        from "somebody else's block", which is the counterfeit signal.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][byte[]]$Buffer,
        [int]$At = 0
    )

    $res = @{ Valid = $false; RunIdBytes = $null; FileIdx = $null; Offset = $null; Crc = $null; CrcOk = $false }
    if ($Buffer.Length - $At -lt 40) { return $res }

    for ($i = 0; $i -lt 4; $i++) {
        if ($Buffer[$At + 36 + $i] -ne $script:SbMagic[$i]) { return $res }
    }

    $stored = [System.BitConverter]::ToUInt32($Buffer, $At + 32)
    $head = [byte[]]::new(40)
    [System.Array]::Copy($Buffer, $At, $head, 0, 40)
    for ($i = 32; $i -lt 36; $i++) { $head[$i] = 0 }
    $res.Crc = $stored
    $res.CrcOk = ((Get-Crc32 -Bytes $head) -eq $stored)
    $res.RunIdBytes = $head[0..15]
    $res.FileIdx = [System.BitConverter]::ToInt64($Buffer, $At + 16)
    $res.Offset = [System.BitConverter]::ToInt64($Buffer, $At + 24)
    $res.Valid = $res.CrcOk
    $res
}

function New-PatternBlock {
    <# One stamped, self-describing 4 KiB block. #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$FileIdx,
        [Parameter(Mandatory)][long]$Offset
    )

    $ctx = New-PatternContext -RunId $RunId
    $blockIndex = [long]([math]::Floor($Offset / $script:SbBlock))
    $body = New-PatternKeystream -Ctx $ctx -FileIdx $FileIdx -BlockIndex $blockIndex -ByteCount ($script:SbBlock - 40)

    $b = [byte[]]::new($script:SbBlock)
    [System.Array]::Copy($body, 0, $b, 40, $body.Length)
    Set-PatternHeader -Buffer $b -At 0 -RunIdBytes $ctx.RunIdBytes -FileIdx $FileIdx -Offset $Offset
    $b
}

function Test-PatternBlock {
    <#
        Verifies one block. Returns @{Ok;MismatchByte;Expected;Actual;Kind;Header}.

        Kind names what went wrong: 'ok', 'header' (wrong or missing header),
        'wrapped' (a valid header for a different location - counterfeit
        capacity), or 'data' (right header, corrupted payload).
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][byte[]]$Block,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$FileIdx,
        [Parameter(Mandatory)][long]$Offset
    )

    $expected = New-PatternBlock -RunId $RunId -FileIdx $FileIdx -Offset $Offset
    $res = @{ Ok = $true; MismatchByte = $null; Expected = $null; Actual = $null; Kind = 'ok'; Header = $null }

    $n = [math]::Min($expected.Length, $Block.Length)
    for ($i = 0; $i -lt $n; $i++) {
        if ($Block[$i] -ne $expected[$i]) {
            $res.Ok = $false
            $res.MismatchByte = $i
            $res.Expected = $expected[$i]
            $res.Actual = $Block[$i]
            break
        }
    }
    if ($Block.Length -lt $expected.Length) {
        $res.Ok = $false
        if ($null -eq $res.MismatchByte) { $res.MismatchByte = $Block.Length }
    }
    if ($res.Ok) { return $res }

    $hdr = Read-PatternHeader -Buffer $Block -At 0
    $res.Header = $hdr
    if (-not $hdr.Valid) {
        $res.Kind = 'header'
    } elseif ($hdr.FileIdx -ne $FileIdx -or $hdr.Offset -ne $Offset) {
        $res.Kind = 'wrapped'
    } else {
        $res.Kind = 'data'
    }
    $res
}

Set-Alias -Name Verify-PatternBlock -Value Test-PatternBlock -Scope Script -Force

function Get-SpanDigest {
    <# Hardware-accelerated SHA-256 over part of a buffer - the fast path. #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][byte[]]$Buffer,
        [Parameter(Mandatory)][int]$Count
    )
    if ($Count -eq $Buffer.Length) { return [System.Security.Cryptography.SHA256]::HashData($Buffer) }
    $tmp = [byte[]]::new($Count)
    [System.Array]::Copy($Buffer, 0, $tmp, 0, $Count)
    [System.Security.Cryptography.SHA256]::HashData($tmp)
}

function Test-DigestEqual {
    [OutputType([bool])]
    param([Parameter(Mandatory)][byte[]]$A, [Parameter(Mandatory)][byte[]]$B)
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    $true
}

function New-PatternSpan {
    <#
        A whole chunk of consecutive stamped blocks, built with one AES call and
        one header pass. This is what makes megabyte-per-second verification
        possible from PowerShell.
    #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][int]$FileIdx,
        [Parameter(Mandatory)][long]$StartOffset,
        [Parameter(Mandatory)][int]$BlockCount
    )

    $total = $BlockCount * $script:SbBlock
    $buf = [System.GC]::AllocateArray[byte]($total, $true)
    $startIdx = [long]([math]::Floor($StartOffset / $script:SbBlock))

    # One keystream covering every block in the span, then headers stamped over it.
    $ks = New-PatternKeystream -Ctx $Ctx -FileIdx $FileIdx -BlockIndex $startIdx -ByteCount $total
    [System.Array]::Copy($ks, 0, $buf, 0, $total)

    for ($i = 0; $i -lt $BlockCount; $i++) {
        Set-PatternHeader -Buffer $buf -At ($i * $script:SbBlock) `
            -RunIdBytes $Ctx.RunIdBytes -FileIdx $FileIdx -Offset ($StartOffset + [long]$i * $script:SbBlock)
    }
    $buf
}

function Invoke-IntegrityScan {
    <#
        Write a known pattern into free space, read it back, and account for
        every byte.

        Mode 'Full'   - one contiguous region of $SizeMB, written then verified.
        Mode 'Spread' - the same total split into several files placed across
                        the free space, which is what exposes a drive that
                        wraps its address space.

        Returns @{Ok;VerifiedMB;WrittenMB;Errors;CounterfeitSuspected;
                  CoveragePct;WriteMBps;ReadMBps;Files;Reason}
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Volume,
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][int]$SizeMB,
        [ValidateSet('Full', 'Spread')][string]$Mode = 'Full',
        [scriptblock]$ProgressCb,
        [int]$ChunkMB = 4
    )

    $res = @{
        Ok = $false; VerifiedMB = 0; WrittenMB = 0; Errors = @()
        CounterfeitSuspected = $false; CoveragePct = 0.0
        WriteMBps = $null; ReadMBps = $null; Files = @(); Reason = ''
    }

    $drive = [char]$Session.Drive
    $needBytes = [long]$SizeMB * 1MB
    $reserve = Test-Reserve -Drive $drive -NeedBytes $needBytes
    if (-not $reserve.Ok) { $res.Reason = $reserve.Reason; return $res }

    $ctx = New-PatternContext -RunId $Session.RunId
    $chunkBlocks = [int](($ChunkMB * 1MB) / $script:SbBlock)
    $chunkBytes = $chunkBlocks * $script:SbBlock

    $fileCount = if ($Mode -eq 'Spread') { 8 } else { 1 }
    $perFileBytes = [long]([math]::Floor($needBytes / $fileCount / $chunkBytes) * $chunkBytes)
    if ($perFileBytes -lt $chunkBytes) {
        $perFileBytes = $chunkBytes
        $fileCount = [int][math]::Max(1, [math]::Floor($needBytes / $chunkBytes))
    }

    $errors = [System.Collections.ArrayList]::new()
    $files = [System.Collections.ArrayList]::new()
    $totalWritten = 0L
    $totalVerified = 0L
    $writeSecs = 0.0
    $readSecs = 0.0

    # --- write phase -------------------------------------------------------
    for ($f = 0; $f -lt $fileCount; $f++) {
        $path = Register-ScratchFile -Session $Session -Path (Join-Path $Session.Root ('integrity-{0:d2}.bin' -f $f))
        [void]$files.Add($path)
        $open = New-BenchStream -Path $path -Access Write -Mode Create
        if (-not $open.Stream) {
            [void]$errors.Add([pscustomobject]@{ FileIdx = $f; Offset = 0L; Kind = 'open'; Detail = $open.Reason })
            continue
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $off = 0L
            while ($off -lt $perFileBytes) {
                $span = New-PatternSpan -Ctx $ctx -FileIdx $f -StartOffset $off -BlockCount $chunkBlocks
                $open.Stream.Write($span, 0, $span.Length)
                $off += $chunkBytes
                $totalWritten += $chunkBytes
                if ($ProgressCb) { & $ProgressCb @{ Phase = 'write'; FileIdx = $f; Files = $fileCount; Bytes = $totalWritten; TotalBytes = ([long]$perFileBytes * $fileCount) } }
            }
            $open.Stream.Flush($true)
        } catch {
            [void]$errors.Add([pscustomobject]@{ FileIdx = $f; Offset = $totalWritten; Kind = 'write'; Detail = $_.Exception.Message })
        } finally {
            try { $open.Stream.Dispose() } catch { }
            $sw.Stop(); $writeSecs += $sw.Elapsed.TotalSeconds
        }
    }
    $res.WrittenMB = [int]($totalWritten / 1MB)
    $res.Files = @($files)
    if ($writeSecs -gt 0) { $res.WriteMBps = [double](($totalWritten / 1MB) / $writeSecs) }

    # --- verify phase ------------------------------------------------------
    # Read back in the same order but from cold storage: the streams above were
    # opened unbuffered and flushed, so nothing here is answered by RAM.
    for ($f = 0; $f -lt $files.Count; $f++) {
        $path = $files[$f]
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $open = New-BenchStream -Path $path -Access Read -Mode Open
        if (-not $open.Stream) {
            [void]$errors.Add([pscustomobject]@{ FileIdx = $f; Offset = 0L; Kind = 'open'; Detail = $open.Reason })
            continue
        }
        $actual = [System.GC]::AllocateArray[byte]($chunkBytes, $true)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $off = 0L
            $len = $open.Stream.Length
            while ($off -lt $len) {
                $want = [int][math]::Min([long]$chunkBytes, $len - $off)
                $got = 0
                while ($got -lt $want) {
                    $n = $open.Stream.Read($actual, $got, $want - $got)
                    if ($n -le 0) { break }
                    $got += $n
                }
                if ($got -le 0) { break }

                $expected = New-PatternSpan -Ctx $ctx -FileIdx $f -StartOffset $off -BlockCount ([int]($got / $script:SbBlock))
                if (-not (Test-DigestEqual (Get-SpanDigest -Buffer $actual -Count $expected.Length) (Get-SpanDigest -Buffer $expected -Count $expected.Length))) {
                    # Narrow it down to the offending block, then classify it.
                    $blocks = [int]($expected.Length / $script:SbBlock)
                    for ($b = 0; $b -lt $blocks; $b++) {
                        $at = $b * $script:SbBlock
                        $one = [byte[]]::new($script:SbBlock)
                        [System.Array]::Copy($actual, $at, $one, 0, $script:SbBlock)
                        $chk = Test-PatternBlock -Block $one -RunId $Session.RunId -FileIdx $f -Offset ($off + $at)
                        if (-not $chk.Ok) {
                            if ($chk.Kind -eq 'wrapped') { $res.CounterfeitSuspected = $true }
                            $detail = 'byte {0}: expected 0x{1:X2}, read 0x{2:X2}' -f $chk.MismatchByte, $chk.Expected, $chk.Actual
                            [void]$errors.Add([pscustomobject]@{
                                    FileIdx = $f
                                    Offset  = ($off + $at)
                                    Kind    = $chk.Kind
                                    Detail  = $detail
                                    Header  = $chk.Header
                                })
                            if ($errors.Count -ge 64) { break }
                        }
                    }
                }
                $off += $got
                $totalVerified += $got
                if ($ProgressCb) { & $ProgressCb @{ Phase = 'verify'; FileIdx = $f; Files = $files.Count; Bytes = $totalVerified; TotalBytes = $totalWritten } }
                if ($errors.Count -ge 64) {
                    [void]$errors.Add([pscustomobject]@{ FileIdx = $f; Offset = $off; Kind = 'aborted'; Detail = 'too many errors; stopped reporting' })
                    break
                }
            }
        } catch {
            [void]$errors.Add([pscustomobject]@{ FileIdx = $f; Offset = $totalVerified; Kind = 'read'; Detail = $_.Exception.Message })
        } finally {
            try { $open.Stream.Dispose() } catch { }
            $sw.Stop(); $readSecs += $sw.Elapsed.TotalSeconds
        }
        if ($errors.Count -ge 65) { break }
    }

    $res.VerifiedMB = [int]($totalVerified / 1MB)
    if ($readSecs -gt 0) { $res.ReadMBps = [double](($totalVerified / 1MB) / $readSecs) }
    $res.Errors = @($errors)
    $res.Ok = ($errors.Count -eq 0 -and $totalVerified -gt 0)

    $volSize = if ($Volume -and $Volume.SizeBytes) { [long]$Volume.SizeBytes } else { 0L }
    if ($volSize -gt 0) { $res.CoveragePct = [double][math]::Round(($totalVerified / $volSize) * 100.0, 3) }

    if (-not $res.Ok -and $errors.Count -eq 0) { $res.Reason = 'nothing was verified' }
    $res
}
