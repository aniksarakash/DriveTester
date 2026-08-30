<#
    Tools.ps1 - optional external tool policy.

    StorageBench works with zero external dependencies. smartctl adds real SMART
    attributes; diskspd adds a cross-check on throughput. Both are optional and
    both are subject to the same rule:

        A binary is never executed unless its SHA-256 was verified against a
        pin recorded in this file.

    A pin of $null means "fetching is disabled for this tool" - no download is
    attempted, nothing is executed, and a warning is recorded so the report can
    say why SMART was unverified. Populating a pin is a deliberate, reviewable
    edit to this table, not something the tool does to itself.
#>

$script:SbToolPins = @{
    Smartctl = @{
        Name        = 'smartctl'
        Version     = '7.5'
        Url         = 'https://sourceforge.net/projects/smartmontools/files/smartmontools/7.5/smartmontools-7.5.win32-setup.exe/download'
        FileName    = 'smartmontools-7.5.win32-setup.exe'
        Sha256      = $null
        Kind        = 'installer'
        InstallArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        ExeName     = 'smartctl.exe'
    }
    DiskSpd  = @{
        Name        = 'diskspd'
        Version     = '2.2'
        Url         = 'https://github.com/microsoft/diskspd/releases/download/v2.2/DiskSpd.ZIP'
        FileName    = 'DiskSpd.ZIP'
        Sha256      = $null
        Kind        = 'zip'
        InstallArgs = ''
        ExeName     = 'diskspd.exe'
    }
}

$script:SbFetchDeclined = @{}
$script:SbToolsDirOverride = $null

function Get-ToolsDir {
    <# Where fetched tools land: <script root>\tools (git-ignored). #>
    [OutputType([string])]
    param()
    if ($script:SbToolsDirOverride) { return $script:SbToolsDirOverride }
    if ($script:SbRootDir) { return (Join-Path $script:SbRootDir 'tools') }
    Join-Path ([System.IO.Path]::GetTempPath()) 'StorageBenchTools'
}

function Set-ToolsDirOverride {
    <# Test seam. #>
    param([AllowNull()][string]$Path)
    $script:SbToolsDirOverride = $Path
}

function Get-FileHash256 {
    <# Lowercase hex SHA-256, or $null when unreadable. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    } catch { return $null }
}

function Find-ToolExecutable {
    <#
        Looks for an already-present executable: PATH first (a user's own
        install is trusted - they put it there), then our own tools directory.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$ExeName)

    try {
        $cmd = Get-Command $ExeName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($cmd) { return @{ Path = $cmd.Source; Source = 'path' } }
    } catch { }

    # Common Windows install locations for smartmontools.
    if ($ExeName -eq 'smartctl.exe') {
        foreach ($p in @(
                (Join-Path $env:ProgramFiles 'smartmontools\bin\smartctl.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'smartmontools\bin\smartctl.exe')
            )) {
            if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) {
                return @{ Path = $p; Source = 'installed' }
            }
        }
    }

    $dir = Get-ToolsDir
    if (Test-Path -LiteralPath $dir) {
        try {
            $hit = Get-ChildItem -LiteralPath $dir -Filter $ExeName -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
            if ($hit) { return @{ Path = $hit.FullName; Source = 'fetched' } }
        } catch { }
    }

    @{ Path = $null; Source = 'none' }
}

function Invoke-CapturedProcess {
    <#
        Runs an executable with a hard timeout and captures both streams.
        Returns @{Ok;ExitCode;StdOut;StdErr;TimedOut}. Never throws - a missing
        or hostile tool must not take down a benchmark run.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30
    )

    $res = @{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false }
    $p = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $FilePath
        foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add([string]$a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $res.TimedOut = $true
            try { $p.Kill($true) } catch { }
            $res.StdErr = "timed out after ${TimeoutSeconds}s"
            return $res
        }
        $res.StdOut = $outTask.GetAwaiter().GetResult()
        $res.StdErr = $errTask.GetAwaiter().GetResult()
        $res.ExitCode = $p.ExitCode
        $res.Ok = $true
        return $res
    } catch {
        $res.StdErr = $_.Exception.Message
        return $res
    } finally {
        if ($p) { try { $p.Dispose() } catch { } }
    }
}

function Get-ToolVersion {
    <# First line of the tool's version banner, or ''. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [string]$VersionArg = '--version')
    $r = Invoke-CapturedProcess -FilePath $Path -Arguments @($VersionArg) -TimeoutSeconds 15
    $text = if ($r.StdOut) { $r.StdOut } else { $r.StdErr }
    if (-not $text) { return '' }
    ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
}

function Add-ToolWarning {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Message
    )
    if ($State.Warnings -notcontains $Message) { $State.Warnings = @($State.Warnings) + $Message }
}

function Get-ToolState {
    <#
        Discovers what is available right now. Never downloads, never prompts.
        Returns @{Smartctl=@{Path;Source;Version;Ok;Pin};DiskSpd=@{...};Warnings=@()}
    #>
    [OutputType([hashtable])]
    param()

    $state = @{
        Smartctl = @{ Path = $null; Source = 'none'; Version = ''; Ok = $false; Pin = $null; FetchDisabled = $false }
        DiskSpd  = @{ Path = $null; Source = 'none'; Version = ''; Ok = $false; Pin = $null; FetchDisabled = $false }
        Warnings = @()
    }

    foreach ($key in @('Smartctl', 'DiskSpd')) {
        $pin = $script:SbToolPins[$key]
        $state[$key].Pin = @{
            Version  = $pin.Version
            Url      = $pin.Url
            FileName = $pin.FileName
            Sha256   = $pin.Sha256
        }
        $state[$key].FetchDisabled = ($null -eq $pin.Sha256)

        $found = Find-ToolExecutable -ExeName $pin.ExeName
        if ($found.Path) {
            $state[$key].Path = $found.Path
            $state[$key].Source = $found.Source
            $state[$key].Version = Get-ToolVersion -Path $found.Path
            $state[$key].Ok = $true
            $state[$key].Sha256 = Get-FileHash256 -Path $found.Path
        } else {
            $msg = if ($null -eq $pin.Sha256) {
                "$($pin.Name) not found; auto-fetch is disabled (no verified hash pinned in lib/Tools.ps1). Install it manually to enable this feature."
            } else {
                "$($pin.Name) not found; run with -FetchTools to download the pinned $($pin.Version) build."
            }
            Add-ToolWarning -State $state -Message $msg
        }
    }

    $state
}

function Invoke-ToolFetch {
    <#
        Downloads and unpacks a pinned tool - but only when the pin carries a
        SHA-256. Returns @{Ok;Reason;Path}. Honours -NoNet and remembers a
        decline for the rest of the session so the user is asked at most once.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('Smartctl', 'DiskSpd')][string]$Tool,
        [switch]$NoNet,
        [switch]$Consented
    )

    $pin = $script:SbToolPins[$Tool]
    if ($null -eq $pin.Sha256) {
        return @{ Ok = $false; Path = $null
            Reason = "Fetch disabled for $($pin.Name): no SHA-256 pinned. StorageBench never runs an unverified binary."
        }
    }
    if ($NoNet) { return @{ Ok = $false; Path = $null; Reason = "-NoNet given; skipping $($pin.Name) download." } }
    if ($script:SbFetchDeclined[$Tool]) { return @{ Ok = $false; Path = $null; Reason = 'declined earlier this session' } }
    if (-not $Consented) {
        $script:SbFetchDeclined[$Tool] = $true
        return @{ Ok = $false; Path = $null; Reason = 'no consent given' }
    }

    $dir = Join-Path (Get-ToolsDir) $Tool
    if (-not (Test-Path -LiteralPath $dir)) {
        try { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) }
        catch { return @{ Ok = $false; Path = $null; Reason = $_.Exception.Message } }
    }
    $pkg = Join-Path $dir $pin.FileName

    try {
        Invoke-WebRequest -Uri $pin.Url -OutFile $pkg -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
    } catch {
        return @{ Ok = $false; Path = $null; Reason = "download failed: $($_.Exception.Message)" }
    }

    $actual = Get-FileHash256 -Path $pkg
    if ($actual -ne $pin.Sha256.ToLowerInvariant()) {
        try { Remove-Item -LiteralPath $pkg -Force -ErrorAction SilentlyContinue } catch { }
        return @{ Ok = $false; Path = $null
            Reason = "SHA-256 mismatch for $($pin.FileName) (expected $($pin.Sha256), got $actual). Package deleted."
        }
    }

    if ($pin.Kind -eq 'zip') {
        try { Expand-Archive -LiteralPath $pkg -DestinationPath $dir -Force -ErrorAction Stop }
        catch { return @{ Ok = $false; Path = $null; Reason = "unpack failed: $($_.Exception.Message)" } }
    } else {
        $r = Invoke-CapturedProcess -FilePath $pkg -Arguments @($pin.InstallArgs -split '\s+' | Where-Object { $_ }) -TimeoutSeconds 180
        if (-not $r.Ok -or $r.ExitCode -ne 0) {
            return @{ Ok = $false; Path = $null; Reason = "installer exit $($r.ExitCode): $($r.StdErr)" }
        }
    }

    $found = Find-ToolExecutable -ExeName $pin.ExeName
    if (-not $found.Path) { return @{ Ok = $false; Path = $null; Reason = "$($pin.ExeName) not present after install" } }
    @{ Ok = $true; Path = $found.Path; Reason = '' }
}

function Invoke-Smartctl {
    <#
        smartctl exit status is a bitmask, not a success flag: bit 0 = usage
        error, bit 1 = device open failed, bit 2 = command failed. Bits 3-7 are
        real findings (failing now, prefail, logged errors) and still come with
        valid output, so they must not be treated as tool failures.

        Returns @{Ok;ExitCode;StdOut;StdErr;DeviceError;Findings}.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$SmartctlPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    $r = Invoke-CapturedProcess -FilePath $SmartctlPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    $code = [int]$r.ExitCode
    $deviceError = (-not $r.Ok) -or $r.TimedOut -or (($code -band 0x07) -ne 0)

    @{
        Ok          = ($r.Ok -and -not $r.TimedOut -and -not $deviceError)
        ExitCode    = $code
        StdOut      = $r.StdOut
        StdErr      = $r.StdErr
        TimedOut    = [bool]$r.TimedOut
        DeviceError = [bool]$deviceError
        Findings    = @{
            FailingNow  = (($code -band 0x08) -ne 0)
            PrefailPast = (($code -band 0x10) -ne 0)
            ErrorLog    = (($code -band 0x40) -ne 0)
            SelfTestBad = (($code -band 0x80) -ne 0)
        }
    }
}
