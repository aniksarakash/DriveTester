# StorageBench

A read-write bench test for a drive you do not fully trust.

It identifies the drive, works out what it actually is from how it behaves
rather than what it claims, reads its health, measures it, writes a pattern
over a slice of it and reads that pattern back, then grades the result and
writes a report you can keep.

It is built for the case where the label is the least reliable thing about the
device: the USB stick that reports itself as a fixed SSD, the "2 TB" drive that
is a 32 GB controller lying about its size, the external disk that benchmarks
fine until the cache runs out.

```powershell
cd StorageBench
pwsh .\StorageBench.ps1 -Drive D -Preset Quick
```

## Requirements

- Windows, PowerShell 7.0 or newer (`pwsh`).
- No administrator rights required. Running elevated gets you better SMART
  data; running as a normal user degrades that one phase and says so rather
  than failing.
- Nothing to install. The external tools are optional and off by default (see
  [External tools](#external-tools)).

## What it does

| Phase | What it establishes |
|---|---|
| Identity | Model, serial, firmware, bus, partition style, sector and cluster geometry, TRIM state |
| Classify | What the medium really is, measured from access latency and a seek ladder - not from what the bus reports |
| Health | SMART status, temperature, power-on hours, per-attribute verdicts where they can be read |
| Benchmark | Sequential read and write, random 4K at QD1 and at depth, sustained write, throughput by zone |
| Integrity | Writes a keyed pattern, reads it back, verifies every block, and detects a drive returning the same content from distant offsets |
| Surface | Reads regions across the volume looking for slow or unreadable ones |
| Verdict | A letter, a score, and the reasons for both |

A phase that cannot run degrades the report, never the run. Only a drive that
cannot be identified at all aborts.

## The method follows the medium

The classify phase runs before the benchmark, so once the drive has said what
it is, the rest of the run is retuned to suit it. The same test is not equally
informative on a platter and on PCIe flash, and the run has a fixed time budget
to spend.

| | HDD | SSD | NVMe |
|---|---|---|---|
| Queue depth | cut to 4 | raised to 32 (16 over USB) | raised to 32 |
| Random samples | cut - each read costs milliseconds | preset | raised - each read costs microseconds |
| Zone profile | raised: track position is real | kept, noted as cache behaviour | kept, noted as cache behaviour |
| Sustained write | capped at 2 GB | full: find the SLC cliff | full: find the SLC cliff |
| Surface sweep | full survey | fewer regions: a remap check | fewer regions: a remap check |

The reasoning, in short: a mechanical drive has one head, so thirty-two
outstanding requests do not make it seek in parallel - they queue, and the
number that comes back is the scheduler's rather than the drive's. Flash has
many channels and only shows real throughput with the queue full. A platter has
no SLC cache to exhaust, so a long sustained write tells you nothing a short
one did not; flash has one, and finding where it runs dry is the point.

Every adjustment is recorded as a note, so the run and both reports can say why
they measured what they measured. If the medium cannot be identified, the
preset runs exactly as written.

## Presets

| | Quick | Standard | Thorough | Certify |
|---|---|---|---|---|
| Runtime | ~2 min | ~10 min | ~40 min | hours |
| Benchmark file | 256 MB | 1 GB | 2 GB | 2 GB |
| Sustained write | - | - | 4 GB | 8 GB |
| Integrity pass | 1 GB | 8 GB | 32 GB | every free byte allowed |
| Surface regions | - | - | 64 | 128 |

`Certify` is the only preset whose integrity size is computed rather than
stated. It means every byte of free space the run is permitted to use - free
space, minus the safety reserve, minus what the other phases need at the same
time. It is the setting for a drive you are about to trust with something, or
one you suspect of lying about its capacity.

Any preset trims itself to fit the space actually available, and says so.

## Options

| Option | Effect |
|---|---|
| `-Drive <letter>` | Which volume to test. Default `D`. |
| `-Preset <name>` | `Quick`, `Standard`, `Thorough`, `Certify`. Default `Standard`. |
| `-DryRun` | Print the plan and exit. Writes nothing whatsoever. |
| `-Yes` | Skip the consent prompt. Required when stdin is redirected. |
| `-Plain` | Line-by-line output instead of the full-screen view. Chosen automatically when output is redirected. |
| `-Force` | Test a protected volume anyway. See [Safety](#safety). |
| `-IntegritySizeGB <n>` | Set the integrity pass size explicitly, overruling the preset. |
| `-SkipBench`, `-SkipIntegrity`, `-SkipSmart` | Drop a phase. The grade records the gap. |
| `-NoClean` | Keep the scratch directory after the run. |
| `-FetchTools` | Permit downloading the optional external tools. |
| `-NoNet` | Forbid all network access. |

Start with `-DryRun`. It shows you the drive it resolved, how many bytes it
intends to write, where, what it will not be able to measure, and why.

## The grade

Three parts, weighted: **health 40%, integrity 30%, performance 30%**.

Performance is scored against what the measured class of drive should do, not
against an absolute - a 5400 RPM USB disk is not marked down for failing to be
an NVMe.

Findings can only ever push the letter *down*, never up:

- A block that does not read back as written, a drive returning identical
  content from distant offsets, or an unreadable region: **F**, whatever else
  the run found.
- SMART reporting pending or reallocated sectors, or an overall failure: **F**.
- SMART unreadable, or readable only in coarse form: capped at **B**. A drive
  whose health is unknown is not certified healthy.

| Letter | Exit code |
|---|---|
| A, B | 0 |
| C | 1 |
| D, F | 2 |
| Aborted, or a tool error | 3 |

## Safety

The run writes only inside `<Drive>:\.storagebench-scratch\<runId>\`, and
removes it in a `finally` block - including when the run is interrupted. Ctrl+C
is handled cooperatively: it sets a flag and cancels the kill precisely so that
cleanup cannot be skipped.

- A manifest of every file is written *before* the first file exists, so even a
  hard kill leaves a complete record of what to remove. Leftovers from an
  interrupted run are found and swept on the next run of the same volume.
- A reserve of `max(2 GB, 5% of the volume)` is never touched. A plan that
  would eat into it is trimmed, or refused.
- Boot, system, and Windows-hosting volumes are refused. `-Force` overrides
  that, and you should have a reason.
- `-DryRun` writes nothing at all, and will happily plan a run against a
  protected volume so you can see what it would have done.

Nothing here is a destructive test. It writes into a scratch folder on a
mounted filesystem; it does not write to raw sectors, partition tables, or
anywhere outside that folder.

## Output

Written to `StorageBench/reports/`:

- **JSON** - the complete run record, including every measurement series, the
  plan it executed, the notes explaining any adjustment, and the provenance of
  any external tool used.
- **HTML** - the same run as a readable page. Genuinely self-contained: it
  fetches no stylesheet, script, or font, because a report about someone's
  hardware should render on an offline machine and should not phone home.

`StorageBench/history/` keeps one line per run, keyed by drive serial, so a
drive tested repeatedly builds a record you can compare against.

## External tools

`smartctl` and `diskspd` improve the health and benchmark phases. Both are
optional, and both are **disabled by default**.

Auto-fetch only happens with `-FetchTools`, and only for a tool whose SHA-256
is pinned in `lib/Tools.ps1`. No hashes are pinned in this build, so nothing
downloads: an unpinned tool records a warning and the run degrades. A pinned
hash that does not match aborts the fetch and deletes the package. An
unverified binary is never executed.

To use them, install them yourself and put them on `PATH`, or in
`StorageBench/tools/`.

## Tests

Vendored Pester 6 lives in `.tools/` (git-ignored).

```powershell
pwsh -NoProfile -c "Import-Module .\.tools\modules\Pester\6.1.0\Pester.psd1 -Force; Invoke-Pester -Path .\StorageBench\tests -Output Detailed"
```

`Integration.Tests.ps1` runs the whole pipeline over a temp directory through
the scratch override the safety layer exposes - real handles, real bytes, read
back - and then runs `StorageBench.ps1` as a process to prove `-DryRun` writes
nothing and that the system volume is refused.

## Layout

```
StorageBench/
  StorageBench.ps1     the run: presets, consent, orchestration, cleanup
  lib/
    Core.ps1           formatting, geometry, PRNG, CRC-32
    Safety.ps1         scratch containment, manifests, reserve arithmetic
    Tools.ps1          external tool policy and hash-pinned fetch
    Inventory.ps1      read-only drive and volume enumeration
    Classify.ps1       behavioural media classification
    Smart.ps1          SMART, with a source ladder
    Bench.ps1          unbuffered performance measurement
    Integrity.ps1      keyed pattern write and verify
    Surface.ps1        region sweep
    Expectations.ps1   class-relative performance scoring
    Grade.ps1          weighted parts, downward-only overrides
    Ui.ps1             plain and full-screen renderers
    Report.ps1         JSON, HTML, history
  tests/               Pester suite
docs/                  design spec and implementation plan
```
