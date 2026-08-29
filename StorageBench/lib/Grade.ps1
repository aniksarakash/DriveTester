<#
    Grade.ps1 - one letter, and the reasons behind it.

    Three parts, weighted:

        Health       40   what the drive says about itself
        Integrity    30   whether it returns what it was given
        Performance  30   whether it is as fast as its class should be

    A weighted average alone would let a drive with reallocated sectors and a
    perfect benchmark score its way to an A, so the average is only the starting
    point. Overrides come after, and they only ever move the grade down:

        SMART reports FAILED, or an attribute is at its
        manufacturer threshold                                  -> F
        the drive returned bytes it was not given                -> F
        capacity wraps (counterfeit)                             -> F
        a critical SMART counter has moved off zero              -> C at best
        SMART could not be read at all                           -> B at best

    That last one is the honest-uncertainty cap from the design spec: a drive
    whose health nobody could read has not earned an A, however fast it is.
#>

$script:SbWeights = @{ Health = 0.40; Integrity = 0.30; Performance = 0.30 }

# Grade boundaries on the 0..1 scale. Deliberately not generous: C means
# "works, with reservations", which is what most used drives deserve.
$script:SbLetterBands = @(
    @{ Letter = 'A'; Min = 0.87 }
    @{ Letter = 'B'; Min = 0.72 }
    @{ Letter = 'C'; Min = 0.55 }
    @{ Letter = 'D'; Min = 0.35 }
    @{ Letter = 'F'; Min = 0.00 }
)

$script:SbLetterRank = @{ 'A' = 4; 'B' = 3; 'C' = 2; 'D' = 1; 'F' = 0 }

function Get-LetterForScore {
    [OutputType([string])]
    param([Parameter(Mandatory)][double]$Score01)
    foreach ($b in $script:SbLetterBands) {
        if ($Score01 -ge $b.Min) { return $b.Letter }
    }
    'F'
}

function Get-CappedLetter {
    <# Applies a ceiling. Never raises a grade. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Letter,
        [Parameter(Mandatory)][string]$Cap
    )
    if ($script:SbLetterRank[$Letter] -gt $script:SbLetterRank[$Cap]) { return $Cap }
    $Letter
}

function Get-HealthScore {
    <#
        Health part from a SMART report. Returns @{Score01;Reasons;Cap}.

        Unreadable health is scored as uncertainty, not as failure: 0.60 says
        "no evidence either way", which is the truth. The B cap alongside it is
        what stops that uncertainty from being rewarded.
    #>
    [OutputType([hashtable])]
    param([AllowNull()][hashtable]$Smart)

    $out = @{ Score01 = $null; Reasons = @(); Cap = $null }
    if ($null -eq $Smart) {
        $out.Score01 = 0.60
        $out.Reasons = @('health was not checked')
        $out.Cap = 'B'
        return $out
    }

    $reasons = [System.Collections.ArrayList]::new()
    $failures = @($Smart.Failures)
    $warnings = @($Smart.Warnings)

    if ($failures.Count -gt 0) {
        foreach ($f in $failures) { [void]$reasons.Add("SMART failure: $f") }
        $out.Score01 = 0.0
        $out.Reasons = @($reasons)
        $out.Cap = 'F'
        return $out
    }

    $score = switch ([string]$Smart.Status) {
        'Verified' { 1.0 }
        'Partial' { 0.80 }
        default { 0.60 }
    }

    switch ([string]$Smart.Status) {
        'Verified' { [void]$reasons.Add("SMART read in full via $($Smart.Source); no attribute is at its threshold") }
        'Partial' { [void]$reasons.Add("only coarse health counters were readable (via $($Smart.Source)); per-attribute thresholds were not available"); $out.Cap = 'B' }
        default { [void]$reasons.Add('SMART data could not be read on this drive, so its health is unknown rather than good'); $out.Cap = 'B' }
    }

    if ($warnings.Count -gt 0) {
        # Each warning is a counter that does not un-move: reallocated sectors,
        # pending sectors, CRC errors on the cable.
        $score = [math]::Max(0.35, $score - (0.15 * $warnings.Count))
        foreach ($w in $warnings) { [void]$reasons.Add("SMART warning: $w") }
        $capBase = if ($out.Cap) { $out.Cap } else { 'A' }
        $out.Cap = Get-CappedLetter -Letter $capBase -Cap 'C'
    }

    if ($null -ne $Smart.Temperature) {
        $t = [int]$Smart.Temperature
        if ($t -ge 60) {
            $score = [math]::Max(0.30, $score - 0.20)
            [void]$reasons.Add("running hot at $t C")
        } elseif ($t -ge 50) {
            $score = [math]::Max(0.40, $score - 0.05)
            [void]$reasons.Add("warm at $t C")
        }
    }

    $out.Score01 = [double][math]::Max(0.0, [math]::Min(1.0, $score))
    $out.Reasons = @($reasons)
    $out
}

function Get-IntegrityScore {
    <#
        Integrity part from the pattern scan and the surface map.
        Returns @{Score01;Reasons;Cap}.

        This is the part that cannot be argued with. Either the bytes came back
        or they did not.
    #>
    [OutputType([hashtable])]
    param([AllowNull()][hashtable]$Integrity, [AllowNull()][hashtable]$Surface)

    $out = @{ Score01 = $null; Reasons = @(); Cap = $null }
    $reasons = [System.Collections.ArrayList]::new()

    if ($null -eq $Integrity -or [int]$Integrity.VerifiedMB -le 0) {
        if ($Integrity -and $Integrity.Reason) { [void]$reasons.Add("integrity check did not run: $($Integrity.Reason)") }
        else { [void]$reasons.Add('integrity was not verified') }
        $out.Reasons = @($reasons)
        return $out    # $null score - dropped from the average, not counted as zero
    }

    $errs = @($Integrity.Errors)
    if ($Integrity.CounterfeitSuspected) {
        [void]$reasons.Add('a block read back with a valid header for a DIFFERENT location: this drive wraps its address space and is not the capacity it claims')
        $out.Score01 = 0.0
        $out.Cap = 'F'
        $out.Reasons = @($reasons)
        return $out
    }
    if ($errs.Count -gt 0) {
        $kinds = @($errs | ForEach-Object { $_.Kind } | Sort-Object -Unique) -join ', '
        [void]$reasons.Add("$($errs.Count) verification error(s) [$kinds]: the drive did not return what was written to it")
        $out.Score01 = 0.0
        $out.Cap = 'F'
        $out.Reasons = @($reasons)
        return $out
    }

    [void]$reasons.Add("$([int]$Integrity.VerifiedMB) MB written and read back byte-for-byte with no mismatch")
    $score = 1.0

    if ($Surface -and @($Surface.Regions).Count -gt 0) {
        $regions = @($Surface.Regions)
        $bad = @($regions | Where-Object { $_.Status -eq 'error' })
        $weak = @($regions | Where-Object { $_.Status -eq 'weak' })
        $slow = @($regions | Where-Object { $_.Status -eq 'slow' })

        if ($bad.Count -gt 0) {
            $score = 0.0
            [void]$reasons.Add("$($bad.Count) of $($regions.Count) regions could not be read at all")
            $out.Cap = 'F'
        } elseif ($weak.Count -gt 0) {
            # A region reading at under a quarter of the drive's own median is
            # retrying internally. The bytes arrived, but the media is tired.
            $frac = $weak.Count / [double]$regions.Count
            $score = [math]::Max(0.35, 1.0 - (2.0 * $frac))
            [void]$reasons.Add("$($weak.Count) of $($regions.Count) regions read far slower than the rest of the drive, which is what internal retries look like")
            $out.Cap = 'C'
        } elseif ($slow.Count -gt 0) {
            $frac = $slow.Count / [double]$regions.Count
            $score = [math]::Max(0.60, 1.0 - $frac)
            [void]$reasons.Add("$($slow.Count) of $($regions.Count) regions read noticeably slower than the rest")
        } else {
            [void]$reasons.Add("all $($regions.Count) mapped regions read at an even rate")
        }
    }

    $out.Score01 = [double][math]::Max(0.0, [math]::Min(1.0, $score))
    $out.Reasons = @($reasons)
    $out
}

function Invoke-Grade {
    <#
        The verdict.

        $Results is the entry point's accumulated run state. The fields read
        here are:
            Smart           Get-SmartReport output
            Integrity       Invoke-IntegrityScan output
            Surface         Invoke-SurfaceScan output
            Performance     Get-PerformanceScore output
            Classification  Invoke-MediaClassification output
            ToolState       Get-ToolState output
            Errors          any fatal run errors the entry point recorded

        Returns @{Letter;Score01;WeightedParts;Overrides;Reasons;Warnings;
                  Failures;Caveats;ExitCode}
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Results)

    $verdict = @{
        Letter = 'F'; Score01 = 0.0; WeightedParts = @{}; Overrides = @()
        Reasons = @(); Warnings = @(); Failures = @(); Caveats = @(); ExitCode = 2
    }

    $health = Get-HealthScore -Smart $Results.Smart
    $integrity = Get-IntegrityScore -Integrity $Results.Integrity -Surface $Results.Surface
    $perf = $Results.Performance
    $perfScore = if ($perf) { $perf.Score01 } else { $null }

    $parts = @(
        @{ Name = 'Health'; Score01 = $health.Score01; Weight = $script:SbWeights.Health; Reasons = @($health.Reasons) }
        @{ Name = 'Integrity'; Score01 = $integrity.Score01; Weight = $script:SbWeights.Integrity; Reasons = @($integrity.Reasons) }
        @{ Name = 'Performance'; Score01 = $perfScore; Weight = $script:SbWeights.Performance; Reasons = @() }
    )

    if ($perf -and $null -ne $perf.Score01) {
        $parts[2].Reasons = @("scored $([math]::Round($perf.Score01 * 100))/100 against $($perf.Label) expectations")
    } elseif ($perf -and $perf.Note) {
        $parts[2].Reasons = @("performance not scored: $($perf.Note)")
    } else {
        $parts[2].Reasons = @('performance was not measured')
    }

    # Renormalise over the parts that actually produced a number, so a run with
    # --SkipIntegrity is graded on what it measured instead of being punished
    # for what it was told not to do.
    $scored = @($parts | Where-Object { $null -ne $_.Score01 })
    $caveats = [System.Collections.ArrayList]::new()
    foreach ($p in $parts) {
        if ($null -eq $p.Score01) { [void]$caveats.Add("$($p.Name) did not contribute to the grade because it was not measured") }
    }

    if ($scored.Count -eq 0) {
        $verdict.Letter = 'F'
        $verdict.Score01 = 0.0
        $verdict.Reasons = @('nothing could be measured on this drive')
        $verdict.Failures = @('no part of the test suite produced a result')
        $verdict.ExitCode = 3
        return $verdict
    }

    $wsum = ($scored | ForEach-Object { $_.Weight } | Measure-Object -Sum).Sum
    $raw = 0.0
    foreach ($p in $scored) { $raw += [double]$p.Score01 * ([double]$p.Weight / $wsum) }

    foreach ($p in $parts) {
        $verdict.WeightedParts[$p.Name] = @{
            Score01    = $p.Score01
            Weight     = [double]$p.Weight
            Normalised = if ($null -ne $p.Score01) { [double][math]::Round($p.Weight / $wsum, 4) } else { 0.0 }
            Reasons    = @($p.Reasons)
        }
    }

    $letter = Get-LetterForScore -Score01 $raw
    $overrides = [System.Collections.ArrayList]::new()

    # Caps, hardest first. Each one records why it fired, so the report can
    # explain a B on a drive that benchmarked like an A.
    foreach ($cap in @($health.Cap, $integrity.Cap)) {
        if (-not $cap) { continue }
        $before = $letter
        $letter = Get-CappedLetter -Letter $letter -Cap $cap
        if ($letter -ne $before) {
            [void]$overrides.Add("held to $letter (from $before) by the findings above")
        }
    }

    $failures = [System.Collections.ArrayList]::new()
    $warnings = [System.Collections.ArrayList]::new()

    if ($Results.Smart) {
        foreach ($f in @($Results.Smart.Failures)) { [void]$failures.Add($f) }
        foreach ($w in @($Results.Smart.Warnings)) { [void]$warnings.Add($w) }
    }
    if ($Results.Integrity -and $Results.Integrity.CounterfeitSuspected) {
        [void]$failures.Add('capacity does not match what the drive claims (address wrapping detected)')
    }
    if ($Results.Integrity -and @($Results.Integrity.Errors).Count -gt 0) {
        [void]$failures.Add("$(@($Results.Integrity.Errors).Count) integrity errors")
    }
    if ($Results.Surface -and [int]$Results.Surface.WeakCount -gt 0) {
        [void]$warnings.Add("$([int]$Results.Surface.WeakCount) slow or weak regions on the mapped area")
    }
    foreach ($e in @($Results.Errors)) { [void]$failures.Add([string]$e) }

    # Caveats: the honest limits of what this run could see.
    if ($Results.Smart -and [string]$Results.Smart.Status -ne 'Verified') {
        [void]$caveats.Add('SMART attributes were not fully readable, so the grade is capped at B however well the drive performed')
    }
    if ($Results.Integrity -and $null -ne $Results.Integrity.CoveragePct) {
        [void]$caveats.Add("integrity covered $($Results.Integrity.CoveragePct)% of the volume - only free space is ever written, so full coverage is not possible on a drive in use")
    }
    if ($Results.Classification -and $Results.Classification.Confidence -in @('low', 'none')) {
        [void]$caveats.Add("media type was inferred with $($Results.Classification.Confidence) confidence, so the performance expectations it selected may be the wrong yardstick")
    }
    if ($Results.ToolState) {
        foreach ($w in @($Results.ToolState.Warnings)) { [void]$caveats.Add([string]$w) }
    }

    $reasons = [System.Collections.ArrayList]::new()
    foreach ($p in $parts) {
        foreach ($r in @($p.Reasons)) { [void]$reasons.Add("$($p.Name): $r") }
    }

    $verdict.Letter = $letter
    $verdict.Score01 = [double][math]::Round($raw, 4)
    $verdict.Overrides = @($overrides)
    $verdict.Reasons = @($reasons)
    $verdict.Warnings = @($warnings)
    $verdict.Failures = @($failures)
    $verdict.Caveats = @($caveats)
    $verdict.ExitCode = switch ($letter) {
        'A' { 0 }
        'B' { 0 }
        'C' { 1 }
        'D' { 2 }
        default { 2 }
    }
    $verdict
}
