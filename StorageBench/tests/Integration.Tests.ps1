#Requires -Version 7.0
<#
    Integration.Tests.ps1 - the whole thing, end to end.

    Every other test file proves one module in isolation. This one proves the
    seams: that the plan the entry point computes is the plan the phases can
    actually execute, that a real write/read/verify cycle over a real
    filesystem produces records the grader accepts, and that the reporters can
    serialise what comes out the other end.

    It runs against a temp directory rather than a removable volume.
    Set-ScratchOverride is the seam the safety layer already exposes for this,
    and it redirects the scratch root without weakening a single containment
    check - the phases below open real handles, write real bytes, and read them
    back. Sizes are deliberately tiny: this is about whether the pipeline holds
    together, not about how fast the host disk is.

    The last block runs StorageBench.ps1 as a process, because two of its
    promises are only true of a process: -DryRun writes nothing and exits 0,
    and the system volume is refused rather than benchmarked.
#>

BeforeAll {
    $script:sbRoot = Split-Path -Parent $PSScriptRoot
    $script:sbScript = Join-Path $script:sbRoot 'StorageBench.ps1'

    # Dot-sourcing the entry point defines its functions and loads every module
    # in lib/ in dependency order. It deliberately does not run.
    . $script:sbScript

    $script:tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('sb-int-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:tempRoot -Force | Out-Null

    $script:reportDir = Join-Path $script:tempRoot 'reports'
    $script:historyDir = Join-Path $script:tempRoot 'history'
    Set-ScratchOverride -Path $script:tempRoot
    Set-HistoryDirOverride -Path $script:historyDir

    # The host volume, used only for the coverage arithmetic the scan reports.
    $script:hostDrive = ([string](Split-Path -Qualifier $script:tempRoot)).TrimEnd(':')[0]
}

AfterAll {
    Set-ScratchOverride -Path $null
    Set-HistoryDirOverride -Path $null
    if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
        Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The preset plan' {
    It 'turns every preset into byte counts a run could actually write' {
        foreach ($name in 'Quick', 'Standard', 'Thorough', 'Certify') {
            $plan = Get-PresetPlan -Preset $name -VolumeBytes 500GB -FreeBytes 400GB
            $plan.Name | Should -Be $name
            $plan.NeedBytes | Should -BeGreaterThan 0
            $plan.ReserveBytes | Should -BeGreaterThan 0
            $plan.Estimate | Should -Not -BeNullOrEmpty
        }
    }

    It 'sizes Certify at the free space it is allowed to use, and no more' {
        $plan = Get-PresetPlan -Preset 'Certify' -VolumeBytes 200GB -FreeBytes 100GB
        $plan.IntegrityMode | Should -Be 'Full'
        ([long]$plan.IntegrityMB * 1MB) | Should -BeGreaterThan 0
        $plan.NeedBytes | Should -BeLessOrEqual (100GB - $plan.ReserveBytes)
        ($plan.Notes -join ' ') | Should -Match 'certify sized'
    }

    It 'trims the integrity pass rather than eating into the reserve' {
        $plan = Get-PresetPlan -Preset 'Thorough' -VolumeBytes 64GB -FreeBytes 12GB
        $plan.NeedBytes | Should -BeLessOrEqual (12GB - $plan.ReserveBytes)
        ($plan.Notes -join ' ') | Should -Match 'trimmed'
    }

    It 'drops the integrity pass when there is no room for a meaningful one' {
        $plan = Get-PresetPlan -Preset 'Standard' -VolumeBytes 64GB -FreeBytes 2GB
        $plan.DoIntegrity | Should -BeFalse
        $plan.IntegrityMB | Should -Be 0
        ($plan.Notes -join ' ') | Should -Match 'not enough free space'
    }

    It 'lets an explicit -IntegritySizeGB overrule the preset, Certify included' {
        $plan = Get-PresetPlan -Preset 'Certify' -VolumeBytes 500GB -FreeBytes 400GB -IntegritySizeGB 4
        $plan.IntegrityMB | Should -Be 4096
        $plan.IntegrityMode | Should -Be 'Spread'
    }

    It 'zeroes the phases the skip switches turn off' {
        $plan = Get-PresetPlan -Preset 'Thorough' -VolumeBytes 500GB -FreeBytes 400GB `
            -SkipBench -SkipIntegrity -SkipSmart
        $plan.DoBench | Should -BeFalse
        $plan.DoIntegrity | Should -BeFalse
        $plan.DoSmart | Should -BeFalse
        $plan.BenchBytes | Should -Be 0
        $plan.SustainedBytes | Should -Be 0
        $plan.Zones | Should -Be 0
    }
}

Describe 'The method, retuned for what the drive turned out to be' {
    BeforeEach {
        $script:base = Get-PresetPlan -Preset 'Thorough' -VolumeBytes 500GB -FreeBytes 400GB
    }

    It 'stops asking a platter for a deep queue' {
        $p = Update-PlanForClass -Plan $script:base -MeasuredClass 'HDD' -BusType 'USB'
        $p.Method | Should -Be 'HDD'
        $p.QueueDepth | Should -Be 4
        $p.QdNSamples | Should -BeLessOrEqual 256
        ($p.Notes -join ' ') | Should -Match 'one head'
    }

    It 'caps a platter''s sustained write, having no cache to exhaust' {
        $p = Update-PlanForClass -Plan $script:base -MeasuredClass 'HDD' -BusType 'SATA'
        $p.SustainedBytes | Should -BeLessOrEqual 2GB
        $p.Zones | Should -BeGreaterOrEqual 8
    }

    It 'fills the queue for PCIe flash instead of emptying it' {
        $p = Update-PlanForClass -Plan $script:base -MeasuredClass 'NVMe' -BusType 'NVMe'
        $p.Method | Should -Be 'NVMe'
        $p.QueueDepth | Should -BeGreaterOrEqual 32
        $p.QdNSamples | Should -BeGreaterOrEqual 1024
    }

    It 'spends fewer regions on a surface that has no tracks' {
        $p = Update-PlanForClass -Plan $script:base -MeasuredClass 'NVMe' -BusType 'NVMe'
        $p.SurfaceRegions | Should -BeLessOrEqual 32
        $p.DoSurface | Should -BeTrue
        ($p.Notes -join ' ') | Should -Match 'remap check'
    }

    It 'keeps a USB SSD at a queue its bridge can actually carry' {
        $p = Update-PlanForClass -Plan (Get-PresetPlan -Preset 'Standard' -VolumeBytes 500GB -FreeBytes 400GB) `
            -MeasuredClass 'SSD' -BusType 'USB'
        $p.Method | Should -Be 'SSD'
        $p.QueueDepth | Should -Be 16
    }

    It 'runs the preset as written when the medium is unknown' {
        $p = Update-PlanForClass -Plan $script:base -MeasuredClass 'Unknown' -BusType 'USB'
        $p.Method | Should -Be 'generic'
        $p.QueueDepth | Should -Be 32
        $p.QdNSamples | Should -Be 1024
        ($p.Notes -join ' ') | Should -Match 'could not be identified'
    }

    It 'never asks for more bytes than the preset already cleared with the reserve' {
        foreach ($cls in 'HDD', 'SSD', 'NVMe', 'Unknown') {
            $plan = Get-PresetPlan -Preset 'Thorough' -VolumeBytes 500GB -FreeBytes 400GB
            $was = $plan.NeedBytes
            $p = Update-PlanForClass -Plan $plan -MeasuredClass $cls -BusType 'SATA'
            ([long]$p.ClassifyBytes + [long]$p.BenchBytes + [long]$p.SustainedBytes + ([long]$p.IntegrityMB * 1MB)) |
                Should -BeLessOrEqual $was
        }
    }
}

Describe 'The process exit code' {
    It 'passes the grade''s own code through' {
        Get-RunExitCode -Grade @{ ExitCode = 0 } | Should -Be 0
        Get-RunExitCode -Grade @{ ExitCode = 1 } | Should -Be 1
        Get-RunExitCode -Grade @{ ExitCode = 2 } | Should -Be 2
    }

    It 'reserves 3 for an abort, a crash, or a verdict that never arrived' {
        Get-RunExitCode -Grade @{ ExitCode = 0 } -Aborted | Should -Be 3
        Get-RunExitCode -Grade @{ ExitCode = 0 } -Fatal | Should -Be 3
        Get-RunExitCode -Grade $null | Should -Be 3
    }
}

Describe 'A full pipeline over a scratch directory' {
    BeforeAll {
        $script:session = Initialize-Scratch -Drive $script:hostDrive
        $script:volume = @{ SizeBytes = 64GB; FreeBytes = 32GB; Letter = $script:hostDrive }

        $script:classification = Invoke-MediaClassification -Drive $script:hostDrive -Session $script:session `
            -FileBytes 16MB -Samples 48

        $script:bench = @{ SeqRead = $null; SeqWrite = $null; RndQd1 = $null; RndQdN = $null; Sustained = $null; Zones = $null }
        $mk = New-BenchFile -Session $script:session -Name 'bench.bin' -Bytes 32MB
        $script:benchFile = $mk.Path
        $script:bench.SeqWrite = Measure-Sequential -File $script:benchFile -OpMode 'Write' -BytesPerRun 32MB -Block 1MB
        $script:bench.SeqRead = Measure-Sequential -File $script:benchFile -OpMode 'Read' -BytesPerRun 32MB -Block 1MB
        $script:bench.RndQd1 = Measure-RandomQd1 -File $script:benchFile -Samples 64 -Block 4096
        $script:bench.RndQdN = Measure-RandomQdN -File $script:benchFile -QueueDepth 8 -Samples 64 -Block 4096
        $script:bench.Zones = Measure-ZoneProfile -File $script:benchFile -Block 1MB -Zones 4 -BlocksPerZone 4

        $script:integrity = Invoke-IntegrityScan -Volume $script:volume -Session $script:session `
            -SizeMB 16 -Mode 'Spread' -ChunkMB 4
        $script:surface = Invoke-SurfaceScan -Volume $script:volume -Session $script:session `
            -Regions 8 -ExistingFile $script:benchFile

        $script:class = Get-DriveClass -Classification $script:classification -BusType 'NVMe' `
            -SeqReadMBps $script:bench.SeqRead.MBps
        $script:perf = Get-PerformanceScore -BenchResults $script:bench -Class $script:class
        $script:grade = Invoke-Grade -Results @{
            Smart          = $null
            Integrity      = $script:integrity
            Surface        = $script:surface
            Performance    = $script:perf
            Classification = $script:classification
            ToolState      = @{ Warnings = @() }
            Errors         = @()
        }
    }

    It 'classified the media from measured latency alone' {
        $script:classification.Ok | Should -BeTrue
        $script:classification.Class | Should -Not -BeNullOrEmpty
        $script:classification.Latency.AvgMs | Should -BeGreaterThan 0
    }

    It 'measured a throughput for every sequential direction' {
        $script:bench.SeqWrite.MBps | Should -BeGreaterThan 0
        $script:bench.SeqRead.MBps | Should -BeGreaterThan 0
    }

    It 'measured random IO at both queue depths' {
        $script:bench.RndQd1.IOPS | Should -BeGreaterThan 0
        $script:bench.RndQdN.IOPS | Should -BeGreaterThan 0
    }

    It 'profiled every zone it was asked for' {
        @($script:bench.Zones.ZoneMBps).Count | Should -Be 4
    }

    It 'wrote and verified the pattern with no mismatches' {
        $script:integrity.Ok | Should -BeTrue
        $script:integrity.VerifiedMB | Should -BeGreaterThan 0
        @($script:integrity.Errors).Count | Should -Be 0
        $script:integrity.CounterfeitSuspected | Should -BeFalse
    }

    It 'read every surface region without an unreadable one' {
        @($script:surface.Regions).Count | Should -Be 8
        @($script:surface.Errors).Count | Should -Be 0
    }

    It 'resolved a drive class the expectations table knows' {
        $script:class | Should -BeIn @('NVMe-Gen3', 'NVMe-Gen4', 'NVMe-Gen5', 'SATA-SSD', 'USB-SSD', 'HDD-7200', 'HDD-5400', 'USB-HDD')
        (Get-ExpectedRange -Class $script:class) | Should -Not -BeNullOrEmpty
        $script:perf.Score01 | Should -BeGreaterOrEqual 0
        $script:perf.Score01 | Should -BeLessOrEqual 1
    }

    It 'produced a letter and an exit code from the parts' {
        $script:grade.Letter | Should -BeIn @('A', 'B', 'C', 'D', 'F')
        $script:grade.ExitCode | Should -BeIn @(0, 1, 2)
    }

    It 'caps the letter because health could not be read' {
        # No SMART source in this environment, so the run cannot certify health
        # and must say so rather than award a top mark on performance alone.
        $script:grade.Letter | Should -Not -Be 'A'
        (@($script:grade.Caveats) -join ' ') | Should -Not -BeNullOrEmpty
    }

    It 'writes a JSON report that survives a round-trip' {
        $record = [ordered]@{
            Meta             = [ordered]@{
                Tool = 'StorageBench'; Version = $script:SbVersion; RunId = $script:session.RunId
                StartedAt = (Get-Date).ToString('o'); FinishedAt = (Get-Date).ToString('o')
                Preset = 'Quick'; Drive = ([string]$script:hostDrive)
            }
            Disk             = @{ Model = 'integration host'; SerialNumber = 'SB-INT-0001'; BusType = 'NVMe' }
            Volume           = $script:volume
            Classification   = $script:classification
            Performance      = $script:bench
            PerformanceScore = $script:perf
            Integrity        = $script:integrity
            Surface          = $script:surface
            Grade            = $script:grade
            Errors           = @()
        }

        $jsonPath = Export-RunJson -Results $record -OutDir $script:reportDir
        Test-Path -LiteralPath $jsonPath | Should -BeTrue

        $back = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        $back.Meta.RunId | Should -Be $script:session.RunId
        $back.Grade.Letter | Should -Be $script:grade.Letter
        @($back.Surface.Regions).Count | Should -Be 8

        $htmlPath = Export-RunHtml -Results $record -OutDir $script:reportDir
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $html | Should -Match '<html'
        $html | Should -Match $script:grade.Letter
        # Self-contained: a report about someone's hardware fetches nothing.
        $html | Should -Not -Match 'src="http'
        $html | Should -Not -Match 'href="http'

        Update-History -Serial 'SB-INT-0001' -Line ([ordered]@{
                RunId = $script:session.RunId; Preset = 'Quick'; Drive = ([string]$script:hostDrive)
                Grade = $script:grade.Letter; Score01 = $script:grade.Score01; Class = $script:class
            })
        @(Get-ChildItem -LiteralPath $script:historyDir -File).Count | Should -BeGreaterThan 0
    }

    It 'removes every byte it wrote' {
        $root = $script:session.Root
        Test-Path -LiteralPath $root | Should -BeTrue

        $cleaned = Clear-Scratch -Session $script:session
        $cleaned.Failed | Should -Be 0
        Test-Path -LiteralPath $root | Should -BeFalse
    }
}

Describe 'StorageBench.ps1 as a process' {
    BeforeAll {
        $script:sysDrive = ([string]$env:SystemDrive).TrimEnd(':')[0]
    }

    It 'plans a run without writing a byte, and exits 0' {
        $scratchRoot = Join-Path ("{0}:\" -f $script:sysDrive) '.storagebench-scratch'
        $before = if (Test-Path -LiteralPath $scratchRoot) {
            @(Get-ChildItem -LiteralPath $scratchRoot -Force).Count
        } else { -1 }

        $out = & pwsh -NoProfile -File $script:sbScript -Drive $script:sysDrive -Preset 'Quick' -DryRun -Plain 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match 'No bytes were written'

        $after = if (Test-Path -LiteralPath $scratchRoot) {
            @(Get-ChildItem -LiteralPath $scratchRoot -Force).Count
        } else { -1 }
        $after | Should -Be $before
    }

    It 'refuses the system volume rather than benchmarking it' {
        $out = & pwsh -NoProfile -File $script:sbScript -Drive $script:sysDrive -Preset 'Quick' -Yes -Plain 2>&1
        $LASTEXITCODE | Should -Be 2
        ($out -join "`n") | Should -Match 'Refusing to write'
    }

    It 'reports a drive that is not there instead of throwing' {
        $free = 'ZYXWVUTSRQPONMLKJIHGFE'.ToCharArray() |
            Where-Object { -not (Test-Path -LiteralPath ("{0}:\" -f $_)) } |
            Select-Object -First 1
        if (-not $free) { Set-ItResult -Skipped -Because 'every drive letter is in use'; return }

        $out = & pwsh -NoProfile -File $script:sbScript -Drive $free -Preset 'Quick' -DryRun -Plain 2>&1
        $LASTEXITCODE | Should -Be 2
        ($out -join "`n") | Should -Match 'Cannot test'
    }
}
