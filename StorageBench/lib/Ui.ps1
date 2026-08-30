<#
    Ui.ps1 - the part the user actually watches.

    Two renderers behind one object:

      plain   scrolling lines, no cursor addressing, safe to pipe or redirect
      tui     alternate screen buffer, panels, live gauges, in-place repaint

    Mode 'auto' picks plain whenever [Console]::IsOutputRedirected is true,
    because every cursor and geometry call throws "The handle is invalid" in
    that state on the target machine. That is not a rare edge case - it is what
    happens every time this tool is piped to a file or run from a test harness.

    Two deliberate reductions from the design spec, recorded here rather than
    hidden: the diff repaint is line-level, not cell-level (a changed row is
    rewritten whole), and the panel set is fixed rather than a selectable card
    per disk. Both keep the renderer inside a size that can be reasoned about;
    neither changes a measurement.

    Every glyph has an ASCII twin. If the console code page cannot render box
    drawing characters the tool degrades to '#' and '-' instead of emitting
    mojibake.

    Nothing in this file measures anything. It formats numbers other modules
    produced, and it must never throw: a renderer that crashes would destroy a
    run that had already written and verified real data.
#>

$script:SbUiSparkUnicode = @([char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584,
    [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588)
$script:SbUiSparkAscii = @('.', '_', '-', '=', '+', '*', '#')

$script:SbUiStatusGlyphUnicode = @{
    ok = [char]0x2588; fair = [char]0x2593; slow = [char]0x2592
    weak = [char]0x2591; error = [char]0x2717
}
$script:SbUiStatusGlyphAscii = @{
    ok = '#'; fair = '+'; slow = '='; weak = '-'; error = 'X'
}

# 24-bit foregrounds. Reached only when colour is enabled, which never happens
# while output is redirected.
$script:SbUiColor = @{
    Reset = "`e[0m"; Dim = "`e[2m"; Bold = "`e[1m"
    Green = "`e[38;2;101;230;169m"; Yellow = "`e[38;2;240;200;90m"
    Orange = "`e[38;2;240;150;70m"; Red = "`e[38;2;255;117;195m"
    Cyan = "`e[38;2;61;217;255m"; Violet = "`e[38;2;139;111;255m"
    Grey = "`e[38;2;150;155;175m"
}

$script:SbUiStatusColor = @{
    ok = 'Green'; pass = 'Green'; good = 'Green'
    warn = 'Yellow'; fair = 'Yellow'; slow = 'Orange'; weak = 'Orange'
    fail = 'Red'; error = 'Red'
    info = 'Cyan'; unknown = 'Grey'; unverified = 'Grey'
}

function Test-UnicodeCapable {
    <#
        Whether box-drawing and shade glyphs will survive the console encoding.
        Guarded because OutputEncoding can be unset in odd hosts.
    #>
    [OutputType([bool])]
    param()
    try {
        $enc = [Console]::OutputEncoding
        if ($null -eq $enc) { return $false }
        # UTF-8 (65001) and UTF-16 render the shade blocks; legacy OEM pages do not.
        return ($enc.CodePage -in 65001, 1200, 1201, 12000, 12001)
    } catch { return $false }
}

function Enable-ConsoleUtf8 {
    <#
        Switches the console to UTF-8 so the shade and box glyphs render instead
        of arriving as mojibake. Returns the previous encoding so the caller can
        put it back, or $null when nothing was changed. Only ever called when we
        own the console: a redirected stream belongs to a decoder we cannot see.
    #>
    [OutputType([object])]
    param()
    try {
        $prev = [Console]::OutputEncoding
        if ($prev -and $prev.CodePage -eq 65001) { return $null }
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        return $prev
    } catch { return $null }
}

function Get-ProgressBar {
    <#
        [#####-----] - Width counts the cells between the brackets, so the
        rendered string is always Width + 2 characters wide regardless of the
        percentage. Out-of-range and null percentages clamp instead of
        overflowing, because a progress figure derived from a division is one
        rounding error away from 100.4.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Pct,
        [int]$Width = 30,
        [switch]$Ascii
    )

    if ($Width -lt 1) { $Width = 1 }
    $p = if ($null -eq $Pct) { 0.0 } else { [double]$Pct }
    if ($p -lt 0) { $p = 0.0 }
    if ($p -gt 100) { $p = 100.0 }

    $fillGlyph = if ($Ascii) { '#' } else { [string][char]0x2588 }
    $emptyGlyph = if ($Ascii) { '-' } else { [string][char]0x2591 }

    $filled = [int][math]::Round(($p / 100.0) * $Width)
    if ($filled -gt $Width) { $filled = $Width }
    if ($filled -lt 0) { $filled = 0 }

    '[{0}{1}]' -f ($fillGlyph * $filled), ($emptyGlyph * ($Width - $filled))
}

function Get-Spark {
    <#
        One glyph per sample, scaled against the series maximum rather than
        against min..max. A throughput series that halves should look half as
        tall; min..max scaling would redraw a 2% wobble as a cliff.

        Nulls are dropped, not read as zero - a sample that was never taken is
        not a sample that measured nothing.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Values,
        [switch]$Ascii
    )

    $vals = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($vals.Count -eq 0) { return '' }

    $ramp = if ($Ascii) { $script:SbUiSparkAscii } else { $script:SbUiSparkUnicode }
    $top = $ramp.Count - 1
    $max = ($vals | Measure-Object -Maximum).Maximum
    if ($max -le 0) { return ([string]$ramp[0]) * $vals.Count }

    $sb = [System.Text.StringBuilder]::new($vals.Count)
    foreach ($v in $vals) {
        $x = $v; if ($x -lt 0) { $x = 0 }
        $idx = [int][math]::Round(($x / $max) * $top)
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -gt $top) { $idx = $top }
        [void]$sb.Append($ramp[$idx])
    }
    $sb.ToString()
}

function Get-StatusGlyph {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][string]$Status,
        [switch]$Ascii
    )
    $table = if ($Ascii) { $script:SbUiStatusGlyphAscii } else { $script:SbUiStatusGlyphUnicode }
    $key = if ([string]::IsNullOrWhiteSpace($Status)) { 'error' } else { $Status.ToLowerInvariant() }
    if ($table.ContainsKey($key)) { return [string]$table[$key] }
    [string]$table['error']
}

function Get-BlockMapLines {
    <#
        The surface map: one glyph per region, wrapped to Width. Returns the
        rows as strings so the caller can indent or colour them without this
        function knowing anything about a console.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Regions,
        [int]$Width = 64,
        [switch]$Ascii
    )

    $regs = @($Regions | Where-Object { $null -ne $_ })
    if ($regs.Count -eq 0) { return @() }
    if ($Width -lt 1) { $Width = 1 }

    $out = [System.Collections.Generic.List[string]]::new()
    $sb = [System.Text.StringBuilder]::new($Width)
    foreach ($r in $regs) {
        $status = if ($r.PSObject.Properties['Status']) { [string]$r.Status } else { 'error' }
        [void]$sb.Append((Get-StatusGlyph -Status $status -Ascii:$Ascii))
        if ($sb.Length -ge $Width) { $out.Add($sb.ToString()); [void]$sb.Clear() }
    }
    if ($sb.Length -gt 0) { $out.Add($sb.ToString()) }
    $out.ToArray()
}

function Get-BlockMapLegend {
    <# Names every status the map can draw, so no glyph is left to be guessed at. #>
    [OutputType([string])]
    param([switch]$Ascii)
    $parts = foreach ($s in 'ok', 'fair', 'slow', 'weak', 'error') {
        '{0} {1}' -f (Get-StatusGlyph -Status $s -Ascii:$Ascii), $s
    }
    $parts -join '   '
}

function Get-EtaText {
    <#
        Remaining time from percentage complete and elapsed seconds. Below 3%
        the extrapolation is meaningless, so it says so instead of inventing a
        confident wrong number.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Pct,
        [Parameter(Mandatory)][AllowNull()][object]$ElapsedSec
    )
    if ($null -eq $Pct -or $null -eq $ElapsedSec) { return '' }
    $p = [double]$Pct; $e = [double]$ElapsedSec
    if ($p -lt 3 -or $p -ge 100 -or $e -le 0) { return '' }
    $total = $e * (100.0 / $p)
    $left = $total - $e
    if ($left -lt 0) { $left = 0 }
    'ETA {0}' -f (Format-Duration -Seconds $left)
}

function Get-UiPanelLines {
    <#
        A titled box around a set of body lines. Pure: takes strings, returns
        strings, knows nothing about colour or cursors.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Body,
        [int]$Width = 78,
        [switch]$Ascii
    )

    if ($Width -lt 20) { $Width = 20 }
    $body = @($Body | ForEach-Object { if ($null -eq $_) { '' } else { [string]$_ } })

    if ($Ascii) {
        $tl = '+'; $tr = '+'; $bl = '+'; $br = '+'; $h = '-'; $v = '|'
    } else {
        $tl = [char]0x256D; $tr = [char]0x256E; $bl = [char]0x2570; $br = [char]0x256F
        $h = [char]0x2500; $v = [char]0x2502
    }

    $inner = $Width - 2
    $out = [System.Collections.Generic.List[string]]::new()

    $head = if ([string]::IsNullOrWhiteSpace($Title)) {
        ([string]$h) * $inner
    } else {
        $t = " $Title "
        if ($t.Length -gt ($inner - 2)) { $t = $t.Substring(0, [math]::Max(0, $inner - 2)) }
        '{0}{1}{2}' -f ([string]$h), $t, (([string]$h) * [math]::Max(0, $inner - 1 - $t.Length))
    }
    $out.Add(('{0}{1}{2}' -f $tl, $head, $tr))

    foreach ($line in $body) {
        $text = $line
        # Visible length only - an ANSI sequence occupies no cells.
        $visible = [regex]::Replace($text, "`e\[[0-9;]*[A-Za-z]", '')
        if ($visible.Length -gt ($inner - 2)) {
            $text = $visible.Substring(0, [math]::Max(0, $inner - 5)) + '...'
            $visible = $text
        }
        $pad = [math]::Max(0, $inner - 2 - $visible.Length)
        $out.Add(('{0} {1}{2} {3}' -f $v, $text, (' ' * $pad), $v))
    }

    $out.Add(('{0}{1}{2}' -f $bl, (([string]$h) * $inner), $br))
    $out.ToArray()
}

function New-Ui {
    <#
        Returns the renderer object. Members:

            Mode Width Height Ascii Colour
            ShowHeader(text)  Phase(title)  Progress(pct,label,extra)
            Metric(name,value,status)  Sparkline(values)
            BlockMap(regions,showLegend)  ResultPanel(grade)
            Note(text)  Warn(text)  Footer()  Close()

        -Sink replaces the output destination with a scriptblock taking one
        line. That is how the tests read what was rendered, and how a caller
        could tee the run to a log.
    #>
    [OutputType([psobject])]
    param(
        [ValidateSet('auto', 'plain', 'tui')][string]$Mode = 'auto',
        [scriptblock]$Sink,
        [switch]$Ascii,
        [switch]$NoColor
    )

    $redirected = Test-OutputRedirected

    # tui is refused, not attempted, when the console cannot be addressed: the
    # alternate buffer escape would land in the piped output as garbage.
    $effective = if ($Mode -eq 'plain') { 'plain' }
    elseif ($redirected -or $Sink) { 'plain' }
    elseif ($Mode -eq 'tui') { 'tui' }
    else { 'tui' }

    $geo = Get-ConsoleGeometry
    $w = [int]$geo.W; if ($w -lt 40) { $w = 40 }
    $h = [int]$geo.H; if ($h -lt 10) { $h = 10 }

    $prevEncoding = $null
    if (-not $redirected -and -not $Sink) { $prevEncoding = Enable-ConsoleUtf8 }

    $useAscii = if ($Ascii) { $true } else { -not (Test-UnicodeCapable) }
    $useColor = -not ($NoColor -or $redirected -or $Sink)

    $ui = [pscustomobject]@{
        Mode           = $effective
        Width          = $w
        Height         = $h
        Ascii          = $useAscii
        Colour         = $useColor
        Sink           = $Sink
        PrevEncoding   = $prevEncoding
        Closed         = $false
        Entered        = $false
        LastProgressAt = [datetime]::MinValue
        ProgressMinMs  = 250
        PhaseCount     = 0
        StartedAt      = [datetime]::UtcNow
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Paint -Value {
        param([string]$Line)
        # The single exit for every rendered line. Never throws: a broken
        # console must not abort a run that is holding real data on disk.
        try {
            if ($this.Sink) { & $this.Sink $Line; return }
            if ($this.Mode -eq 'tui' -and -not $this.Entered) { $this.Enter() }
            [Console]::Out.WriteLine($Line)
        } catch { }
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Tint -Value {
        param([string]$Text, [string]$ColorName)
        if (-not $this.Colour -or [string]::IsNullOrEmpty($ColorName)) { return $Text }
        $code = $script:SbUiColor[$ColorName]
        if (-not $code) { return $Text }
        '{0}{1}{2}' -f $code, $Text, $script:SbUiColor.Reset
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Enter -Value {
        # Alternate buffer + hidden cursor. Close() undoes both, and so does
        # the entry point's Ctrl+C handler, so the terminal is never left in
        # this state.
        if ($this.Entered -or $this.Mode -ne 'tui') { return }
        try {
            [Console]::Out.Write("`e[?1049h`e[?25l`e[H`e[2J")
            $this.Entered = $true
        } catch { $this.Mode = 'plain' }
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name ShowHeader -Value {
        param([string]$Text)
        if ($this.Mode -eq 'tui') { $this.Enter() }
        $lines = Get-UiPanelLines -Title '' -Body @($Text) -Width ([math]::Min($this.Width, 100)) -Ascii:$this.Ascii
        foreach ($l in $lines) { $this.Paint(($this.Tint($l, 'Cyan'))) }
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Phase -Value {
        param([string]$Title)
        $this.PhaseCount++
        $this.LastProgressAt = [datetime]::MinValue
        $rule = if ($this.Ascii) { '-' } else { [string][char]0x2500 }
        $label = '{0} {1} ' -f ($rule * 2), $Title
        $tail = [math]::Max(0, [math]::Min($this.Width, 100) - $label.Length)
        $this.Paint('')
        $this.Paint(($this.Tint(($label + ($rule * $tail)), 'Violet')))
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Progress -Value {
        param([object]$Pct, [string]$Label, [string]$Extra)
        # Throttled so a callback firing per 4 KiB block cannot cost more than
        # the measurement it is reporting on. 100% is never throttled: the last
        # line a phase writes has to be the true one.
        $p = if ($null -eq $Pct) { 0.0 } else { [double]$Pct }
        $now = [datetime]::UtcNow
        $due = ($now - $this.LastProgressAt).TotalMilliseconds -ge $this.ProgressMinMs
        if (-not $due -and $p -lt 100) { return }
        $this.LastProgressAt = $now

        $barW = [math]::Max(10, [math]::Min(40, [int]($this.Width / 3)))
        $bar = Get-ProgressBar -Pct $p -Width $barW -Ascii:$this.Ascii
        $line = '  {0} {1,5:0.0}%  {2}' -f $bar, $p, $Label
        if (-not [string]::IsNullOrWhiteSpace($Extra)) { $line += "   $Extra" }

        if ($this.Mode -eq 'tui') {
            # In-place: return to column 0, clear the row, rewrite it.
            try { [Console]::Out.Write("`r`e[2K" + $this.Tint($line, 'Cyan')); return } catch { }
        }
        $this.Paint($line)
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name EndProgress -Value {
        # Closes the in-place row so the next line does not overwrite it.
        if ($this.Mode -eq 'tui' -and $this.Entered) { try { [Console]::Out.WriteLine('') } catch { } }
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Metric -Value {
        param([string]$Name, [object]$Value, [string]$Status)
        $key = if ([string]::IsNullOrWhiteSpace($Status)) { 'info' } else { $Status.ToLowerInvariant() }
        $colour = if ($script:SbUiStatusColor.ContainsKey($key)) { $script:SbUiStatusColor[$key] } else { 'Grey' }
        $tag = switch ($key) {
            'fail' { 'FAIL' }
            'error' { 'FAIL' }
            'warn' { 'WARN' }
            'ok' { 'ok' }
            'pass' { 'ok' }
            default { $key }
        }
        $val = if ($null -eq $Value) { 'n/a' } else { [string]$Value }
        $line = '  {0,-30} {1,-18} {2}' -f $Name, $val, $this.Tint($tag, $colour)
        $this.Paint($line)
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Sparkline -Value {
        param([object[]]$Values, [string]$Label)
        $spark = Get-Spark -Values $Values -Ascii:$this.Ascii
        if ([string]::IsNullOrEmpty($spark)) { return }
        $vals = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
        $min = ($vals | Measure-Object -Minimum).Minimum
        $max = ($vals | Measure-Object -Maximum).Maximum
        $head = if ([string]::IsNullOrWhiteSpace($Label)) { '  ' } else { "  $Label " }
        $line = '{0}{1}  min {2}  max {3}' -f $head, $this.Tint($spark, 'Cyan'),
        (Format-Mbps -MBps $min), (Format-Mbps -MBps $max)
        $this.Paint($line)
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name BlockMap -Value {
        param([object[]]$Regions, [bool]$ShowLegend)
        $avail = [math]::Max(16, [math]::Min(96, $this.Width - 6))
        $n = @($Regions | Where-Object { $null -ne $_ }).Count
        $w = $avail
        if ($n -gt $avail) {
            for ($cand = $avail; $cand -ge 16; $cand--) {
                if ($n % $cand -eq 0) { $w = $cand; break }
            }
        }
        $rows = Get-BlockMapLines -Regions $Regions -Width $w -Ascii:$this.Ascii
        foreach ($r in $rows) { $this.Paint('  ' + $r) }
        if ($ShowLegend -and @($rows).Count -gt 0) {
            $this.Paint('  ' + $this.Tint((Get-BlockMapLegend -Ascii:$this.Ascii), 'Grey'))
        }
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Note -Value {
        param([string]$Text)
        $this.Paint('  ' + $this.Tint('note ', 'Grey') + $Text)
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Warn -Value {
        param([string]$Text)
        $this.Paint('  ' + $this.Tint('warn ', 'Yellow') + $Text)
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name ResultPanel -Value {
        param($Grade)
        if ($null -eq $Grade) { return }

        $letter = [string]$Grade.Letter
        $score = if ($null -ne $Grade.Score01) { [double]$Grade.Score01 * 100.0 } else { 0.0 }
        $colour = switch ($letter) {
            'A' { 'Green' } 'B' { 'Green' } 'C' { 'Yellow' } 'D' { 'Orange' } default { 'Red' }
        }

        $body = [System.Collections.Generic.List[string]]::new()
        $body.Add(('{0}   {1:0.0}/100' -f $this.Tint("GRADE  $letter", $colour), $score))

        $parts = $Grade.WeightedParts
        if ($parts -and $parts.Keys.Count -gt 0) {
            $body.Add('')
            foreach ($name in @('Health', 'Integrity', 'Performance')) {
                if (-not $parts.ContainsKey($name)) { continue }
                $p = $parts[$name]
                $s = if ($null -ne $p.Score01) { '{0,5:0.0}' -f ([double]$p.Score01 * 100.0) } else { '  n/a' }
                $body.Add(('  {0,-12} {1}/100   weight {2}' -f $name, $s, $p.Weight))
            }
        }

        foreach ($set in @(
                @{ Label = 'failed'; Items = $Grade.Failures; Colour = 'Red' },
                @{ Label = 'capped by'; Items = $Grade.Overrides; Colour = 'Orange' },
                @{ Label = 'warning'; Items = $Grade.Warnings; Colour = 'Yellow' },
                @{ Label = 'could not verify'; Items = $Grade.Caveats; Colour = 'Grey' },
                @{ Label = 'because'; Items = $Grade.Reasons; Colour = 'Grey' })) {
            $items = @($set.Items | Where-Object { $_ })
            if ($items.Count -eq 0) { continue }
            $body.Add('')
            foreach ($i in $items) {
                $text = if ($i -is [string]) { $i } elseif ($i.Reason) { [string]$i.Reason } else { [string]$i }
                $body.Add(('  {0}: {1}' -f $this.Tint($set.Label, $set.Colour), $text))
            }
        }

        $this.Paint('')
        foreach ($l in (Get-UiPanelLines -Title 'Verdict' -Body $body.ToArray() -Width ([math]::Min($this.Width, 100)) -Ascii:$this.Ascii)) {
            $this.Paint($l)
        }
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Footer -Value {
        $elapsed = ([datetime]::UtcNow - $this.StartedAt).TotalSeconds
        $this.Paint('')
        $this.Paint($this.Tint(('  run time {0}' -f (Format-Duration -Seconds $elapsed)), 'Grey'))
    }

    Add-Member -InputObject $ui -MemberType ScriptMethod -Name Close -Value {
        # Idempotent by contract: the entry point calls this in finally and the
        # Ctrl+C handler calls it too, and both may run.
        if ($this.Closed) { return }
        $this.Closed = $true
        if ($this.Entered) {
            try { [Console]::Out.Write("`e[?25h`e[0m`e[?1049l") } catch { }
            $this.Entered = $false
        }
        if ($this.PrevEncoding) {
            try { [Console]::OutputEncoding = $this.PrevEncoding } catch { }
            $this.PrevEncoding = $null
        }
    }

    $ui
}
