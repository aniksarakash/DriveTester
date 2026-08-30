# Running StorageBench

A step-by-step guide to executing a run, reading what comes back, and dealing
with the situations that come up. For what the project *is*, see the
[README](../README.md).

---

## 1. Check your environment

StorageBench needs Windows and PowerShell 7.0 or newer. It does **not** need
administrator rights.

```powershell
$PSVersionTable.PSVersion
```

If that prints 5.1, you are in Windows PowerShell, not PowerShell 7. Install
PowerShell 7 and use the `pwsh` command rather than `powershell`.

```powershell
winget install --id Microsoft.PowerShell
```

Confirm the files are where the script expects:

```powershell
cd "C:\Users\aniks\Desktop\New folder\StorageBench"
Get-ChildItem .\lib\*.ps1 | Measure-Object
```

You should see 13 files. The script refuses to start if any are missing, and
names the one it could not find.

### If the script will not run at all

An unsigned local script can be blocked by execution policy. This runs it for
that one invocation without changing any machine setting:

```powershell
pwsh -ExecutionPolicy Bypass -File .\StorageBench.ps1 -Drive D -Preset Quick
```

---

## 2. Find the drive you mean

Get the letter right before anything else. Testing the wrong volume is the one
mistake the tool cannot undo for you.

```powershell
Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}}
```

Note the letter, and note the free space — the preset you can run depends on it.

---

## 3. Always dry-run first

`-DryRun` writes nothing whatsoever. It resolves the drive, computes the exact
plan, and prints it.

```powershell
pwsh .\StorageBench.ps1 -Drive D -Preset Standard -DryRun
```

```
StorageBench 1.0.0   preset Standard   about 10 minutes

  drive      D: "Backup" NTFS
  disk       #1 Seagate BUP Slim BK [USB, reports Unspecified]
  capacity   298.1 GB total, 214.7 GB free
  writes     9.5 GB under D:\.storagebench-scratch\, removed afterwards
  reserve    14.9 GB of free space is never touched
  phases     identity -> classify -> health -> bench -> integrity 8.0 GB
  degraded   smartctl not found; auto-fetch is disabled ...
  dry run    nothing will be written; this is the plan only

Dry run complete. No bytes were written.
```

Read four things before you go further:

| Line | What to check |
|---|---|
| `drive` / `disk` | Is this actually the device you meant? Check the model and label, not just the letter. |
| `writes` | How many bytes will be written, and where. |
| `phases` | What you will get. A missing phase here is a gap in the answer. |
| `degraded` | What it will *not* be able to measure, and why. |

`-DryRun` also works on a protected volume — it plans the run and tells you it
would be refused, rather than refusing to plan.

---

## 4. Run it

```powershell
pwsh .\StorageBench.ps1 -Drive D -Preset Standard
```

You will be asked to confirm before a single byte is written:

```
Proceed? [y/N]
```

Anything other than `y` or `yes` cancels, and nothing is written.

### Choosing a preset

| Preset | Time | Writes | Use it when |
|---|---|---|---|
| `Quick` | ~2 min | ~1.5 GB | You want a sanity check, or a first look at an unknown device. |
| `Standard` | ~10 min | ~9.5 GB | Default. Real numbers, real integrity coverage, no long wait. |
| `Thorough` | ~40 min | ~40 GB | You are deciding whether to trust this drive with something. Adds sustained write and the surface sweep. |
| `Certify` | hours | all free space allowed | You suspect the capacity is a lie, or the drive is going into service. Verifies every free byte it is permitted to touch. |

`Certify` is the one that catches counterfeit capacity. A fake reports a large
size and silently wraps writes back over earlier blocks; only writing across
the whole claimed range and reading it back exposes that.

### Watching it run

The full-screen view shows the current phase, a progress bar with an ETA, and
metrics as they land. Two live displays are worth understanding:

- **Sustained write sparkline** — the shape matters more than the numbers. A
  line that starts high and drops off a cliff is an SLC cache running dry; the
  rate after the cliff is the drive's real sustained speed.
- **Surface block map** — one glyph per region, from fast to unreadable. A
  scattering of slow regions on a platter is early mechanical trouble.

If the display is wrong for your terminal, or you are capturing output:

```powershell
pwsh .\StorageBench.ps1 -Drive D -Preset Standard -Plain
```

Plain mode is selected automatically whenever output is redirected to a file or
a pipe, so you do not have to remember it in scripts.

---

## 5. Interrupting a run

Press **Ctrl+C**. The interrupt is handled cooperatively: it sets a flag and
cancels the kill, so the current step finishes and cleanup still runs.

```
Interrupt received - finishing the current step, then cleaning up.
```

Give it a moment. The scratch directory is removed before the process exits,
and the run reports itself as interrupted rather than pretending it finished.

If the process is killed outright — power loss, a hard `taskkill` — the scratch
directory survives. Nothing is lost: a manifest of every file is written
*before* the first file exists, and the next run against that volume finds the
leftovers and sweeps them:

```
degraded   1 scratch folder(s) from an interrupted run are still on D: and will be removed
```

To clear one by hand, delete `<Drive>:\.storagebench-scratch\`. Nothing outside
that folder is ever touched.

---

## 6. Read the result

### The verdict panel

```
  Grade   B   score 0.78
  held to B (from A) by the findings above
  caveat  SMART data could not be read on this drive, so its health is unknown
```

The letter comes from three weighted parts — **health 40%, integrity 30%,
performance 30%** — and then from any override that fired. Overrides only ever
push the letter *down*.

| What was found | Result |
|---|---|
| A block did not read back as written | **F** |
| Distant blocks returned identical content | **F** — suspect counterfeit capacity |
| A region was unreadable | **F** |
| SMART reports pending or reallocated sectors, or overall failure | **F** |
| SMART could not be read, or only coarsely | capped at **B** |

A **B with a health caveat is the normal result on USB enclosures**, which
usually do not pass SMART through. It does not mean the drive is suspect; it
means health could not be verified, and the tool will not certify what it could
not read.

Performance is scored against what the *measured* class of drive should do. A
5400 RPM USB disk is not marked down for failing to be an NVMe.

### The report files

Written to `StorageBench/reports/`:

```powershell
Get-ChildItem ..\StorageBench\reports | Sort-Object LastWriteTime -Descending | Select-Object -First 4
Invoke-Item (Get-ChildItem ..\StorageBench\reports\*.html | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
```

- **HTML** — the run as a readable page. Self-contained: no external
  stylesheet, script, or font, so it renders on an offline machine and does not
  phone home about your hardware.
- **JSON** — the complete record: every measurement series, the plan actually
  executed, the notes explaining any adjustment, and the provenance of any
  external tool used.

Pull a number straight out of the JSON:

```powershell
$run = Get-Content (Get-ChildItem ..\StorageBench\reports\*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1) -Raw | ConvertFrom-Json
$run.Grade.Letter
$run.Performance.SeqRead.MBps
$run.Integrity.CoveragePct
$run.Plan.Method
```

`StorageBench/history/` keeps one line per run, keyed by drive serial, so a
drive tested repeatedly builds a record you can compare against.

---

## 7. Understanding what it chose to measure

The classify phase runs before the benchmark, so once the drive says what it
is, the rest of the run is retuned to suit it. You will see this during the
run:

```
  Method   tuned for HDD
  note     queue depth cut from 32 to 4 - one head cannot serve a deeper queue
  note     random QDN samples cut from 1024 to 256 - at platter speed the rest
           would add minutes and not precision
```

That is deliberate, and it is recorded in the report under `Plan.Method` and
`Plan.Notes`. A mechanical drive is not asked to serve a deep queue, because
the number that comes back would be the scheduler's rather than the drive's;
flash *is*, because it only shows real throughput with the queue full. If the
medium cannot be identified, the preset runs exactly as written and says so.

---

## 8. Scripting it

The process exit code is the verdict:

| Code | Meaning |
|---|---|
| `0` | Grade A or B — pass |
| `1` | Grade C — warn |
| `2` | Grade D or F — fail, or the run was refused |
| `3` | Aborted, interrupted, or a tool error |

```powershell
pwsh .\StorageBench.ps1 -Drive D -Preset Standard -Yes -Plain
if ($LASTEXITCODE -ge 2) { Write-Error "Drive D failed its bench (exit $LASTEXITCODE)"; exit $LASTEXITCODE }
```

`-Yes` is **required** when stdin is redirected. Rather than hang on a prompt
nobody can answer, the run refuses to start and tells you to pass it.

---

## 9. Situations you will hit

### `Cannot test D: - volume not ready`

The letter is not mounted. Re-check with `Get-Volume`, and make sure an
external drive is plugged in and has finished spinning up.

### `Refusing to write to C: - C: is protected (boot disk, system disk, hosts Windows)`

Working as intended. `-Force` overrides it, and you should have a reason —
StorageBench writes into a scratch folder, not to raw sectors, but a large
integrity pass on your system volume will consume real free space for the
duration of the run.

### `Refusing to start: space is tight`

The plan needs more than the volume can give while keeping the reserve of
`max(2 GB, 5% of the volume)` untouched. Either free space, or shrink the run:

```powershell
pwsh .\StorageBench.ps1 -Drive D -Preset Standard -IntegritySizeGB 2
```

### `smartctl not found; auto-fetch is disabled`

Expected in this build. The health phase falls back through WMI, the storage
reliability counters, and finally the drive's own health status. Each fallback
is named in the report as `Smart.Source`, and a coarse source caps the grade at
B. To get full per-attribute health, install `smartctl` yourself and put it on
`PATH` or in `StorageBench/tools/`.

Nothing downloads on its own. Auto-fetch requires `-FetchTools` **and** a
SHA-256 pinned in `lib/Tools.ps1`; no hashes are pinned here, so an unverified
binary is never executed. `-NoNet` forbids network access outright.

### The run says counterfeit capacity is suspected

Distant offsets returned identical content — the drive wrapped your writes back
over earlier blocks. Confirm with `Certify`, which verifies every free byte it
is allowed to touch:

```powershell
pwsh .\StorageBench.ps1 -Drive D -Preset Certify
```

Do not trust the device with anything until that comes back clean.

### The grade is B and everything looks fine

Read the caveat. It is almost always SMART being unreadable through a USB
bridge. Performance and integrity passed; health simply could not be verified.

---

## 10. Running the tests

Pester 6 is vendored in `.tools/` (git-ignored). From the repository root:

```powershell
pwsh -NoProfile -c "Import-Module .\.tools\modules\Pester\6.1.0\Pester.psd1 -Force; Invoke-Pester -Path .\StorageBench\tests -Output Detailed"
```

123 tests, all passing. `Integration.Tests.ps1` runs the whole pipeline over a
temp directory through the scratch override the safety layer exposes — real
handles, real bytes, read back — and then runs `StorageBench.ps1` as a process
to prove `-DryRun` writes nothing and that the system volume is refused. It
needs no removable drive.

---

## 11. Full option reference

| Option | Effect |
|---|---|
| `-Drive <letter>` | Volume to test. Default `D`. |
| `-Preset <name>` | `Quick`, `Standard`, `Thorough`, `Certify`. Default `Standard`. |
| `-DryRun` | Print the plan and exit. Writes nothing. |
| `-Yes` | Skip the consent prompt. Required when stdin is redirected. |
| `-Plain` | Line output instead of full-screen. Automatic when redirected. |
| `-Force` | Test a protected volume anyway. |
| `-IntegritySizeGB <n>` | Set the integrity size explicitly, overruling the preset. |
| `-SkipBench` | Drop the benchmark. The grade records the gap. |
| `-SkipIntegrity` | Drop the pattern write/verify. |
| `-SkipSmart` | Drop the health read. |
| `-NoClean` | Keep the scratch directory after the run. |
| `-FetchTools` | Permit downloading the optional external tools. |
| `-NoNet` | Forbid all network access. |

### Worked examples

```powershell
# See the plan for a full certify run without committing to it
pwsh .\StorageBench.ps1 -Drive E -Preset Certify -DryRun

# Verify a suspect USB stick end to end, unattended, logged
pwsh .\StorageBench.ps1 -Drive E -Preset Certify -Yes -Plain | Tee-Object -FilePath .\certify-E.log

# Performance only, on a drive whose health you already know
pwsh .\StorageBench.ps1 -Drive D -Preset Thorough -SkipIntegrity -SkipSmart

# Integrity only, 4 GB, keeping the scratch files for inspection
pwsh .\StorageBench.ps1 -Drive D -Preset Quick -SkipBench -IntegritySizeGB 4 -NoClean

# Fully offline
pwsh .\StorageBench.ps1 -Drive D -Preset Standard -NoNet
```
