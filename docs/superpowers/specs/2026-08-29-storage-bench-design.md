# StorageBench — Design Spec

**Date:** 2026-08-29
**Status:** Approved (design), pending implementation plan
**Target platform:** Windows 11, PowerShell 7.6+ (Core), with PowerShell 5.1 graceful degradation

---

## 1. Purpose

A single-command Windows PowerShell tool that answers one question about any
attached HDD, SATA SSD, NVMe SSD, or USB-bridged drive:

> **Is this drive healthy, honest about its capacity, and performing to the spec
> of what it actually is?**

The primary use case is **benching new or borrowed drives** — connect, test,
receive a verdict. A small per-serial history is kept so a repeat run reveals
change over time, but trending is not the focus.

### Success criteria

1. Reports a defensible PASS / WARN / FAIL verdict with a letter grade and stated
   reasons.
2. Detects counterfeit-capacity drives.
3. Reports performance relative to the drive's **measured** class, not its
   self-reported one.
4. Cannot destroy user data — safety is structural, not advisory.
5. Runs useful (`-Quick`) in about 90 seconds and exhaustive (`-Certify`) on
   demand.
6. Explains every missing datum and how to obtain it, instead of showing blanks.

---

## 2. Verified environment findings

Everything below was measured on the target machine on 2026-08-29 and drives the
design. These are facts, not assumptions.

| Probe | Result | Consequence for design |
|---|---|---|
| PowerShell | 7.6.4 Core | `PSStyle`, 24-bit colour, `Flush($true)` available |
| Elevation at probe time | **Non-admin** | Admin-only paths must degrade, never crash |
| Disk 0 | FORESEE VP1000F512G, NVMe, 476.9 GB, boot + system (C:) | Must be write-protected by default |
| Disk 1 | JMicron Tech, **BusType USB**, `MediaType = Unspecified`, 298.1 GB (D:) | Bus hides media type — see 2.1 |
| Unbuffered seq write on D: | **87.9 MB/s** (`FILE_FLAG_NO_BUFFERING` 0x20000000 accepted) | Real, cache-bypassed numbers achievable in pure PowerShell |
| Unbuffered seq read on D: | **92.7 MB/s** | Same |
| Random 4 KiB QD1 on D: | **117 IOPS, avg 8.437 ms, p99 15.877 ms** | Unambiguous mechanical-HDD signature |
| `MSStorageDriver_FailurePredictStatus` / `...Data` | `Not supported` | Native SMART unavailable (non-admin + USB bridge) |
| `MSFT_PhysicalDisk`, `MSFT_Disk`, `Win32_DiskDrive` | OK, n=2 | Identity and health status obtainable without admin |
| `Get-StorageReliabilityCounter` | `Access to a CIM resource was not available` | Temperature / wear / POH need elevation |
| Raw `\\.\PhysicalDrive1` open (read) | **DENIED** non-admin | Raw-LBA surface scan is an elevated-only enhancement |
| Raw `\\.\D:` open (read) | **DENIED** non-admin | Same |
| `fsutil fsinfo ntfsinfo D:` | 512 logical / **4096 physical** (512e), 4 KB cluster, 625,106,943 sectors | Free geometry plus 512e detection without admin |
| `fsutil behavior query DisableDeleteNotify` | `= 0` (TRIM allowed) | Free TRIM state |
| `smartctl`, `diskspd` | **Not installed** | Consent-gated portable fetch required |
| `winsat`, `fsutil`, `chkdsk` | Present in System32 | Usable as supplementary sources |
| Unicode + 24-bit colour render | Correct (`╭─╮│╰╯ █▓▒░ ▁▂▄▆█ ⠹⠼⣾`) | TUI is viable |
| `[Console]::IsOutputRedirected` | Correctly `True` when piped | Reliable trigger for plain-text fallback |
| `[Console]::WindowWidth` when redirected | **Throws "The handle is invalid"** | Must be wrapped; never read console geometry unguarded |

### 2.1 Consequence for the default run on this machine

Because SMART is unreachable on D: without elevation and without `smartctl`, a
default non-admin run against D: will report health as **unverified** and, per
§5.7, cap the grade at **B**. This is intended behaviour, not a defect: the tool
must never assert health it could not measure. The report states the cap, the
reason, and the two remedies (run elevated, or install `smartctl`). Running
elevated with `smartctl -d sat` available lifts the cap.

### 2.2 The central insight

Disk 1 reports `MediaType = Unspecified` yet measures 8.4 ms random latency at
117 IOPS — a 5400 RPM mechanical drive behind a USB bridge. **The bus lied.**

StorageBench must therefore classify media from *measured behaviour*, never from
`MediaType` alone. This capability is what distinguishes it from ordinary
disk-speed scripts, and the target hardware is itself the proof case.

---

## 3. Architecture

Modular toolkit (Approach A, approved): a thin entry point plus focused library
files, each with one responsibility and independently testable.

```
StorageBench.ps1              # entry point: params, orchestration, exit code
lib/
  Core.ps1                    # formatting, size/time math, logging, error types
  Ui.ps1                      # TUI primitives + plain-mode renderer
  Safety.ps1                  # preflight, reserve, scratch manifest, cleanup
  Tools.ps1                   # external tool detection + consented fetch
  Inventory.ps1               # identity, geometry, fsutil facts, NVMe/USB detail
  Classify.ps1                # behavioural media classification
  Smart.ps1                   # SMART acquisition + threshold evaluation
  Bench.ps1                   # seq, random QD1/QD32, sustained curve, zones
  Integrity.ps1               # pattern write/verify, spread sampling
  Surface.ps1                 # latency map, elevated raw scan
  Expectations.ps1            # expected performance per drive class
  Grade.ps1                   # weighted score, hard overrides, verdict
  Report.ps1                  # JSON + self-contained HTML
tests/
  <Module>.Tests.ps1          # Pester unit tests per module
  Integration.Tests.ps1       # tiny-size real-I/O smoke tests
reports/                      # run output (JSON + HTML)
history/                      # per-serial run history
tools/                        # portable smartctl/diskspd, if fetched
```

**Loading:** `StorageBench.ps1` dot-sources `lib/*.ps1` in dependency order. No
module writes to global state; each exposes verb-noun functions returning plain
`[pscustomobject]` result records. A `-Bundle` build step that flattens `lib/`
into one portable file is a possible later addition, not in scope now.

---

## 4. Safety model

Non-destructive testing was chosen, so safety is enforced by construction rather
than by warnings.

1. **No write handle is ever opened on a raw device.** `\\.\PhysicalDriveN` and
   `\\.\<Vol>:` are opened read-only or not at all. This eliminates the entire
   class of catastrophic bugs; no code path can partition, format, or overwrite a
   disk.
2. **Single scratch root.** All test data lives in
   `<Drive>:\.storagebench-scratch\<runId>\`. Nothing outside that folder is
   created, modified, or deleted. Existing user files are never opened for write.
3. **Free-space reserve.** `reserve = max(2 GB, 5% of volume size)`. The tool
   refuses to begin a write phase if free space is below the reserve, and stops
   the phase if the reserve would be breached mid-run.
4. **Crash-safe cleanup.** `manifest.json` records each scratch file *before* it
   is created. Cleanup runs in `finally`, and a `[Console]::CancelKeyPress`
   handler removes scratch files on Ctrl+C. On startup, an orphan sweep detects
   leftovers from a killed run and offers to remove them.
5. **System-volume protection.** Boot / system / pagefile-hosting volumes are
   refused for write phases unless `-Force` is given. (C: on this machine is boot
   + system, therefore protected by default.)
6. **Explicit preflight.** Before any write, print the target volume, scratch
   path, exact bytes to be written, reserve remaining afterwards, and estimated
   duration; require confirmation unless `-Yes`.
7. **`-DryRun`** walks the complete plan, printing every intended action and
   writing nothing.
8. **Read-only phases never prompt** — identity, SMART, and read benchmarks run
   without confirmation.

### 4.1 Explicitly out of scope

Destructive full-disk certification, secure erase, firmware update, partition or
volume modification, and repair actions. StorageBench measures and reports; it
never remediates.

---

## 5. Test modules

### 5.1 Identity and inventory — read-only, no admin

Model, serial, firmware revision, bus type, size, partition style, volume list
with free space, logical vs physical sector size (flags 512e), NTFS cluster size,
partition alignment, TRIM state, BitLocker state, health and operational status.
For NVMe: PCIe link generation and width. For USB: bridge/enclosure
identification where exposed.

Sources: `MSFT_PhysicalDisk`, `MSFT_Disk`, `Win32_DiskDrive`, `Get-Partition`,
`Get-Volume`, `fsutil fsinfo ntfsinfo`, `fsutil behavior query
DisableDeleteNotify`, and `smartctl -i` when available.

### 5.2 Behavioural media classification — no admin

A short calibration probe (a few MB, seconds) measures random 4 KiB read latency
and its sensitivity to seek distance, then classifies:

| Signature | Classification |
|---|---|
| avg > 3 ms **and** latency scales with seek distance | HDD; RPM estimated from latency band |
| avg < 0.5 ms, flat across seek distance | SSD (SATA or NVMe by reported bus) |
| 0.5–3 ms, flat | SSD behind a slow bridge, or SMR/host-managed |
| High variance with periodic stalls under sustained write | SMR HDD suspected |

Output states reported vs measured with a confidence level, for example
*"Reported: Unspecified · Measured: HDD ≈5400 RPM (8.4 ms random, seek-dependent)
· confidence: high"*. The measured class — not the reported one — feeds grading.

### 5.3 SMART and health — best-effort, escalating sources

Attributes: temperature, wear-levelling / percentage used, power-on hours, power
cycles, reallocated sectors, current pending sectors, offline uncorrectable,
UDMA CRC errors, host writes (converted to TBW), and for NVMe: critical warning
flags, available spare, media errors, unsafe shutdowns.

Source ladder — first success wins, with provenance recorded per attribute:

1. `smartctl` (auto-probing `-d sat` / `-d nvme`) — the only reliable path
   through a USB bridge such as the JMicron on this machine
2. `Get-StorageReliabilityCounter` — requires elevation
3. `MSStorageDriver_FailurePredictData` — requires elevation, absent on USB here
4. `MSFT_PhysicalDisk.HealthStatus` / `Win32_DiskDrive.Status` — always available

Each attribute is evaluated PASS / WARN / FAIL against published thresholds
(pending sectors > 0 → FAIL; reallocated > 0 → WARN, > 50 → FAIL;
percentage-used > 80 → WARN, > 95 → FAIL; CRC errors > 0 → WARN indicating cable
or bridge fault). A plain-English remaining-life statement is derived from wear
and host writes where present.

**When data is unreachable**, the report names the reason and the remedy — "run
elevated" or "install smartctl" — and offers the consent-gated portable download.
It never renders a blank or implies health it could not verify.

### 5.4 Performance benchmarks — no admin

All I/O uses `FileStream` with `FILE_FLAG_NO_BUFFERING` (0x20000000), verified
working on the target, so the OS cache is bypassed and figures reflect the
device. Buffers are sector-aligned and sizes are multiples of the physical sector
size (4096 here). Data buffers hold incompressible pseudo-random content so
compressing controllers cannot inflate results.

| Test | Method | Reported |
|---|---|---|
| Sequential read / write | 1 MiB blocks, unbuffered | MB/s |
| Random 4 KiB QD1 | single-threaded random offsets | IOPS, MB/s, avg/p50/p95/p99/max ms |
| Random 4 KiB QD32 | async overlapped I/O, 32 outstanding | IOPS, MB/s, latency percentiles |
| Sustained write curve | continuous write sampled once per second | MB/s over time; detects SLC-cache cliff and HDD write-cache saturation |
| Zone / seek profile | throughput at 0 / 25 / 50 / 75 / 100 % of LBA range | MB/s per zone; reveals HDD outer-to-inner falloff |

A brief warm-up is discarded, and each measurement records its duration and byte
count so results are auditable.

### 5.5 Integrity verification — no admin

Non-destructive H2testw-equivalent logic. Every 4 KiB block written into the
scratch folder is stamped with a deterministic header — run id, file index,
logical offset, and a checksum — over incompressible filler. On read-back the
tool byte-compares and reports the **exact byte offset** of any mismatch, plus
whether the failure pattern indicates counterfeit capacity (wrapped or mirrored
address space), silent corruption, or a bad sector.

**Spread sampling** is the key technique: rather than filling from the beginning,
blocks are scattered across the whole free address range, so counterfeit-capacity
detection completes in minutes instead of the roughly two hours a full 298 GB
pass would take at the measured 88 MB/s.

Concretely, spread sampling allocates `N` scratch files of equal size, evenly
spaced across the free-space extent by requesting allocation at intervals of
`free_space / N`, and within each file writes stamped blocks at a fixed stride
rather than contiguously. `N` is 16 for `-Quick`, 64 for `-Standard`, 256 for
`-Thorough`. `-Certify` writes contiguously with no stride, covering every
writable byte. Because NTFS chooses the physical placement, the tool records the
actual extents obtained (via `fsutil file queryextents` where permitted) and
reports the achieved address-range coverage rather than claiming coverage it
cannot confirm.

Any mismatch is a hard failure and forces grade F.

### 5.6 Surface map

Read latency is sampled across regions of the address range and rendered as a
coloured block grid — `█ fast · ▓ ok · ▒ slow · ░ very slow · ✗ error` — with a
legend, and per-region millisecond figures available in the JSON.

Non-admin operates at file level within the scratch set. When elevated, a true
read-only raw-LBA scan of `\\.\PhysicalDriveN` covers the whole device including
unallocated space. Optionally reports `chkdsk /scan` findings (read-only) when
elevated.

### 5.7 Grade, verdict and report

**Weighting:** Health 40 %, Integrity 30 %, Performance 30 %.

**Hard overrides**, applied after weighting:

| Condition | Cap |
|---|---|
| Any integrity mismatch | **F** |
| Current pending sectors > 0 | **D** |
| Reallocated sectors > 0 | **C** |
| SMART overall FAIL / NVMe critical warning | **F** |
| Unreadable sector during surface scan | **F** |
| SMART unobtainable | grade issued with an explicit "unverified health" caveat, capped at **B** |

**Performance scoring is class-relative:** `measured / expected_for_measured_class`,
using the `Expectations.ps1` table (NVMe Gen3/Gen4/Gen5, SATA SSD, USB-bridged
SSD, 7200/5400 RPM HDD, USB-bridged HDD). A 5400 RPM disk over USB is not
penalised for being what it is; a Gen4 NVMe running at Gen3 speeds is.

**Outputs:**

- TUI scorecard panel with grade and itemised reasons
- Versioned JSON at `reports/<model>-<serial>-<timestamp>.json`
- Self-contained HTML report (inline CSS/JS, no external assets) with the
  sustained-write curve, zone profile, latency distribution, and surface map
- One-line append to `history/<serial>.jsonl` for run-to-run comparison
- Exit codes: `0` pass · `1` warn · `2` fail · `3` tool error — CI-usable

### 5.8 External tool policy (`Tools.ps1`)

Detection runs first and silently: `Get-Command` for `smartctl` and `diskspd`,
plus a check of the local `tools/` folder. If a tool is already present it is
used with no prompt and no network access.

If a tool is absent **and** would materially improve the result — which on this
machine means `smartctl` for SMART over the USB bridge — the tool explains what
is missing, what it would unlock, and asks once per session before downloading.
Declining is remembered for the session and the run proceeds degraded. `-NoNet`
disables the offer entirely; `-FetchTools` pre-accepts it.

Downloads go only to `tools/` inside the script directory, never to a system
path, and require no installer or administrator rights. Each download is
verified by SHA-256 against a hash pinned in `Tools.ps1`; a mismatch aborts the
fetch, deletes the file, and continues degraded rather than executing an
unverified binary. Source URLs are pinned to official release artefacts
(smartmontools for `smartctl`, Microsoft for `diskspd`) and recorded in the JSON
report alongside the verified hash, so a run is auditable.

---

## 6. Depth presets

At the measured 88 MB/s, verifying all 298 GB of D:'s free space takes about two
hours. Presets make the trade-off explicit.

| Preset | Coverage | Est. on D: (88 MB/s HDD) |
|---|---|---|
| `-Quick` | Identity, classification, SMART, short bench, 1 GB spread integrity | ~90 s |
| `-Standard` *(default)* | Full bench including QD32 and zone profile, 8 GB spread integrity | ~8 min |
| `-Thorough` | Adds sustained-write curve, 32 GB integrity, surface map | ~35 min |
| `-Certify` | Every writable byte of free space verified | ~2 h |

Sizes are also expressible directly (`-IntegritySizeGB`). Every phase prints an
ETA before starting and can be skipped with a keypress without aborting the run.

---

## 7. Interface

Full-screen TUI in the alternate screen buffer: rounded-border panels, a
selectable card per detected disk (arrow keys or number), live gauges during
tests showing bar fill, MB/s, percentage, ETA and spinner, a throughput
sparkline, the coloured surface map, and a final grade panel.

**Robustness requirements derived from the probes:**

- Every `[Console]::WindowWidth` / `WindowHeight` read is wrapped, because it
  **throws "The handle is invalid" when output is redirected** (confirmed).
  Fallback width 100, height 30.
- `[Console]::IsOutputRedirected` (confirmed reliable) auto-selects plain mode;
  `-Plain` forces it. Plain mode is the scrolling-log renderer: same data, no
  cursor addressing, safe to pipe or log.
- The alternate buffer is exited, the cursor shown, and colours reset in `finally`
  and in the Ctrl+C handler, so the terminal is never left corrupted.
- Rendering is diff-based (only changed cells repainted) at 10 fps or less, so the
  animation costs negligible CPU against the measurement.
- ASCII fallback glyph set if the code page cannot render box-drawing characters.

---

## 8. Testing strategy

Test-first (TDD) for all pure logic, with Pester:

- `Grade` — weighting maths, every hard override, caveat behaviour
- `Classify` — synthetic latency vectors to expected classification, including the
  measured D: vector (8.437 ms avg, seek-dependent) to HDD ≈5400 RPM
- `Smart` — threshold evaluation, source-ladder precedence, provenance recording
- `Integrity` — pattern generation/verification round-trip; injected corruption
  detected at the correct offset; simulated wrapped address space detected as
  counterfeit capacity
- `Safety` — reserve maths, system-volume refusal, manifest lifecycle, orphan
  sweep, path containment (must reject any path outside the scratch root)
- `Core` / `Ui` — size and duration formatting, bar and sparkline rendering,
  console-geometry fallback when `WindowWidth` throws
- `Expectations` — class lookup and ratio scoring

Integration smoke tests run real I/O against D: at tiny sizes (tens of MB), so the
unbuffered path, alignment, manifest and cleanup are all genuinely exercised in
seconds rather than hours.

---

## 9. Open items

- **Git:** the working directory is not a git repository, so this spec is written
  but not committed. Initialising a repo is offered, not assumed.
- **QD32 implementation:** async overlapped I/O via `FileStream` with
  `useAsync: true` and a task pool is the intended approach. If measured overhead
  proves to distort results, fall back to reporting QD1 plus a multi-threaded
  aggregate figure, labelled as such.
