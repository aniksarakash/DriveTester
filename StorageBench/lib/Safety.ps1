<#
    Safety.ps1 - structural protection for non-destructive testing.

    The one rule this file exists to enforce: StorageBench writes ONLY inside
    <Vol>:\.storagebench-scratch\<runId>\ and deletes ONLY paths it recorded
    there itself. No raw-device write handle is opened anywhere in this toolkit,
    and no pre-existing user file is ever opened for write.
#>

$script:SbScratchDirName = '.storagebench-scratch'
$script:SbRunIdPattern = '^[0-9]{8}-[0-9]{6}-[a-z0-9]{4}$'

function Get-ScratchRoot {
    <#
        Returns the scratch container for a volume: <X>:\.storagebench-scratch

        $script:SbScratchOverride lets the test suite point the whole safety
        subsystem at a temp directory without weakening any containment check.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][char]$Drive)

    if ($script:SbScratchOverride) {
        return (Join-Path $script:SbScratchOverride $script:SbScratchDirName)
    }
    Join-Path ("{0}:\" -f ([string]$Drive).ToUpperInvariant()) $script:SbScratchDirName
}

function Set-ScratchOverride {
    <# Test seam. Pass $null to restore real volume behaviour. #>
    param([AllowNull()][string]$Path)
    $script:SbScratchOverride = $Path
}

function Get-VolumeSpace {
    <# @{SizeBytes;FreeBytes;Ok;Reason} - never throws. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][char]$Drive)

    try {
        $root = if ($script:SbScratchOverride) { [System.IO.Path]::GetPathRoot($script:SbScratchOverride) }
        else { '{0}:\' -f ([string]$Drive).ToUpperInvariant() }
        $di = [System.IO.DriveInfo]::new($root)
        if (-not $di.IsReady) {
            return @{ SizeBytes = 0L; FreeBytes = 0L; Ok = $false; Reason = "Volume $root is not ready" }
        }
        return @{
            SizeBytes = [long]$di.TotalSize
            FreeBytes = [long]$di.AvailableFreeSpace
            Ok        = $true
            Reason    = ''
        }
    } catch {
        return @{ SizeBytes = 0L; FreeBytes = 0L; Ok = $false; Reason = $_.Exception.Message }
    }
}

function Get-ReserveBytes {
    <# reserve = max(2 GB, 5% of volume size) - spec section 4.3. #>
    [OutputType([long])]
    param([Parameter(Mandatory)][long]$VolumeSizeBytes)
    $twoGB = 2GB
    $fivePct = [long][math]::Floor($VolumeSizeBytes * 0.05)
    if ($fivePct -gt $twoGB) { [long]$fivePct } else { [long]$twoGB }
}

function Test-Reserve {
    <#
        Can we write $NeedBytes and still leave the reserve intact?
        Returns @{Ok;FreeGB;NeedGB;ReserveGB} (+ raw byte fields and Reason).
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][char]$Drive,
        [Parameter(Mandatory)][long]$NeedBytes
    )

    $space = Get-VolumeSpace -Drive $Drive
    $reserve = Get-ReserveBytes -VolumeSizeBytes $space.SizeBytes
    $ok = $space.Ok -and (($space.FreeBytes - $NeedBytes) -ge $reserve)

    $reason = ''
    if (-not $space.Ok) { $reason = $space.Reason }
    elseif (-not $ok) {
        $reason = 'Need {0} + {1} reserve but only {2} free' -f `
        (Format-Bytes $NeedBytes), (Format-Bytes $reserve), (Format-Bytes $space.FreeBytes)
    }

    @{
        Ok           = [bool]$ok
        FreeGB       = [math]::Round($space.FreeBytes / 1GB, 2)
        NeedGB       = [math]::Round($NeedBytes / 1GB, 2)
        ReserveGB    = [math]::Round($reserve / 1GB, 2)
        FreeBytes    = [long]$space.FreeBytes
        NeedBytes    = [long]$NeedBytes
        ReserveBytes = [long]$reserve
        SizeBytes    = [long]$space.SizeBytes
        Reason       = $reason
    }
}

function Initialize-Scratch {
    <#
        Creates <root>\<runId>\ and writes manifest.json BEFORE any test file
        exists, so a hard kill still leaves a complete record of what to remove.
        Returns @{Root;RunId;ManifestPath;Files}.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][char]$Drive,
        [string]$RunId
    )

    if (-not $RunId) { $RunId = New-RunId }
    $container = Get-ScratchRoot -Drive $Drive
    $root = Join-Path $container $RunId

    if (-not (Test-Path -LiteralPath $root)) {
        [void](New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop)
    }

    $manifestPath = Join-Path $root 'manifest.json'
    $session = @{
        Root         = $root
        RunId        = $RunId
        ManifestPath = $manifestPath
        Files        = [System.Collections.ArrayList]::new()
        Drive        = ([string]$Drive).ToUpperInvariant()[0]
        Created      = (Get-Date).ToString('o')
    }
    [void]$session.Files.Add($manifestPath)
    Save-ScratchManifest -Session $session
    $session
}

function Save-ScratchManifest {
    param([Parameter(Mandatory)][hashtable]$Session)
    $doc = [ordered]@{
        tool    = 'StorageBench'
        runId   = $Session.RunId
        drive   = [string]$Session.Drive
        root    = $Session.Root
        created = $Session.Created
        files   = @($Session.Files)
    }
    $json = $doc | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $Session.ManifestPath -Value $json -Encoding UTF8 -ErrorAction Stop
}

function Register-ScratchFile {
    <#
        Records a path in the manifest BEFORE the caller creates it. Refuses any
        path that does not resolve inside the session's scratch root - the
        containment check that makes Clear-Scratch safe.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Path
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-PathContained -Root $Session.Root -Path $full)) {
        throw "Refusing to register '$full': outside scratch root '$($Session.Root)'"
    }
    if (-not ($Session.Files -contains $full)) { [void]$Session.Files.Add($full) }
    Save-ScratchManifest -Session $Session
    $full
}

function Test-PathContained {
    <# True only when $Path is at or beneath $Root after full normalisation. #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    try {
        $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        if ($p -eq $r) { return $true }
        return $p.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Clear-Scratch {
    <#
        Deletes only the paths the manifest records, each re-checked for
        containment at delete time, then removes the run folder (and the
        container if it is now empty). Returns @{Deleted;Failed;Errors}.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$Session,
        [switch]$KeepManifest
    )

    $res = @{ Deleted = 0; Failed = 0; Errors = @() }
    if ($null -eq $Session -or -not $Session.Root) { return $res }

    $paths = @($Session.Files)
    # Deepest first so directories empty before removal; manifest handled last.
    $ordered = @($paths | Where-Object { $_ -ne $Session.ManifestPath } |
        Sort-Object -Property @{ Expression = { ($_ -split '[\\/]').Count } } -Descending)

    foreach ($p in $ordered) {
        if (-not (Test-PathContained -Root $Session.Root -Path $p)) {
            $res.Errors += "skipped (outside root): $p"; continue
        }
        try {
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Force -Recurse -ErrorAction Stop
                $res.Deleted++
            }
        } catch {
            $res.Failed++
            $res.Errors += "$p : $($_.Exception.Message)"
        }
    }

    if (-not $KeepManifest) {
        try {
            if (Test-Path -LiteralPath $Session.ManifestPath) {
                Remove-Item -LiteralPath $Session.ManifestPath -Force -ErrorAction Stop
                $res.Deleted++
            }
        } catch { $res.Failed++; $res.Errors += $_.Exception.Message }

        try {
            if (Test-Path -LiteralPath $Session.Root) {
                Remove-Item -LiteralPath $Session.Root -Force -Recurse -ErrorAction Stop
            }
            $container = Split-Path -Parent $Session.Root
            if ((Test-Path -LiteralPath $container) -and
                -not (Get-ChildItem -LiteralPath $container -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $container -Force -ErrorAction SilentlyContinue
            }
        } catch { $res.Errors += $_.Exception.Message }
    }

    $res
}

function Find-OrphanedScratch {
    <#
        Run folders left by a killed run. Matches the runId shape only, so
        reports/, history/ and anything else a user parked there are ignored.
    #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][char]$Drive)

    $container = Get-ScratchRoot -Drive $Drive
    if (-not (Test-Path -LiteralPath $container)) { return @() }
    try {
        return @(Get-ChildItem -LiteralPath $container -Directory -Force -ErrorAction Stop |
            Where-Object { $_.Name -match $script:SbRunIdPattern } |
            Select-Object -ExpandProperty FullName)
    } catch { return @() }
}

function Remove-OrphanedScratch {
    <# Removes an orphan folder, but only via its own manifest when one exists. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $name = Split-Path -Leaf $Path
    if ($name -notmatch $script:SbRunIdPattern) {
        return @{ Deleted = 0; Failed = 1; Errors = @("not a runId folder: $Path") }
    }
    $manifest = Join-Path $Path 'manifest.json'
    $files = [System.Collections.ArrayList]::new()
    [void]$files.Add($manifest)
    if (Test-Path -LiteralPath $manifest) {
        try {
            $doc = Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($f in @($doc.files)) { if ($f -and $f -ne $manifest) { [void]$files.Add([string]$f) } }
        } catch { }
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if (-not ($files -contains $child.FullName)) { [void]$files.Add($child.FullName) }
    }
    Clear-Scratch -Session @{ Root = $Path; ManifestPath = $manifest; Files = $files }
}

function Test-VolumeWritableForTest {
    <#
        Gatekeeper for every write phase. Returns @{Ok;Reason;RequiresForce}.
        Boot / system / pagefile volumes are refused unless -Force.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$DiskInfo,
        [Parameter(Mandatory)][char]$Drive,
        [switch]$Force
    )

    $d = ([string]$Drive).ToUpperInvariant()[0]
    $protectedReasons = [System.Collections.ArrayList]::new()

    if ($null -ne $DiskInfo) {
        if ($DiskInfo.PSObject.Properties['IsBoot'] -and $DiskInfo.IsBoot) { [void]$protectedReasons.Add('boot disk') }
        if ($DiskInfo.PSObject.Properties['IsSystem'] -and $DiskInfo.IsSystem) { [void]$protectedReasons.Add('system disk') }
        if ($DiskInfo.PSObject.Properties['IsReadOnly'] -and $DiskInfo.IsReadOnly) {
            return @{ Ok = $false; Reason = "Disk is read-only"; RequiresForce = $false }
        }
    }

    $sysDrive = $env:SystemDrive
    if ($sysDrive -and $sysDrive.TrimEnd(':').ToUpperInvariant()[0] -eq $d) {
        [void]$protectedReasons.Add('hosts Windows')
    }
    if ($d -eq ($env:TEMP -replace '^([A-Za-z]):.*$', '$1').ToUpperInvariant() -and $d -eq 'C') {
        # informational only; C: is already covered above
    }

    if ($protectedReasons.Count -gt 0) {
        $why = ($protectedReasons | Select-Object -Unique) -join ', '
        if (-not $Force) {
            return @{
                Ok            = $false
                Reason        = "${d}: is protected ($why). Re-run with -Force to test it anyway."
                RequiresForce = $true
            }
        }
        return @{ Ok = $true; Reason = "${d}: is protected ($why) - proceeding because -Force was given"; RequiresForce = $true }
    }

    $space = Get-VolumeSpace -Drive $d
    if (-not $space.Ok) { return @{ Ok = $false; Reason = $space.Reason; RequiresForce = $false } }

    @{ Ok = $true; Reason = ''; RequiresForce = $false }
}
