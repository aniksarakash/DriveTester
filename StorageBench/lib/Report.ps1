<#
    Report.ps1 - what the run leaves behind.

    Three artefacts:

      JSON   the machine-readable record. Complete, including the tool state,
             so a reader can tell what was measured from what was assumed.
      HTML   the human record. Self-contained by rule: no stylesheet, font,
             script or image is fetched from anywhere. A drive test often runs
             on a machine that is offline or air-gapped, and a report about
             someone's hardware has no business making network requests when
             it is opened months later.
      JSONL  one line per run, keyed by drive serial, so the same disk
             accumulates a history and a degrading drive becomes visible.

    Every accessor here tolerates absent data. A run that aborted in preflight
    still gets a report, and that report says what went wrong rather than
    failing to render.
#>

$script:SbHistoryOverride = $null

function Set-HistoryDirOverride {
    <# Test seam, matching Set-ToolsDirOverride and Set-ScratchOverride. #>
    param([AllowNull()][AllowEmptyString()][string]$Path)
    $script:SbHistoryOverride = if ([string]::IsNullOrWhiteSpace($Path)) { $null } else { $Path }
}

function Get-HistoryDir {
    <# StorageBench\history by default - beside the tool, not inside the drive under test. #>
    [OutputType([string])]
    param()
    if ($script:SbHistoryOverride) { return $script:SbHistoryOverride }
    Join-Path (Split-Path -Parent $PSScriptRoot) 'history'
}

function Get-ResultField {
    <#
        Dotted-path read that returns $null instead of throwing for anything
        missing, and works against hashtables and objects alike. The results
        bag is assembled phase by phase, so any branch of it may be absent
        when a phase was skipped or failed.
    #>
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Path
    )
    $cur = $Object
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($seg)) { return $null }
            $cur = $cur[$seg]
        } elseif ($cur.PSObject.Properties[$seg]) {
            $cur = $cur.PSObject.Properties[$seg].Value
        } else {
            return $null
        }
    }
    $cur
}

function Get-SafeFileToken {
    <#
        Reduces a model or serial to something safe as one filename segment.
        Anything outside [A-Za-z0-9._-] becomes a dash; dot runs collapse so no
        token can read as a relative path. Truncated because some USB bridges
        report a 60-character model string.
    #>
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string]$Fallback = 'unknown',
        [int]$MaxLength = 48
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Fallback }
    $t = $Text.Trim() -replace '[^A-Za-z0-9._-]', '-'
    $t = $t -replace '-{2,}', '-'
    $t = $t -replace '\.{2,}', '.'
    $t = $t.Trim('-', '.')
    if ($t.Length -gt $MaxLength) { $t = $t.Substring(0, $MaxLength).TrimEnd('-', '.') }
    if ([string]::IsNullOrWhiteSpace($t)) { return $Fallback }
    $t
}

function Get-RunStamp {
    <#
        The run's own start time, not the moment the report was written, so the
        filename matches the run it describes even when export happens late.
    #>
    [OutputType([string])]
    param([AllowNull()]$Results)
    $started = Get-ResultField -Object $Results -Path 'Meta.StartedAt'
    if ($started) {
        try { return ([datetime]$started).ToLocalTime().ToString('yyyy-MM-dd-HHmmss') } catch { }
    }
    [datetime]::Now.ToString('yyyy-MM-dd-HHmmss')
}

function Format-LocalStamp {
    <# Local wall-clock time for reading; the JSON keeps the exact instant. #>
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
    try { ([datetime]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { [string]$Value }
}

function Get-ReportBaseName {
    <# model-serial-yyyy-MM-dd-HHmmss #>
    [OutputType([string])]
    param([AllowNull()]$Results)
    $model = Get-SafeFileToken -Text ([string](Get-ResultField -Object $Results -Path 'Disk.Model')) -Fallback 'unknown-model'
    $serial = Get-SafeFileToken -Text ([string](Get-ResultField -Object $Results -Path 'Disk.SerialNumber')) -Fallback 'unknown-serial' -MaxLength 32
    '{0}-{1}-{2}' -f $model, $serial, (Get-RunStamp -Results $Results)
}

function New-ReportDirectory {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$OutDir)
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    (Resolve-Path -LiteralPath $OutDir).ProviderPath
}

function Export-RunJson {
    <#
        The complete record. Depth 8 covers the deepest branch in the results
        bag (grade part reasons, expectation bands) with room to spare; a
        silently truncated tree would be worse than a large file.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Results,
        [Parameter(Mandatory)][string]$OutDir
    )
    $dir = New-ReportDirectory -OutDir $OutDir
    $path = Join-Path $dir ((Get-ReportBaseName -Results $Results) + '.json')
    $json = $Results | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    $path
}

function Update-History {
    <#
        One JSON object per line, appended, named for the drive serial. A drive
        that gets slower or starts reallocating sectors shows up as a trend
        here and nowhere else.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Serial,
        [Parameter(Mandatory)][AllowNull()]$Line
    )
    $dir = Get-HistoryDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $dirFull = (Resolve-Path -LiteralPath $dir).ProviderPath

    $name = (Get-SafeFileToken -Text $Serial -Fallback 'unknown-serial' -MaxLength 32) + '.jsonl'
    $path = Join-Path $dirFull $name

    # A sanitised token cannot escape, but the check is cheap and this is the
    # one place in the module that writes to a caller-influenced path.
    $resolved = [IO.Path]::GetFullPath($path)
    if (-not $resolved.StartsWith($dirFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "History path escaped the history directory: $resolved"
    }

    # Timestamp first so the line reads chronologically, and copied rather than
    # added in place - the caller's object is not ours to modify.
    $entry = [ordered]@{ At = [datetime]::Now.ToString('o') }
    if ($Line -is [System.Collections.IDictionary]) {
        foreach ($k in $Line.Keys) { if ($k -ne 'At') { $entry[[string]$k] = $Line[$k] } }
    } elseif ($null -ne $Line) {
        foreach ($p in $Line.PSObject.Properties) { if ($p.Name -ne 'At') { $entry[$p.Name] = $p.Value } }
    }

    $json = $entry | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::AppendAllText($resolved, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------- HTML

function ConvertTo-HtmlText {
    <# Ampersand first, or the escapes escape each other. #>
    [OutputType([string])]
    param([AllowNull()]$Text)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    $s.Replace('"', '&quot;').Replace("'", '&#39;')
}

function Get-HtmlHostPath {
    <#
        A download URL with its scheme removed. The provenance of a fetched
        binary is worth showing, but not as something a browser could resolve:
        this report is meant to make no requests at all.
    #>
    [OutputType([string])]
    param([AllowNull()]$Url)
    if ([string]::IsNullOrWhiteSpace([string]$Url)) { return '' }
    ConvertTo-HtmlText -Text (([string]$Url) -replace '^[A-Za-z][A-Za-z0-9+.-]*://', '')
}

function Get-SvgLineChart {
    <#
        The sustained-write series as an inline polyline. No xmlns: inline SVG
        in an HTML5 document is already in the SVG namespace, and the namespace
        URI would be the only http:// string in the file.
    #>
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Values,
        [int]$Width = 760,
        [int]$Height = 170
    )
    $vals = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($vals.Count -lt 2) { return '' }

    $pad = 26
    $max = ($vals | Measure-Object -Maximum).Maximum
    $min = ($vals | Measure-Object -Minimum).Minimum
    if ($max -le 0) { $max = 1 }
    $top = $max * 1.08
    $plotW = $Width - ($pad * 2)
    $plotH = $Height - ($pad * 2)

    $pts = for ($i = 0; $i -lt $vals.Count; $i++) {
        $x = $pad + ($plotW * $i / [math]::Max(1, $vals.Count - 1))
        $y = $pad + $plotH - ($plotH * ($vals[$i] / $top))
        '{0:0.##},{1:0.##}' -f $x, $y
    }
    $points = $pts -join ' '

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(('<svg class="chart" viewBox="0 0 {0} {1}" preserveAspectRatio="none" role="img">' -f $Width, $Height))
    foreach ($frac in 0.0, 0.25, 0.5, 0.75, 1.0) {
        $y = $pad + ($plotH * $frac)
        [void]$sb.Append(('<line class="grid" x1="{0}" y1="{1:0.##}" x2="{2}" y2="{1:0.##}" />' -f $pad, $y, ($Width - $pad)))
    }
    [void]$sb.Append(('<polyline class="series" points="{0}" />' -f $points))
    [void]$sb.Append(('<text class="axis" x="{0}" y="{1}">{2}</text>' -f $pad, ($pad - 8), (ConvertTo-HtmlText -Text (Format-Mbps -MBps $max))))
    [void]$sb.Append(('<text class="axis" x="{0}" y="{1}">{2}</text>' -f $pad, ($Height - 8), (ConvertTo-HtmlText -Text (Format-Mbps -MBps $min))))
    [void]$sb.Append('</svg>')
    $sb.ToString()
}

function Get-HtmlRows {
    <#
        A table body from name/value/note triples. Rows whose value is $null
        are dropped rather than rendered as blanks - an empty cell reads as a
        measurement of nothing, which is not the same as a phase that was
        skipped.
    #>
    [OutputType([string])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Rows)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($r in $Rows) {
        if ($null -eq $r) { continue }
        $val = $r.Value
        if ($null -eq $val -or ([string]$val) -eq '') { continue }
        $note = if ($r.Note) { ConvertTo-HtmlText -Text $r.Note } else { '' }
        [void]$sb.Append(('<tr><th>{0}</th><td class="num">{1}</td><td class="note">{2}</td></tr>' -f
            (ConvertTo-HtmlText -Text $r.Name), (ConvertTo-HtmlText -Text $val), $note))
    }
    $sb.ToString()
}

function Get-HtmlList {
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Items,
        [string]$Class = ''
    )
    $items = @($Items | Where-Object { $_ })
    if ($items.Count -eq 0) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(('<ul class="{0}">' -f $Class))
    foreach ($i in $items) {
        $text = if ($i -is [string]) { $i } elseif ($i.Reason) { [string]$i.Reason } else { [string]$i }
        [void]$sb.Append(('<li>{0}</li>' -f (ConvertTo-HtmlText -Text $text)))
    }
    [void]$sb.Append('</ul>')
    $sb.ToString()
}

function Get-HtmlSection {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][AllowEmptyString()][string]$Body,
        [string]$Subtitle = ''
    )
    if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
    $sub = if ($Subtitle) { '<p class="sub">' + (ConvertTo-HtmlText -Text $Subtitle) + '</p>' } else { '' }
    '<section class="card"><h2>{0}</h2>{1}{2}</section>' -f (ConvertTo-HtmlText -Text $Title), $sub, $Body
}

function Get-ReportCss {
    [OutputType([string])]
    param()
    @'
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0b0d1a;color:#e8ecf8;
  font:14px/1.55 "Segoe UI",-apple-system,system-ui,sans-serif}
a{color:#3dd9ff}
.wrap{max-width:1040px;margin:0 auto;padding:32px 20px 64px}
header.hero{display:flex;gap:24px;align-items:center;flex-wrap:wrap;
  border:1px solid #1e2340;border-radius:16px;padding:24px;
  background:linear-gradient(140deg,#111531,#0d1024 60%,#141a3a)}
.badge{flex:0 0 auto;width:104px;height:104px;border-radius:16px;display:flex;
  align-items:center;justify-content:center;flex-direction:column;
  border:1px solid #2a3157;background:#0b0e20}
.grade-letter{font-size:52px;font-weight:700;line-height:1}
.grade-score{font-size:12px;color:#98a0c0;letter-spacing:.06em}
.g-A .grade-letter{color:#65e6a9}.g-B .grade-letter{color:#a8e063}
.g-C .grade-letter{color:#f0c85a}.g-D .grade-letter{color:#f09646}
.g-F .grade-letter{color:#ff75c3}
.hero-main h1{margin:0 0 4px;font-size:22px;font-weight:600}
.hero-main .meta{color:#98a0c0;font-size:13px;margin:0}
.hero-main .meta span{margin-right:16px;white-space:nowrap}
.card{border:1px solid #1e2340;border-radius:14px;padding:20px 22px;margin-top:20px;background:#0e1226}
.card h2{margin:0 0 14px;font-size:13px;text-transform:uppercase;
  letter-spacing:.12em;color:#8b6fff;font-weight:600}
.card .sub{margin:-8px 0 14px;color:#98a0c0;font-size:13px}
.card .group{margin:20px 0 4px;color:#b8c0da;font-size:11.5px;
  text-transform:uppercase;letter-spacing:.09em;font-weight:600}
.card .group:first-of-type{margin-top:14px}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #171b33;vertical-align:top}
tr:last-child th,tr:last-child td{border-bottom:0}
th{font-weight:500;color:#b8c0da;width:38%}
td.num{font-variant-numeric:tabular-nums;font-family:"Cascadia Mono",Consolas,monospace}
td.note{color:#8189a8;font-size:12.5px;width:30%}
ul{margin:2px 0 10px;padding-left:20px}
ul li{margin:3px 0}
ul.warn li{color:#f0c85a}
ul.fail li{color:#ff75c3}
ul.caveat li{color:#98a0c0}
ul.note li{color:#b8c0da}
.chart{width:100%;height:180px;display:block;margin:4px 0 10px}
.chart .grid{stroke:#1c2140;stroke-width:1}
.chart .series{fill:none;stroke:#3dd9ff;stroke-width:2;stroke-linejoin:round}
.chart .axis{fill:#6d7595;font-size:11px;font-family:Consolas,monospace}
.map{display:flex;flex-wrap:wrap;gap:2px;margin:4px 0 12px}
.cell{width:13px;height:13px;border-radius:2px;background:#2a3157}
.cell.ok{background:#65e6a9}.cell.fair{background:#a8e063}
.cell.slow{background:#f0c85a}.cell.weak{background:#f09646}
.cell.error{background:#ff75c3}
.legend{display:flex;gap:16px;flex-wrap:wrap;color:#98a0c0;font-size:12.5px;align-items:center}
.legend span{display:flex;gap:6px;align-items:center}
.bars{margin-top:6px}
.bar-row{display:flex;align-items:center;gap:12px;margin:6px 0}
.bar-row .lbl{width:120px;color:#b8c0da;font-size:13px}
.bar-row .track{flex:1;height:8px;border-radius:4px;background:#171b33;overflow:hidden}
.bar-row .fill{height:100%;border-radius:4px;background:linear-gradient(90deg,#8b6fff,#3dd9ff)}
.bar-row .val{width:118px;text-align:right;font-family:Consolas,monospace;
  font-variant-numeric:tabular-nums;font-size:12.5px;color:#e8ecf8}
footer{margin-top:28px;color:#6d7595;font-size:12px;line-height:1.7}
footer code{color:#8189a8}
@media print{body{background:#fff;color:#111}.card,header.hero{border-color:#ccc;background:#fff}}
'@
}

function Get-HtmlBarRow {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()]$Fraction,
        [AllowNull()][AllowEmptyString()][string]$Value
    )
    $f = if ($null -eq $Fraction) { 0.0 } else { [double]$Fraction }
    if ($f -lt 0) { $f = 0.0 }
    if ($f -gt 1) { $f = 1.0 }
    '<div class="bar-row"><div class="lbl">{0}</div><div class="track"><div class="fill" style="width:{1:0.#}%"></div></div><div class="val">{2}</div></div>' -f
    (ConvertTo-HtmlText -Text $Label), ($f * 100), (ConvertTo-HtmlText -Text $Value)
}

function Export-RunHtml {
    <#
        The human-readable report. Self-contained: inline CSS, inline SVG, no
        script, no remote reference of any kind. Sections whose data is absent
        are omitted rather than rendered empty, so the report shows what was
        actually measured.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Results,
        [Parameter(Mandatory)][string]$OutDir
    )

    $dir = New-ReportDirectory -OutDir $OutDir
    $path = Join-Path $dir ((Get-ReportBaseName -Results $Results) + '.html')

    $f = { param($p) Get-ResultField -Object $Results -Path $p }

    $model = [string](& $f 'Disk.Model')
    $serial = [string](& $f 'Disk.SerialNumber')
    $letter = [string](& $f 'Grade.Letter')
    if ([string]::IsNullOrWhiteSpace($letter)) { $letter = '?' }
    $score = & $f 'Grade.Score01'
    $scoreText = if ($null -ne $score) { '{0:0.0}/100' -f ([double]$score * 100) } else { 'no score' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!doctype html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine(('<title>StorageBench - {0}</title>' -f (ConvertTo-HtmlText -Text ($model + ' ' + $serial))))
    [void]$sb.AppendLine(('<style>{0}</style>' -f (Get-ReportCss)))
    [void]$sb.AppendLine('</head><body><div class="wrap">')

    # ------------------------------------------------------------- hero
    $metaBits = [System.Collections.Generic.List[string]]::new()
    foreach ($bit in @(
            @{ L = 'drive'; V = (& $f 'Meta.Drive') },
            @{ L = 'preset'; V = (& $f 'Meta.Preset') },
            @{ L = 'started'; V = (Format-LocalStamp -Value (& $f 'Meta.StartedAt')) },
            @{ L = 'bus'; V = (& $f 'Disk.BusType') },
            @{ L = 'capacity'; V = $(if ($null -ne (& $f 'Disk.SizeBytes')) { Format-Bytes -Bytes ([long](& $f 'Disk.SizeBytes')) }) })) {
        if ($null -eq $bit.V -or ([string]$bit.V) -eq '') { continue }
        $metaBits.Add(('<span>{0} <b>{1}</b></span>' -f $bit.L, (ConvertTo-HtmlText -Text $bit.V)))
    }

    $title = if ([string]::IsNullOrWhiteSpace($model)) { 'Unidentified drive' } else { $model }
    if ($serial) { $title = $title + '  -  ' + $serial }

    [void]$sb.AppendLine(('<header class="hero g-{0}"><div class="badge"><div class="grade-letter">{1}</div><div class="grade-score">{2}</div></div><div class="hero-main"><h1>{3}</h1><p class="meta">{4}</p></div></header>' -f
        (ConvertTo-HtmlText -Text $letter), (ConvertTo-HtmlText -Text $letter),
        (ConvertTo-HtmlText -Text $scoreText), (ConvertTo-HtmlText -Text $title),
        ($metaBits -join '')))

    # ------------------------------------------------------------ verdict
    $verdictBody = [System.Text.StringBuilder]::new()
    $parts = & $f 'Grade.WeightedParts'
    if ($parts) {
        [void]$verdictBody.Append('<div class="bars">')
        foreach ($name in @('Health', 'Integrity', 'Performance')) {
            $p = Get-ResultField -Object $parts -Path $name
            if ($null -eq $p) { continue }
            $s = Get-ResultField -Object $p -Path 'Score01'
            $w = Get-ResultField -Object $p -Path 'Weight'
            $val = if ($null -ne $s) { '{0:0.0}/100  x{1}' -f ([double]$s * 100), $w } else { "not measured  x$w" }
            [void]$verdictBody.Append((Get-HtmlBarRow -Label $name -Fraction $s -Value $val))
        }
        [void]$verdictBody.Append('</div>')
    }
    foreach ($set in @(
            @{ Items = (& $f 'Grade.Failures'); Class = 'fail'; Head = 'Failures' },
            @{ Items = (& $f 'Grade.Overrides'); Class = 'warn'; Head = 'Grade capped by' },
            @{ Items = (& $f 'Grade.Warnings'); Class = 'warn'; Head = 'Warnings' },
            @{ Items = (& $f 'Grade.Caveats'); Class = 'caveat'; Head = 'Could not be verified' },
            @{ Items = (& $f 'Grade.Reasons'); Class = 'note'; Head = 'Scoring notes' },
            @{ Items = (& $f 'Errors'); Class = 'fail'; Head = 'Errors during the run' })) {
        $list = Get-HtmlList -Items $set.Items -Class $set.Class
        if ($list) {
            [void]$verdictBody.Append(('<p class="group">{0}</p>' -f $set.Head))
            [void]$verdictBody.Append($list)
        }
    }
    [void]$sb.AppendLine((Get-HtmlSection -Title 'Verdict' -Body $verdictBody.ToString() `
                -Subtitle 'Health 40, Integrity 30, Performance 30. Overrides only ever lower a grade.'))

    # ----------------------------------------------------------- identity
    $cls = & $f 'Classification'
    $rvm = & $f 'ReportedVsMeasured'
    $identity = Get-HtmlRows -Rows @(
        @{ Name = 'Model'; Value = $model }
        @{ Name = 'Serial'; Value = $serial }
        @{ Name = 'Firmware'; Value = (& $f 'Disk.FirmwareRevision') }
        @{ Name = 'Bus'; Value = (& $f 'Disk.BusType') }
        @{ Name = 'Reported media type'; Value = (& $f 'Disk.MediaType')
            Note = $(if ($rvm -and (Get-ResultField -Object $rvm -Path 'Agrees') -eq $false) { Get-ResultField -Object $rvm -Path 'Note' })
        }
        @{ Name = 'Measured class'; Value = (Get-ResultField -Object $cls -Path 'Class')
            Note = $(
                $rpm = Get-ResultField -Object $cls -Path 'RPM'
                $conf = Get-ResultField -Object $cls -Path 'Confidence'
                $b = @()
                if ($rpm) { $b += "$rpm RPM" }
                if ($null -ne $conf) { $b += ('confidence {0:0.00}' -f [double]$conf) }
                $b -join ', ')
        }
        @{ Name = 'Volume'; Value = $(
                $lbl = & $f 'Volume.Label'; $fs = & $f 'Volume.FileSystem'
                if ($lbl -or $fs) { (@($lbl, $fs) | Where-Object { $_ }) -join '  ' })
        }
        @{ Name = 'Free space'; Value = $(if ($null -ne (& $f 'Volume.FreeBytes')) { Format-Bytes -Bytes ([long](& $f 'Volume.FreeBytes')) }) }
        @{ Name = 'Cluster size'; Value = $(if ($null -ne (& $f 'Volume.ClusterBytes')) { Format-Bytes -Bytes ([long](& $f 'Volume.ClusterBytes')) }) }
    )
    $latency = & $f 'Classification.Latency'
    if ($latency) {
        $identity += Get-HtmlRows -Rows @(
            @{ Name = 'Random read latency (avg)'; Value = (Format-Ms -Ms (Get-ResultField -Object $latency -Path 'AvgMs')) }
            @{ Name = 'Random read latency (p99)'; Value = (Format-Ms -Ms (Get-ResultField -Object $latency -Path 'P99')) }
            @{ Name = 'Seek slope'; Value = $(
                    $sl = Get-ResultField -Object $latency -Path 'SeekSlopeMsPerGB'
                    if ($null -ne $sl) { '{0:0.0000} ms/GB' -f [double]$sl })
                Note = 'a flat slope means no mechanical seek'
            }
        )
    }
    if ($identity) {
        $ev = Get-HtmlList -Items (Get-ResultField -Object $cls -Path 'Evidence') -Class 'note'
        [void]$sb.AppendLine((Get-HtmlSection -Title 'Identity and classification' -Body ('<table>' + $identity + '</table>' + $ev) `
                    -Subtitle 'The class is measured from latency behaviour, not taken from what the bus claims.'))
    }

    # -------------------------------------------------------------- SMART
    $smart = & $f 'Smart'
    if ($smart) {
        $smartBody = [System.Text.StringBuilder]::new()
        [void]$smartBody.Append('<table>')
        [void]$smartBody.Append((Get-HtmlRows -Rows @(
                    @{ Name = 'Status'; Value = (Get-ResultField -Object $smart -Path 'Status') }
                    @{ Name = 'Overall assessment'; Value = (Get-ResultField -Object $smart -Path 'Overall') }
                    @{ Name = 'Source'; Value = (Get-ResultField -Object $smart -Path 'Source') }
                )))
        foreach ($a in @(Get-ResultField -Object $smart -Path 'Attributes')) {
            if ($null -eq $a) { continue }
            $an = Get-ResultField -Object $a -Path 'Name'
            $av = Get-ResultField -Object $a -Path 'Raw'
            if ($null -eq $av) { $av = Get-ResultField -Object $a -Path 'Value' }
            [void]$smartBody.Append((Get-HtmlRows -Rows @(
                        @{ Name = $an; Value = $av; Note = (Get-ResultField -Object $a -Path 'Verdict') })))
        }
        [void]$smartBody.Append('</table>')
        [void]$smartBody.Append((Get-HtmlList -Items (Get-ResultField -Object $smart -Path 'Notes') -Class 'caveat'))
        [void]$sb.AppendLine((Get-HtmlSection -Title 'Health' -Body $smartBody.ToString()))
    }

    # -------------------------------------------------------- performance
    $perf = & $f 'Performance'
    if ($perf) {
        $perfBody = [System.Text.StringBuilder]::new()
        $rows = Get-HtmlRows -Rows @(
            @{ Name = 'Sequential read'; Value = (Format-Mbps -MBps (& $f 'Performance.SeqRead.MBps'))
                Note = $(if ($null -ne (& $f 'Performance.SeqRead.PeakMBps')) { 'peak ' + (Format-Mbps -MBps (& $f 'Performance.SeqRead.PeakMBps')) })
            }
            @{ Name = 'Sequential write'; Value = (Format-Mbps -MBps (& $f 'Performance.SeqWrite.MBps'))
                Note = $(if ($null -ne (& $f 'Performance.SeqWrite.PeakMBps')) { 'peak ' + (Format-Mbps -MBps (& $f 'Performance.SeqWrite.PeakMBps')) })
            }
            @{ Name = 'Random read QD1'; Value = (Format-IOPS -Iops (& $f 'Performance.RndQd1.IOPS'))
                Note = $(if ($null -ne (& $f 'Performance.RndQd1.P99')) { 'p99 ' + (Format-Ms -Ms (& $f 'Performance.RndQd1.P99')) })
            }
            @{ Name = ('Random read QD' + [string](& $f 'Performance.RndQdN.QueueDepth')); Value = (Format-IOPS -Iops (& $f 'Performance.RndQdN.IOPS'))
                Note = $(if ($null -ne (& $f 'Performance.RndQdN.P99')) { 'p99 ' + (Format-Ms -Ms (& $f 'Performance.RndQdN.P99')) })
            }
            @{ Name = 'Class scored against'; Value = (& $f 'PerformanceScore.Class') }
        )
        if ($rows) { [void]$perfBody.Append('<table>' + $rows + '</table>') }

        $series = & $f 'Performance.Sustained.SeriesMBps'
        $chart = Get-SvgLineChart -Values @($series)
        if ($chart) {
            [void]$perfBody.Append('<p class="group">Sustained write</p>')
            [void]$perfBody.Append($chart)
            $cliff = & $f 'Performance.Sustained.CliffDetected'
            if ($cliff -eq $true) {
                $at = & $f 'Performance.Sustained.CliffAtMB'
                [void]$perfBody.Append((Get-HtmlList -Items @("Write speed fell away after about $at MB - cache exhausted, this is the drive's true sustained rate.") -Class 'warn'))
            }
        }

        $zonePcts = @(& $f 'Performance.Zones.ZonePcts')
        $zoneMBps = @(& $f 'Performance.Zones.ZoneMBps')
        if ($zoneMBps.Count -gt 0) {
            $zmax = ($zoneMBps | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum
            if ($zmax -gt 0) {
                [void]$perfBody.Append('<p class="group">Read speed by position on the platter</p><div class="bars">')
                for ($i = 0; $i -lt $zoneMBps.Count; $i++) {
                    $pct = if ($i -lt $zonePcts.Count) { $zonePcts[$i] } else { $i }
                    [void]$perfBody.Append((Get-HtmlBarRow -Label ("at $pct%") -Fraction ($zoneMBps[$i] / $zmax) -Value (Format-Mbps -MBps $zoneMBps[$i])))
                }
                [void]$perfBody.Append('</div>')
            }
        }
        [void]$sb.AppendLine((Get-HtmlSection -Title 'Performance' -Body $perfBody.ToString()))
    }

    # ---------------------------------------------------------- integrity
    $integ = & $f 'Integrity'
    if ($integ) {
        $rows = Get-HtmlRows -Rows @(
            @{ Name = 'Data verified'; Value = $(
                    $mb = Get-ResultField -Object $integ -Path 'VerifiedMB'
                    if ($null -ne $mb) { Format-Bytes -Bytes ([long]$mb * 1MB) })
                Note = (Get-ResultField -Object $integ -Path 'Mode')
            }
            @{ Name = 'Coverage of capacity'; Value = $(
                    $cov = Get-ResultField -Object $integ -Path 'CoveragePct'
                    if ($null -ne $cov) { '{0:0.00}%' -f ([double]$cov * 100) })
                Note = 'a sample, not a full-surface guarantee'
            }
            @{ Name = 'Mismatched blocks'; Value = ([string]@(Get-ResultField -Object $integ -Path 'Errors').Count) }
            @{ Name = 'Counterfeit capacity suspected'; Value = $(
                    $c = Get-ResultField -Object $integ -Path 'CounterfeitSuspected'
                    if ($null -ne $c) { if ($c) { 'yes' } else { 'no' } })
            }
        )
        if ($rows) { [void]$sb.AppendLine((Get-HtmlSection -Title 'Integrity' -Body ('<table>' + $rows + '</table>') `
                        -Subtitle 'Every block written carries its own run id, file index and offset, and is read back and compared.')) }
    }

    # ------------------------------------------------------------ surface
    $regions = @(& $f 'Surface.Regions')
    if ($regions.Count -gt 0) {
        $mapBody = [System.Text.StringBuilder]::new()
        [void]$mapBody.Append('<div class="map">')
        foreach ($r in $regions) {
            if ($null -eq $r) { continue }
            $st = [string](Get-ResultField -Object $r -Path 'Status')
            if ([string]::IsNullOrWhiteSpace($st)) { $st = 'error' }
            $mb = Get-ResultField -Object $r -Path 'MBps'
            $tip = if ($null -ne $mb) { '{0} - {1}' -f $st, (Format-Mbps -MBps $mb) } else { $st }
            [void]$mapBody.Append(('<div class="cell {0}" title="{1}"></div>' -f
                (ConvertTo-HtmlText -Text $st), (ConvertTo-HtmlText -Text $tip)))
        }
        [void]$mapBody.Append('</div><div class="legend">')
        foreach ($s in 'ok', 'fair', 'slow', 'weak', 'error') {
            [void]$mapBody.Append(('<span><i class="cell {0}"></i>{0}</span>' -f $s))
        }
        [void]$mapBody.Append('</div>')
        [void]$mapBody.Append((Get-HtmlList -Items (& $f 'Surface.Errors') -Class 'fail'))
        [void]$sb.AppendLine((Get-HtmlSection -Title 'Surface' -Body $mapBody.ToString() `
                    -Subtitle 'Each cell is one region, shaded by read speed relative to this drive''s own median.'))
    }

    # -------------------------------------------------------------- tools
    $tools = & $f 'ToolState'
    if ($tools) {
        $toolBody = [System.Text.StringBuilder]::new()
        [void]$toolBody.Append('<table>')
        foreach ($name in 'Smartctl', 'DiskSpd') {
            $t = Get-ResultField -Object $tools -Path $name
            if ($null -eq $t) { continue }
            $ok = Get-ResultField -Object $t -Path 'Ok'
            $note = @()
            $src = Get-ResultField -Object $t -Path 'Source'
            if ($src) { $note += "source $src" }
            $hostPath = Get-HtmlHostPath -Url (Get-ResultField -Object $t -Path 'Url')
            if ($hostPath) { $note += "from $hostPath" }
            [void]$toolBody.Append((Get-HtmlRows -Rows @(
                        @{ Name = $name
                            Value = $(
                                $v = Get-ResultField -Object $t -Path 'Version'
                                if ($ok -and $v) { $v } elseif ($ok) { 'present' } else { 'not used' })
                            Note = ($note -join ', ')
                        })))
        }
        [void]$toolBody.Append('</table>')
        [void]$toolBody.Append((Get-HtmlList -Items (Get-ResultField -Object $tools -Path 'Warnings') -Class 'caveat'))
        [void]$sb.AppendLine((Get-HtmlSection -Title 'External tools' -Body $toolBody.ToString() `
                    -Subtitle 'A binary is never executed unless its SHA-256 matches the pin recorded in the source.'))
    }

    # ------------------------------------------------------------- footer
    $foot = [System.Collections.Generic.List[string]]::new()
    $runId = & $f 'Meta.RunId'
    if ($runId) { $foot.Add(('run <code>{0}</code>' -f (ConvertTo-HtmlText -Text $runId))) }
    $tool = & $f 'Meta.Tool'; $ver = & $f 'Meta.Version'
    if ($tool) { $foot.Add((ConvertTo-HtmlText -Text (@($tool, $ver) | Where-Object { $_ }) -join ' ')) }
    $machine = & $f 'Meta.Machine'
    if ($machine) { $foot.Add(('on {0}' -f (ConvertTo-HtmlText -Text $machine))) }
    if ((& $f 'Meta.Elevated') -eq $false) { $foot.Add('run without elevation') }
    $foot.Add('Nothing outside the scratch directory was written. This report makes no network requests.')
    [void]$sb.AppendLine(('<footer>{0}</footer>' -f ($foot -join ' &middot; ')))

    [void]$sb.AppendLine('</div></body></html>')

    [IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    $path
}
