#Requires -Version 7.0
<#
    Ui.Tests.ps1 - the renderer.

    Everything asserted here is a pure string transform. The console itself is
    never driven by these tests: the ui object accepts a sink, so plain-mode
    output is captured as text instead of being written to a terminal that
    Pester has redirected anyway.
#>

BeforeAll {
    $lib = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
    . (Join-Path $lib 'Core.ps1')
    . (Join-Path $lib 'Ui.ps1')

    function New-CaptureUi {
        param([string]$Mode = 'plain')
        $lines = [System.Collections.Generic.List[string]]::new()
        $sink = { param($line) $lines.Add([string]$line) }.GetNewClosure()
        $ui = New-Ui -Mode $Mode -Sink $sink
        [pscustomobject]@{ Ui = $ui; Lines = $lines }
    }
}

Describe 'Get-ProgressBar' {
    It 'fills nothing at 0 percent' {
        Get-ProgressBar -Pct 0 -Width 10 -Ascii | Should -Be '[----------]'
    }

    It 'fills everything at 100 percent' {
        Get-ProgressBar -Pct 100 -Width 10 -Ascii | Should -Be '[##########]'
    }

    It 'fills half the width at 50 percent' {
        Get-ProgressBar -Pct 50 -Width 10 -Ascii | Should -Be '[#####-----]'
    }

    It 'keeps total rendered length at Width plus the two brackets' {
        foreach ($p in 0, 7, 33, 66, 99, 100) {
            (Get-ProgressBar -Pct $p -Width 24 -Ascii).Length | Should -Be 26
        }
    }

    It 'clamps out-of-range percentages instead of overflowing the bar' {
        Get-ProgressBar -Pct -30 -Width 8 -Ascii | Should -Be '[--------]'
        Get-ProgressBar -Pct 480 -Width 8 -Ascii | Should -Be '[########]'
    }

    It 'treats a null percentage as zero' {
        Get-ProgressBar -Pct $null -Width 4 -Ascii | Should -Be '[----]'
    }

    It 'uses block glyphs when not in ascii mode' {
        Get-ProgressBar -Pct 100 -Width 4 | Should -Be ('[' + ([string][char]0x2588) * 4 + ']')
    }

    It 'never renders a bar narrower than one cell' {
        (Get-ProgressBar -Pct 50 -Width 0 -Ascii).Length | Should -BeGreaterOrEqual 3
    }
}

Describe 'Get-Spark' {
    It 'returns one glyph per sample' {
        (Get-Spark -Values @(1, 2, 3, 4, 5)).Length | Should -Be 5
    }

    It 'returns an empty string for an empty series' {
        Get-Spark -Values @() | Should -Be ''
    }

    It 'renders a flat series as one repeated glyph' {
        $s = Get-Spark -Values @(88, 88, 88, 88)
        ($s.ToCharArray() | Select-Object -Unique).Count | Should -Be 1
    }

    It 'puts the tallest glyph at the maximum sample' {
        $s = Get-Spark -Values @(1, 2, 9)
        $s[2] | Should -Be ([char]0x2588)
        [int]$s[0] | Should -BeLessThan ([int]$s[2])
    }

    It 'skips null samples rather than treating them as zero' {
        (Get-Spark -Values @(5, $null, 5)).Length | Should -Be 2
    }

    It 'survives a single sample' {
        (Get-Spark -Values @(42)).Length | Should -Be 1
    }

    It 'falls back to an ascii ramp on request' {
        Get-Spark -Values @(1, 5, 9) -Ascii | Should -Match '^[._=+*#-]{3}$'
    }
}

Describe 'Get-BlockMapLines' {
    BeforeAll {
        $script:regions = 1..64 | ForEach-Object {
            [pscustomobject]@{ Index = $_ - 1; Status = 'ok' }
        }
    }

    It 'wraps the regions to the requested width' {
        $lines = Get-BlockMapLines -Regions $script:regions -Width 32
        $lines.Count | Should -Be 2
        $lines[0].Length | Should -Be 32
    }

    It 'renders one line when everything fits' {
        (Get-BlockMapLines -Regions $script:regions -Width 100).Count | Should -Be 1
    }

    It 'maps each status to its own glyph' {
        $mixed = @(
            [pscustomobject]@{ Status = 'ok' }
            [pscustomobject]@{ Status = 'fair' }
            [pscustomobject]@{ Status = 'slow' }
            [pscustomobject]@{ Status = 'weak' }
            [pscustomobject]@{ Status = 'error' }
        )
        $line = @(Get-BlockMapLines -Regions $mixed -Width 80)[0]
        $line.Length | Should -Be 5
        ($line.ToCharArray() | Select-Object -Unique).Count | Should -Be 5
    }

    It 'returns nothing for no regions' {
        @(Get-BlockMapLines -Regions @() -Width 40).Count | Should -Be 0
    }

    It 'names every status in the legend' {
        $legend = Get-BlockMapLegend
        foreach ($s in 'ok', 'fair', 'slow', 'weak', 'error') { $legend | Should -Match $s }
    }
}

Describe 'New-Ui mode selection' {
    It 'resolves auto to plain while output is redirected' {
        [Console]::IsOutputRedirected | Should -BeTrue -Because 'Pester captures output, so this run is the redirected case'
        (New-Ui -Mode auto).Mode | Should -Be 'plain'
    }

    It 'honours an explicit plain request' {
        (New-Ui -Mode plain).Mode | Should -Be 'plain'
    }

    It 'degrades tui to plain when the console cannot be addressed' {
        (New-Ui -Mode tui).Mode | Should -Be 'plain'
    }

    It 'reports a usable width even when the console handle is invalid' {
        (New-Ui -Mode auto).Width | Should -BeGreaterOrEqual 40
    }
}

Describe 'plain renderer output' {
    It 'writes the phase title' {
        $c = New-CaptureUi
        $c.Ui.Phase('Integrity verification')
        ($c.Lines -join "`n") | Should -Match 'Integrity verification'
    }

    It 'writes percentage and label on a progress line' {
        $c = New-CaptureUi
        $c.Ui.Progress(63, 'sequential read', '412 MB/s')
        $text = $c.Lines -join "`n"
        $text | Should -Match '63'
        $text | Should -Match 'sequential read'
        $text | Should -Match '412 MB/s'
    }

    It 'throttles repeated progress lines but always emits the final one' {
        $c = New-CaptureUi
        foreach ($p in 1..40) { $c.Ui.Progress($p, 'writing', '') }
        $c.Ui.Progress(100, 'writing', '')
        $c.Lines.Count | Should -BeLessThan 41
        $c.Lines[-1] | Should -Match '100'
    }

    It 'writes a metric with its name and value' {
        $c = New-CaptureUi
        $c.Ui.Metric('Sequential read', '93.4 MB/s', 'ok')
        $text = $c.Lines -join "`n"
        $text | Should -Match 'Sequential read'
        $text | Should -Match '93\.4 MB/s'
    }

    It 'marks a failing metric visibly' {
        $c = New-CaptureUi
        $c.Ui.Metric('Reallocated sectors', '14', 'fail')
        ($c.Lines -join "`n") | Should -Match 'FAIL'
    }

    It 'writes the header text' {
        $c = New-CaptureUi
        $c.Ui.ShowHeader('StorageBench 1.0 - drive D:')
        ($c.Lines -join "`n") | Should -Match 'StorageBench 1\.0'
    }

    It 'writes the grade letter, score and caveats in the result panel' {
        $c = New-CaptureUi
        $c.Ui.ResultPanel(@{
                Letter        = 'B'
                Score01       = 0.842
                ExitCode      = 1
                Reasons       = @('Health: SMART unavailable without elevation')
                Warnings      = @('CRC error count is 3')
                Failures      = @()
                Caveats       = @('SMART could not be read')
                Overrides     = @()
                WeightedParts = @{ Health = @{ Score01 = 0.6; Weight = 40 } }
            })
        $text = $c.Lines -join "`n"
        $text | Should -Match 'B'
        $text | Should -Match '84'
        $text | Should -Match 'SMART could not be read'
    }

    It 'renders a result panel for a run that measured nothing' {
        $c = New-CaptureUi
        { $c.Ui.ResultPanel(@{ Letter = 'F'; Score01 = 0.0; ExitCode = 3 }) } | Should -Not -Throw
        ($c.Lines -join "`n") | Should -Match 'F'
    }

    It 'renders a sparkline through the ui object' {
        $c = New-CaptureUi
        $c.Ui.Sparkline(@(10, 20, 30))
        ($c.Lines -join "`n").Length | Should -BeGreaterThan 0
    }

    It 'renders a block map with its legend through the ui object' {
        $c = New-CaptureUi
        $c.Ui.BlockMap(@([pscustomobject]@{ Status = 'ok' }, [pscustomobject]@{ Status = 'weak' }), $true)
        ($c.Lines -join "`n") | Should -Match 'ok'
    }

    It 'closes without throwing and tolerates a second close' {
        $c = New-CaptureUi
        { $c.Ui.Close(); $c.Ui.Close() } | Should -Not -Throw
    }

    It 'writes notes and warnings' {
        $c = New-CaptureUi
        $c.Ui.Note('scratch reserved 2.0 GB')
        $c.Ui.Warn('smartctl not installed')
        $text = $c.Lines -join "`n"
        $text | Should -Match 'scratch reserved'
        $text | Should -Match 'smartctl not installed'
    }

    It 'writes the footer' {
        $c = New-CaptureUi
        $c.Ui.Footer()
        $c.Lines.Count | Should -BeGreaterThan 0
    }
}
