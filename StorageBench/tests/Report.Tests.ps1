#Requires -Version 7.0
<#
    Report.Tests.ps1 - the artefacts a run leaves behind.

    Two properties matter more than layout. The JSON has to survive a
    round-trip with its nested series intact, because it is the machine-readable
    record and history is built from it. The HTML has to be genuinely
    self-contained: a report that fetches a stylesheet or a font is a report
    that renders wrong on the offline machine where drives actually get tested,
    and one that phones home from a document about someone's hardware.

    Both exporters are also asserted against a nearly empty results object. A
    run that aborted in its first phase still deserves a report saying so.
#>

BeforeAll {
    $lib = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
    . (Join-Path $lib 'Core.ps1')
    . (Join-Path $lib 'Report.ps1')

    $script:outDir = Join-Path ([IO.Path]::GetTempPath()) ("sb-report-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $script:histDir = Join-Path $script:outDir 'history'
    New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
    Set-HistoryDirOverride -Path $script:histDir

    $script:sample = @{
        Meta               = @{
            Tool = 'StorageBench'; Version = '1.0.0'
            RunId = '20260830-011500-a1b2c3'
            StartedAt = '2026-08-30T01:15:00Z'; FinishedAt = '2026-08-30T01:16:30Z'
            Preset = 'Quick'; Drive = 'D'
            Machine = 'DESKTOP-TEST'; PSVersion = '7.6.4'; Elevated = $false
        }
        Disk               = @{
            Number = 1; Model = 'Seagate BUP Slim BK'; SerialNumber = 'NAA1B2C3'
            FirmwareRevision = '0304'; BusType = 'USB'; MediaType = 'Unspecified'
            SizeBytes = 2000363192320; PartitionStyle = 'GPT'
        }
        Volume             = @{
            Drive = 'D'; Label = 'Backup'; FileSystem = 'NTFS'
            SizeBytes = 2000363192320; FreeBytes = 1200000000000; ClusterBytes = 4096
        }
        Classification     = @{
            # A word, not a decimal - this is what Classify-Latency actually
            # returns, and a numeric fixture here once hid a crash in the HTML.
            Class = 'HDD'; RPM = 5400; Confidence = 'high'
            Evidence = @('avg random read 8.437 ms', 'p99 15.877 ms')
            Latency = @{ AvgMs = 8.437; P50 = 7.9; P95 = 14.2; P99 = 15.877; MaxMs = 41.2; SeekSlopeMsPerGB = 0.0031 }
        }
        ReportedVsMeasured = @{
            ReportedMediaType = 'Unspecified'; MeasuredClass = 'HDD'; Agrees = $false
            Note = 'the bus reports no media type through the USB bridge'
        }
        Smart              = @{
            Status = 'Unavailable'; Source = 'none'; Overall = 'Unknown'; Attributes = @()
            Notes = @('smartctl not installed', 'WMI predict-failure requires elevation')
        }
        Performance        = @{
            SeqRead   = @{ MBps = 93.4; Seconds = 11.2; Bytes = 1073741824; PeakMBps = 101.2 }
            SeqWrite  = @{ MBps = 88.1; Seconds = 12.1; Bytes = 1073741824; PeakMBps = 95.0 }
            RndQd1    = @{ IOPS = 117.3; AvgMs = 8.52; P50 = 7.9; P95 = 14.4; P99 = 16.1; MaxMs = 42.0 }
            RndQdN    = @{ IOPS = 141.9; AvgMs = 28.1; P95 = 61.0; P99 = 88.4; MaxMs = 140.2; QueueDepth = 16 }
            Sustained = @{ SeriesMBps = @(88.4, 91.0, 90.2, 52.1, 89.7, 90.1); CliffDetected = $true; CliffAtMB = 768; FinalMBps = 90.1 }
            Zones     = @{ ZonePcts = @(0, 25, 50, 75, 100); ZoneMBps = @(101.1, 97.4, 88.0, 74.2, 61.3) }
        }
        PerformanceScore   = @{
            Score01 = 0.91; Class = 'USB-HDD'
            Metrics = @{ SeqRead = @{ Value = 93.4; Score01 = 0.95; Band = @{ Floor = 30; Target = 110 } } }
        }
        Integrity          = @{ VerifiedMB = 1024; Errors = @(); CounterfeitSuspected = $false; CoveragePct = 0.05; Mode = 'write-verify' }
        Surface            = @{
            Mode = 'read'; Errors = @()
            Regions = @(1..64 | ForEach-Object {
                    [pscustomobject]@{ Index = $_ - 1; Status = @('ok', 'ok', 'fair', 'slow', 'weak')[$_ % 5]; MBps = 90.0 - $_ }
                })
        }
        Grade              = @{
            Letter = 'B'; Score01 = 0.842; ExitCode = 1
            WeightedParts = @{
                Health      = @{ Score01 = 0.60; Weight = 40; Normalised = 0.24; Reasons = @('SMART unavailable') }
                Integrity   = @{ Score01 = 1.00; Weight = 30; Normalised = 0.30; Reasons = @() }
                Performance = @{ Score01 = 0.91; Weight = 30; Normalised = 0.273; Reasons = @() }
            }
            Overrides = @(); Reasons = @('Performance scored against class USB-HDD')
            Warnings = @('CRC error count is 3'); Failures = @()
            Caveats = @('SMART could not be read without elevation')
        }
        ToolState          = @{
            Smartctl = @{ Path = $null; Source = 'missing'; Version = $null; Ok = $false; Url = 'https://example.invalid/smartctl.zip'; Pin = 'abc123'; Hash = $null }
            DiskSpd  = @{ Path = $null; Source = 'missing'; Version = $null; Ok = $false; Url = $null; Pin = $null; Hash = $null }
            Warnings = @('smartctl not found on PATH')
        }
        Errors             = @()
    }
}

AfterAll {
    Set-HistoryDirOverride -Path $null
    if ($script:outDir -and (Test-Path $script:outDir)) {
        Remove-Item -LiteralPath $script:outDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Export-RunJson' {
    It 'writes a file and returns its path' {
        $p = Export-RunJson -Results $script:sample -OutDir $script:outDir
        $p | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $p | Should -BeTrue
    }

    It 'names the file model-serial-date-time.json' {
        $p = Export-RunJson -Results $script:sample -OutDir $script:outDir
        [IO.Path]::GetFileName($p) | Should -Match '^Seagate-BUP-Slim-BK-NAA1B2C3-\d{4}-\d{2}-\d{2}-\d{6}\.json$'
    }

    It 'round-trips the scalar fields a reader depends on' {
        $p = Export-RunJson -Results $script:sample -OutDir $script:outDir
        $back = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $back.Grade.Letter | Should -Be 'B'
        $back.Grade.ExitCode | Should -Be 1
        $back.Disk.SerialNumber | Should -Be 'NAA1B2C3'
        $back.Performance.SeqRead.MBps | Should -Be 93.4
        $back.Classification.RPM | Should -Be 5400
    }

    It 'round-trips nested series without truncating them' {
        $p = Export-RunJson -Results $script:sample -OutDir $script:outDir
        $back = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        @($back.Performance.Sustained.SeriesMBps).Count | Should -Be 6
        @($back.Surface.Regions).Count | Should -Be 64
        $back.Grade.WeightedParts.Health.Weight | Should -Be 40
        $back.PerformanceScore.Metrics.SeqRead.Band.Target | Should -Be 110
    }

    It 'records the tool state so a reader can see what was not verified' {
        $p = Export-RunJson -Results $script:sample -OutDir $script:outDir
        $back = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $back.ToolState.Smartctl.Source | Should -Be 'missing'
        $back.ToolState.Smartctl.Ok | Should -BeFalse
    }

    It 'creates the output directory when it does not exist' {
        $nested = Join-Path $script:outDir 'deep/reports'
        $p = Export-RunJson -Results $script:sample -OutDir $nested
        Test-Path -LiteralPath $p | Should -BeTrue
    }

    It 'still writes a report for a run that measured almost nothing' {
        $p = Export-RunJson -Results @{ Errors = @('aborted during preflight') } -OutDir $script:outDir
        Test-Path -LiteralPath $p | Should -BeTrue
        (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).Errors[0] | Should -Match 'aborted'
    }
}

Describe 'Export-RunHtml' {
    BeforeAll {
        $script:htmlPath = Export-RunHtml -Results $script:sample -OutDir $script:outDir
        $script:html = Get-Content -LiteralPath $script:htmlPath -Raw
    }

    It 'writes a file and returns its path' {
        Test-Path -LiteralPath $script:htmlPath | Should -BeTrue
        [IO.Path]::GetExtension($script:htmlPath) | Should -Be '.html'
    }

    It 'is a complete html document' {
        $script:html | Should -Match '<html'
        $script:html | Should -Match '</html>'
        $script:html | Should -Match '<style'
    }

    It 'is self-contained, with no request to any remote host' {
        $script:html | Should -Not -Match 'http://'
        $script:html | Should -Not -Match 'https://'
        $script:html | Should -Not -Match '<script'
    }

    It 'shows the grade letter and score' {
        $script:html | Should -Match '>\s*B\s*<'
        $script:html | Should -Match '84'
    }

    It 'identifies the drive it tested' {
        $script:html | Should -Match 'Seagate BUP Slim BK'
        $script:html | Should -Match 'NAA1B2C3'
    }

    It 'draws the sustained series as an inline svg' {
        $script:html | Should -Match '<svg'
        $script:html | Should -Match '<polyline'
    }

    It 'renders the surface map' {
        ([regex]::Matches($script:html, 'class="cell')).Count | Should -BeGreaterOrEqual 64
    }

    It 'reports what could not be verified rather than hiding it' {
        $script:html | Should -Match 'SMART could not be read without elevation'
        $script:html | Should -Match 'smartctl not found on PATH'
    }

    It 'shows the measured class against the reported media type' {
        $script:html | Should -Match 'Unspecified'
        $script:html | Should -Match 'HDD'
    }

    It 'escapes html-significant characters in drive strings' {
        $evil = @{
            Disk  = @{ Model = 'Acme <script>alert(1)</script> & Co'; SerialNumber = 'A&B' }
            Grade = @{ Letter = 'C'; Score01 = 0.7 }
        }
        $p = Export-RunHtml -Results $evil -OutDir $script:outDir
        $text = Get-Content -LiteralPath $p -Raw
        $text | Should -Not -Match '<script'
        $text | Should -Match '&lt;script&gt;'
        $text | Should -Match 'A&amp;B'
    }

    It 'still writes a report for a run that measured almost nothing' {
        $p = Export-RunHtml -Results @{ Errors = @('aborted during preflight') } -OutDir $script:outDir
        (Get-Content -LiteralPath $p -Raw) | Should -Match 'aborted during preflight'
    }
}

Describe 'Update-History' {
    It 'creates a jsonl file named for the serial' {
        Update-History -Serial 'NAA1B2C3' -Line @{ Grade = 'B'; SeqRead = 93.4 }
        $f = Join-Path $script:histDir 'NAA1B2C3.jsonl'
        Test-Path -LiteralPath $f | Should -BeTrue
    }

    It 'appends rather than overwriting, one json object per line' {
        $serial = 'APPEND1'
        Update-History -Serial $serial -Line @{ Run = 1 }
        Update-History -Serial $serial -Line @{ Run = 2 }
        Update-History -Serial $serial -Line @{ Run = 3 }
        $lines = @(Get-Content -LiteralPath (Join-Path $script:histDir "$serial.jsonl"))
        $lines.Count | Should -Be 3
        foreach ($l in $lines) { { $l | ConvertFrom-Json } | Should -Not -Throw }
        ($lines[2] | ConvertFrom-Json).Run | Should -Be 3
    }

    It 'writes each entry on a single line even for nested data' {
        $serial = 'NESTED1'
        Update-History -Serial $serial -Line @{ Series = @(1, 2, 3); Nested = @{ A = @{ B = 'c' } } }
        @(Get-Content -LiteralPath (Join-Path $script:histDir "$serial.jsonl")).Count | Should -Be 1
    }

    It 'sanitises a serial that would be illegal as a filename' {
        Update-History -Serial 'WD\..\evil:*?' -Line @{ Run = 1 }
        $files = @(Get-ChildItem -LiteralPath $script:histDir -Filter '*.jsonl')
        foreach ($f in $files) { $f.Name | Should -Not -Match '[\\/:*?"<>|]' }
        (Split-Path -Parent $files[0].FullName) | Should -Be $script:histDir
    }

    It 'falls back to a placeholder when the drive reports no serial' {
        { Update-History -Serial '' -Line @{ Run = 1 } } | Should -Not -Throw
        { Update-History -Serial $null -Line @{ Run = 1 } } | Should -Not -Throw
        @(Get-ChildItem -LiteralPath $script:histDir -Filter 'unknown-serial.jsonl').Count | Should -Be 1
    }

    It 'stamps each entry with a timestamp so runs can be ordered' {
        $serial = 'STAMPED1'
        Update-History -Serial $serial -Line @{ Run = 1 }
        $entry = Get-Content -LiteralPath (Join-Path $script:histDir "$serial.jsonl") | ConvertFrom-Json
        $entry.At | Should -Not -BeNullOrEmpty
        { [datetime]::Parse($entry.At) } | Should -Not -Throw
    }
}
