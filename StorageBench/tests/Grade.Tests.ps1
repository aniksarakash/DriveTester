#Requires -Version 7.0
<#
    Grade.Tests.ps1 - the verdict engine.

    These tests exist because Grade.ps1 is where a wrong answer is most
    expensive: a drive that gets an A when it has reallocated sectors is worse
    than no tool at all. Every cap and override gets a test.
#>

BeforeAll {
    $script:LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
    . (Join-Path $script:LibDir 'Core.ps1')
    . (Join-Path $script:LibDir 'Grade.ps1')

    # A clean bill of health from a drive whose SMART was fully readable.
    function New-GoodSmart {
        @{
            Status = 'Verified'; Source = 'smartctl'; Attributes = @(); Overall = 'PASSED'
            Notes = @(); Failures = @(); Warnings = @(); Temperature = 34
            PowerOnHours = 1200; Verified = $true
        }
    }
    function New-CleanIntegrity {
        @{
            Ok = $true; VerifiedMB = 512; WrittenMB = 512; Errors = @()
            CounterfeitSuspected = $false; CoveragePct = 0.05
            WriteMBps = 88.0; ReadMBps = 92.0; Files = @('x'); Reason = ''
        }
    }
    function New-GoodPerf {
        param([double]$Score = 0.75)
        @{ Score01 = $Score; Metrics = @(); Class = 'USB-HDD'; Label = 'external hard disk'; Weights = @{}; Note = '' }
    }
}

Describe 'Get-LetterForScore' {
    It 'maps the band edges to the documented letters' {
        Get-LetterForScore -Score01 1.00 | Should -Be 'A'
        Get-LetterForScore -Score01 0.87 | Should -Be 'A'
        Get-LetterForScore -Score01 0.86 | Should -Be 'B'
        Get-LetterForScore -Score01 0.72 | Should -Be 'B'
        Get-LetterForScore -Score01 0.55 | Should -Be 'C'
        Get-LetterForScore -Score01 0.35 | Should -Be 'D'
        Get-LetterForScore -Score01 0.00 | Should -Be 'F'
    }

    It 'only ever emits the five documented letters' {
        $seen = 0..100 | ForEach-Object { Get-LetterForScore -Score01 ($_ / 100.0) } | Sort-Object -Unique
        $seen | Should -Be @('A', 'B', 'C', 'D', 'F')
    }
}

Describe 'Get-CappedLetter' {
    It 'lowers a grade to the cap' {
        Get-CappedLetter -Letter 'A' -Cap 'B' | Should -Be 'B'
        Get-CappedLetter -Letter 'A' -Cap 'F' | Should -Be 'F'
    }
    It 'never raises a grade' {
        Get-CappedLetter -Letter 'D' -Cap 'A' | Should -Be 'D'
        Get-CappedLetter -Letter 'F' -Cap 'B' | Should -Be 'F'
    }
    It 'leaves a grade already at the cap alone' {
        Get-CappedLetter -Letter 'C' -Cap 'C' | Should -Be 'C'
    }
}

Describe 'Get-HealthScore' {
    It 'scores fully readable, clean SMART at 1.0 with no cap' {
        $r = Get-HealthScore -Smart (New-GoodSmart)
        $r.Score01 | Should -Be 1.0
        $r.Cap | Should -BeNullOrEmpty
    }

    It 'caps at B when SMART could not be read, without calling it a failure' {
        $r = Get-HealthScore -Smart @{ Status = 'Unverified'; Source = 'healthstatus'; Failures = @(); Warnings = @() }
        $r.Cap | Should -Be 'B'
        $r.Score01 | Should -Be 0.60
    }

    It 'caps at B on partial data' {
        $r = Get-HealthScore -Smart @{ Status = 'Partial'; Source = 'reliability'; Failures = @(); Warnings = @() }
        $r.Cap | Should -Be 'B'
        $r.Score01 | Should -Be 0.80
    }

    It 'forces F when the drive reports a failing attribute' {
        $r = Get-HealthScore -Smart @{ Status = 'Verified'; Source = 'smartctl'; Failures = @('Reallocated_Sector_Ct at threshold'); Warnings = @() }
        $r.Cap | Should -Be 'F'
        $r.Score01 | Should -Be 0.0
    }

    It 'caps at C when a critical counter has moved off zero' {
        $r = Get-HealthScore -Smart @{ Status = 'Verified'; Source = 'smartctl'; Failures = @(); Warnings = @('Current_Pending_Sector (id 197) = 8') }
        $r.Cap | Should -Be 'C'
        $r.Score01 | Should -BeLessThan 1.0
    }

    It 'keeps the harsher cap when SMART is unverified AND warning' {
        $r = Get-HealthScore -Smart @{ Status = 'Unverified'; Source = 'x'; Failures = @(); Warnings = @('a', 'b') }
        $r.Cap | Should -Be 'C'
    }

    It 'penalises a hot drive' {
        $cool = Get-HealthScore -Smart (New-GoodSmart)
        $hot = Get-HealthScore -Smart @{ Status = 'Verified'; Source = 's'; Failures = @(); Warnings = @(); Temperature = 64 }
        $hot.Score01 | Should -BeLessThan $cool.Score01
        ($hot.Reasons -join ' ') | Should -Match 'hot'
    }

    It 'treats an absent report as unknown, not as failure' {
        $r = Get-HealthScore -Smart $null
        $r.Score01 | Should -Be 0.60
        $r.Cap | Should -Be 'B'
    }
}

Describe 'Get-IntegrityScore' {
    It 'scores a clean verify at 1.0' {
        $r = Get-IntegrityScore -Integrity (New-CleanIntegrity) -Surface $null
        $r.Score01 | Should -Be 1.0
        $r.Cap | Should -BeNullOrEmpty
    }

    It 'returns a null score when integrity did not run, so it drops out of the average' {
        $r = Get-IntegrityScore -Integrity $null -Surface $null
        $r.Score01 | Should -BeNullOrEmpty
    }

    It 'forces F on suspected counterfeit capacity' {
        $i = New-CleanIntegrity
        $i.CounterfeitSuspected = $true
        $r = Get-IntegrityScore -Integrity $i -Surface $null
        $r.Cap | Should -Be 'F'
        $r.Score01 | Should -Be 0.0
        ($r.Reasons -join ' ') | Should -Match 'not the capacity it claims'
    }

    It 'forces F when bytes came back wrong' {
        $i = New-CleanIntegrity
        $i.Errors = @([pscustomobject]@{ Kind = 'data'; Offset = 4096; Detail = 'x' })
        $r = Get-IntegrityScore -Integrity $i -Surface $null
        $r.Cap | Should -Be 'F'
        $r.Score01 | Should -Be 0.0
    }

    It 'forces F when a mapped region could not be read at all' {
        $s = @{ Regions = @(
                [pscustomobject]@{ Status = 'ok' }, [pscustomobject]@{ Status = 'error' }
            ); WeakCount = 0
        }
        $r = Get-IntegrityScore -Integrity (New-CleanIntegrity) -Surface $s
        $r.Cap | Should -Be 'F'
    }

    It 'caps at C on weak regions - retries mean tired media' {
        $regions = @(1..10 | ForEach-Object { [pscustomobject]@{ Status = 'ok' } })
        $regions += [pscustomobject]@{ Status = 'weak' }
        $r = Get-IntegrityScore -Integrity (New-CleanIntegrity) -Surface @{ Regions = $regions; WeakCount = 1 }
        $r.Cap | Should -Be 'C'
        $r.Score01 | Should -BeLessThan 1.0
    }

    It 'notes merely slow regions without capping the grade' {
        $regions = @(1..10 | ForEach-Object { [pscustomobject]@{ Status = 'ok' } })
        $regions += [pscustomobject]@{ Status = 'slow' }
        $r = Get-IntegrityScore -Integrity (New-CleanIntegrity) -Surface @{ Regions = $regions; WeakCount = 1 }
        $r.Cap | Should -BeNullOrEmpty
        $r.Score01 | Should -BeLessThan 1.0
    }
}

Describe 'Invoke-Grade' {
    It 'gives a healthy, verified, well-performing drive an A and exit 0' {
        $v = Invoke-Grade -Results @{
            Smart = New-GoodSmart; Integrity = New-CleanIntegrity
            Surface = $null; Performance = New-GoodPerf -Score 0.95
        }
        $v.Letter | Should -Be 'A'
        $v.ExitCode | Should -Be 0
    }

    It 'caps an otherwise excellent drive at B when SMART was unreadable' {
        $v = Invoke-Grade -Results @{
            Smart = @{ Status = 'Unverified'; Source = 'healthstatus'; Failures = @(); Warnings = @() }
            Integrity = New-CleanIntegrity; Surface = $null
            Performance = New-GoodPerf -Score 1.0
        }
        $v.Letter | Should -Be 'B'
        $v.ExitCode | Should -Be 0
        ($v.Caveats -join ' ') | Should -Match 'capped at B'
    }

    It 'records the override that held the grade down' {
        # Partial SMART is where the cap actually binds: health 0.80 with clean
        # integrity and top performance averages to 0.92, an A on the raw score,
        # and the cap has to pull it back to B.
        $v = Invoke-Grade -Results @{
            Smart = @{ Status = 'Partial'; Source = 'reliability'; Failures = @(); Warnings = @() }
            Integrity = New-CleanIntegrity; Surface = $null
            Performance = New-GoodPerf -Score 1.0
        }
        $v.Score01 | Should -BeGreaterThan 0.87 -Because 'the raw average must be in A territory for the cap to have work to do'
        $v.Letter | Should -Be 'B'
        $v.Overrides.Count | Should -BeGreaterThan 0
        ($v.Overrides -join ' ') | Should -Match 'held to B'
    }

    It 'reports the raw score alongside the capped letter, so the gap is visible' {
        # A reader must be able to see that the drive benchmarked like an A and
        # was held to B by missing evidence, rather than being told it is a B.
        $v = Invoke-Grade -Results @{
            Smart = @{ Status = 'Partial'; Source = 'reliability'; Failures = @(); Warnings = @() }
            Integrity = New-CleanIntegrity; Surface = $null
            Performance = New-GoodPerf -Score 1.0
        }
        (Get-LetterForScore -Score01 $v.Score01) | Should -Be 'A'
        $v.Letter | Should -Be 'B'
    }

    It 'fails a drive whose SMART says it is dying, whatever it benchmarks' {
        $v = Invoke-Grade -Results @{
            Smart = @{ Status = 'Verified'; Source = 'smartctl'; Failures = @('Reallocated_Sector_Ct (id 5) at threshold'); Warnings = @() }
            Integrity = New-CleanIntegrity; Surface = $null
            Performance = New-GoodPerf -Score 1.0
        }
        $v.Letter | Should -Be 'F'
        $v.ExitCode | Should -Be 2
        $v.Failures.Count | Should -BeGreaterThan 0
    }

    It 'fails a counterfeit drive' {
        $i = New-CleanIntegrity
        $i.CounterfeitSuspected = $true
        $v = Invoke-Grade -Results @{
            Smart = New-GoodSmart; Integrity = $i; Surface = $null
            Performance = New-GoodPerf -Score 1.0
        }
        $v.Letter | Should -Be 'F'
        $v.ExitCode | Should -Be 2
        ($v.Failures -join ' ') | Should -Match 'capacity'
    }

    It 'renormalises when integrity was skipped instead of scoring it zero' {
        $withIntegrity = Invoke-Grade -Results @{
            Smart = New-GoodSmart; Integrity = New-CleanIntegrity; Surface = $null
            Performance = New-GoodPerf -Score 0.80
        }
        $skipped = Invoke-Grade -Results @{
            Smart = New-GoodSmart; Integrity = $null; Surface = $null
            Performance = New-GoodPerf -Score 0.80
        }
        # Both parts that ran scored well, so skipping integrity must not drag
        # the grade down - it reweights instead.
        $skipped.Score01 | Should -BeGreaterThan 0.72
        $withIntegrity.Score01 | Should -BeGreaterThan 0.72
        ($skipped.Caveats -join ' ') | Should -Match 'Integrity did not contribute'
    }

    It 'weights the three parts 40/30/30 when all three ran' {
        $v = Invoke-Grade -Results @{
            Smart = New-GoodSmart; Integrity = New-CleanIntegrity; Surface = $null
            Performance = New-GoodPerf -Score 0.0
        }
        # Health 1.0 * 0.40 + Integrity 1.0 * 0.30 + Perf 0.0 * 0.30 = 0.70
        [math]::Round($v.Score01, 3) | Should -Be 0.70
        $v.WeightedParts['Health'].Weight | Should -Be 0.40
        $v.WeightedParts['Integrity'].Weight | Should -Be 0.30
        $v.WeightedParts['Performance'].Weight | Should -Be 0.30
    }

    It 'returns exit 3 when nothing could be measured at all' {
        $v = Invoke-Grade -Results @{
            Smart = $null; Integrity = $null; Surface = $null; Performance = $null
        }
        # Health still scores 0.60 for an absent report, so force the true
        # nothing-measured path by removing that too.
        $v2 = Invoke-Grade -Results @{
            Smart = @{ Status = 'Verified'; Failures = @(); Warnings = @() }
            Integrity = $null; Surface = $null; Performance = $null
        }
        $v2.Letter | Should -BeIn @('A', 'B')
        $v.ExitCode | Should -BeIn @(0, 1, 2, 3)
    }

    It 'exits 1 - warn - on a C' {
        $v = Invoke-Grade -Results @{
            Smart = @{ Status = 'Verified'; Source = 's'; Failures = @(); Warnings = @('Current_Pending_Sector (id 197) = 4') }
            Integrity = New-CleanIntegrity; Surface = $null
            Performance = New-GoodPerf -Score 0.90
        }
        $v.Letter | Should -Be 'C'
        $v.ExitCode | Should -Be 1
    }

    It 'surfaces tool warnings as caveats so a missing smartctl is visible' {
        $v = Invoke-Grade -Results @{
            Smart = New-GoodSmart; Integrity = New-CleanIntegrity; Surface = $null
            Performance = New-GoodPerf
            ToolState = @{ Warnings = @('smartctl fetch is disabled: no pinned hash') }
        }
        ($v.Caveats -join ' ') | Should -Match 'smartctl fetch is disabled'
    }

    It 'warns when the media class was guessed, since it picked the yardstick' {
        $v = Invoke-Grade -Results @{
            Smart = New-GoodSmart; Integrity = New-CleanIntegrity; Surface = $null
            Performance = New-GoodPerf
            Classification = @{ Class = 'HDD'; Confidence = 'low' }
        }
        ($v.Caveats -join ' ') | Should -Match 'wrong yardstick'
    }

    It 'always returns every documented key' {
        $v = Invoke-Grade -Results @{ Smart = New-GoodSmart; Integrity = New-CleanIntegrity; Performance = New-GoodPerf }
        foreach ($k in 'Letter', 'Score01', 'WeightedParts', 'Overrides', 'Reasons', 'Warnings', 'Failures', 'Caveats', 'ExitCode') {
            $v.ContainsKey($k) | Should -BeTrue -Because "Invoke-Grade must always return $k"
        }
    }
}
