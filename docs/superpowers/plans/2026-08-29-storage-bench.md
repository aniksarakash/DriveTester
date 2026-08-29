# StorageBench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A world-class, non-destructive PowerShell disk-benchmarking tool that identifies, classifies, health-checks, benchmarks, and verifies any attached drive — with a TUI dashboard, letter-grade verdict, and JSON/HTML reports — and runs it against D: on the target machine.

**Architecture:** Thin entry point (`StorageBench.ps1`) that dot-sources 13 focused library modules in `lib/`, each returning plain `[pscustomobject]` result records. TDD via Pester for all pure logic; integration smoke tests exercise real I/O on D: at tiny sizes; a real `-Quick` run produces the first JSON/HTML report.

**Tech Stack:** PowerShell 7.6+ (Core), .NET `FileStream` with `FILE_FLAG_NO_BUFFERING` (0x20000000), `Get-CimInstance` (Storage WMI), `fsutil`, optional smartctl/diskspd (consent-gated fetch), Pester 5, self-contained HTML report (inline CSS/JS).

**Spec:** `docs/superpowers/specs/2026-08-29-storage-bench-design.md` (parent dir of the tool folder)

## Global Constraints

- Target platform: Windows 11, PowerShell 7.6+ Core; PS 5.1 degrades gracefully (no `$PSStyle` reliance in logic paths).
- **Safety (non-negotiable):** no write handle on any raw device ever; all test data under `<Vol>:\.storagebench-scratch\<runId>\`; reserve `max(2 GB, 5% of volume)`; system/boot volumes refused for writes unless `-Force`; manifest before file creation; cleanup in `finally` + Ctrl+C handler; `-DryRun` writes nothing.
- Unbuffered I/O: `[System.IO.FileOptions]0x20000000`; block sizes multiples of physical sector (4096 on D:); incompressible PRNG content.
- Console geometry reads MUST be try/caught (throws "The handle is invalid" when redirected — confirmed on target). Fallback 100×30.
- Every missing datum is explained with its remedy; never blank, never implied.
- Exit codes: 0 pass, 1 warn, 2 fail, 3 tool error.
- Performance scoring is class-relative via `Expectations.ps1`; the measured class (Classify) feeds grading, never `MediaType` alone.

## Global Public Interfaces (locked here; all tasks must match exactly)

- `Core.ps1`: `Format-Bytes(long)->string`, `Format-Duration(double)->string`, `Format-Mbps(double)->string`, `Format-IOPS(double)->string`, `Get-ConsoleGeometry()->@{W;H}`, `New-RunId()->string`, `Get-Pct(cur,total)->double`, `New-RandomStream(seed)->obj` (repeatable PRNG)
- `Safety.ps1`: `Initialize-Scratch(char)->@{Root;RunId;ManifestPath;Files}` , `Register-ScratchFile(session,path)`, `Clear-Scratch(session)`, `Get-ScratchRoot(char)->string`, `Test-Reserve(char,long)->@{Ok;FreeGB;NeedGB;ReserveGB}`, `Find-OrphanedScratch(char)->string[]`, `Test-VolumeWritableForTest(diskInfo,char)->@{Ok;Reason}`
- `Tools.ps1`: `Get-ToolState()->@{Smartctl=@{Path;Source;Version;Ok};DiskSpd=@{Path;Source;Version;Ok};Warnings=@()}`, `Invoke-ToolFetch(tool)->$path|$null`, `Invoke-Smartctl(args,timeoutS)->$text|$null`, `Get-FileHash256(path)->string`
- `Inventory.ps1`: `Get-DriveInventory()->object[]` (one per PhysicalDisk), `Get-VolumeInfo(char)->obj`, `Get-VolumeGeometry(char)->obj` (fsutil-based)
- `Classify.ps1`: `Measure-ReadLatency(filePath,samples,block,positions[])->@{AvgMs;P50;P95;P99;MaxMs;SeekSlopeMsPerGB}`, `Classify-Latency(lat)->@{Class;RPM;Confidence;Evidence}`, `Invoke-MediaClassification(char,session)->obj`
- `Smart.ps1`: `Get-SmartReport(diskInfo,toolState,isAdmin)->@{Status;Source;Attributes;Overall;Notes}`, `Test-SmartThreshold(attr)->PASS|WARN|FAIL` (pure)
- `Bench.ps1`: `Measure-Sequential(file,mode,bytesPerRun,block)->@{MBps;Seconds;Bytes;PeakMBps}`, `Measure-RandomQd1(file,samples,block)->@{IOPS;AvgMs;P50;P95;P99;MaxMs}`, `Measure-RandomQdN(file,queueDepth,samples,block)->@{IOPS;AvgMs;P95;P99;MaxMs}`, `Measure-SustainedWrite(file,totalBytes,intervalSec,sampleCb)->@{SeriesMBps;CliffDetected;CliffAtMB;FinalMBps}`, `Measure-ZoneProfile(file,block,zones)->@{ZonePcts;ZoneMBps}`
- `Integrity.ps1`: `New-PatternBlock(runId,fileIdx,offset)->byte[4096]`, `Verify-PatternBlock(block,runId,fileIdx,offset)->@{Ok;MismatchByte;Expected;Actual}`, `Invoke-IntegrityScan(vol,session,sizeMB,mode,progressCb)->@{VerifiedMB;Errors;CounterfeitSuspected;CoveragePct}`
- `Surface.ps1`: `Invoke-SurfaceScan(vol,session,regions,progressCb)->@{Mode;Regions;Errors}`
- `Expectations.ps1`: `Get-DriveClass(classification,busType)->string`, `Get-ExpectedRange(class)->@{SeqRead;SeqWrite;RndIOPS;RndWriteIOPS}`, `Get-PerformanceScore(benchResults,class)->@{Score01;Metrics}`
- `Grade.ps1`: `Invoke-Grade(results)->@{Letter;Score01;WeightedParts;Overrides;Reasons;Warnings;Failures;Caveats;ExitCode}`
- `Ui.ps1`: `New-Ui(mode)->ui`, `ui.ShowHeader(text)`, `ui.Phase(title)`, `ui.Progress(pct,label,extra)`, `ui.Metric(name,value,status)`, `ui.Sparkline(values)`, `ui.BlockMap(regions,legend)`, `ui.ResultPanel(grade)`, `ui.Footer()`, `ui.Close()`; plain-mode auto when `[Console]::IsOutputRedirected` or `-Plain`
- `Report.ps1`: `Export-RunJson(results,outDir)->path`, `Export-RunHtml(results,outDir)->path`, `Update-History(serial,line)->void`
- `StorageBench.ps1` params: `-Drive <char>`, `-Preset Quick|Standard|Thorough|Certify`, `-Yes`, `-NoNet`, `-FetchTools`, `-Plain`, `-DryRun`, `-Force`, `-IntegritySizeGB <int>`, `-SkipIntegrity`, `-SkipBench`, `-SkipSmart`, `-NoClean`

---

## Task 1: Scaffold + Core

**Files:** Create `StorageBench/Core.ps1`, `StorageBench/tests/Core.Tests.ps1`, `StorageBench/lib/` dirs, `StorageBench/reports/`, `StorageBench/history/`, `StorageBench/tools/`

**Interfaces:** see Core signatures above.

- [ ] Create folder tree. `StorageBench.ps1` placeholder prints "scaffold ok".
- [ ] Write `Core.Tests.ps1`: `Format-Bytes 0→"0 B"`, `298.1GB→"298.1 GB"`; `Format-Duration 90→"1m 30s"`, `5400→"1h 30m 0s"`; `New-RandomStream(42)` produces identical first 16 bytes as `New-RandomStream(42)` and different from seed(7); `Get-ConsoleGeometry` never throws and returns W,H ≥ 40.
- [ ] Run tests → fail (fns missing).
- [ ] Implement Core.ps1 (pure helpers; PRNG = xorshift64 seeded, `$seed` param; geometry wrapped in try/catch, fallback 100×30).
- [ ] Run tests → pass. Dry check that geometry does not throw under redirected output.

## Task 2: Safety

**Files:** `StorageBench/lib/Safety.ps1`, `StorageBench/tests/Safety.Tests.ps1`

**Interfaces:** see Safety signatures above.

- [ ] Tests first: reserve math (300GB vol, 2GB min reserve; 40GB vol → 5% = 2GB, both cases), `Test-Reserve` refuses when free < reserve+need, `Initialize-Scratch` creates manifest.json BEFORE any file and lists it first, `Register-ScratchFile` then `Clear-Scratch` removes every registered file and the folder, `Find-OrphanedScratch` finds a pre-created fake orphan folder but ignores `reports/`.
- [ ] Implement: manifest JSON at root; Register appends; Clear reads manifest and deletes only listed paths (defense: delete only paths that resolve under scratch root); orphan sweep lists `[0-9]{8}-[0-9]{6}-[a-z0-9]{4}` dirs.
- [ ] Tests pass.

## Task 3: Tools (detect, fetch, verify)

**Files:** `StorageBench/lib/Tools.ps1`, `StorageBench/tests/Tools.Tests.ps1`

**Interfaces:** `Get-ToolState`, `Invoke-ToolFetch`, `Invoke-Smartctl`, `Get-FileHash256`.

Pinned facts (verified 2026-08-29): smartmontools latest = RELEASE_7_5, only `smartmontools-7.5.win32-setup.exe` (no zip); diskspd = v2.2 `DiskSpd.ZIP` → contains `amd64/DiskSpd.exe`. SHA-256 values filled at implementation time from the fetched files (pin the downloaded file's own hash after first verify — plan records the method; the runner pins actual values visible in Fetch).

- [ ] Tests: `Get-FileHash256` returns 64-hex; `Get-ToolState` with no tools marks Ok=false with note; fetch flow called with `-NoNet` returns null and no network call (mock via function stub for fetch).
- [ ] Implement: detect PATH + `tools/`; fetch = download to `tools\_pkg\`, verify SHA-256 against pinned table, extract (Expand-Archive for zip; for setup.exe attempt silent run with `/VERYSILENT /SUPPRESSMSGBOXES /DIR=<tools>\smartmontools /NORESTART`, then locate `smartctl.exe`; on any failure or elevation prompt → delete package, degrade, record warning). `Invoke-Smartctl` runs with timeout and captures stdout only.
- [ ] Tests pass. Live probe: `Get-ToolState` on this machine → both missing, warnings accurate.

## Task 4: Inventory

**Files:** `StorageBench/lib/Inventory.ps1`, `StorageBench/tests/Inventory.Tests.ps1`

**Interfaces:** `Get-DriveInventory`, `Get-VolumeInfo`, `Get-VolumeGeometry`.

- [ ] Tests (pure parts): map `MediaType`/`BusType` strings; geometry parser for fsutil output sample (512/4096/4K cluster) — parse from fixture text, not live call.
- [ ] Implement: `MSFT_PhysicalDisk` + `MSFT_Disk` + `Win32_DiskDrive` joined by device id; Volumes via `Get-Volume` filtered to the disk's partitions (`Get-Partition`); geometry via `fsutil fsinfo ntfsinfo`, `fsutil behavior query DisableDeleteNotify`; BitLocker via `Get-BitLockerVolume` try/catch; NVMe link width/gen via `MSFT_PhysicalDisk` SpindleSpeed? (no — via `Get-PhysicalDisk | Select *Nvme*` properties try/catch); `IsSystem/IsBoot` from `Get-Disk`.
- [ ] Tests pass. Live: inventory of this machine must show Disk0 NVMe boot/system and Disk1 USB 298.1 GB with fsutil geometry 512e/4096 cluster, TRIM allowed.

## Task 5: Classify

**Files:** `StorageBench/lib/Classify.ps1`, `StorageBench/tests/Classify.Tests.ps1`

**Interfaces:** `Measure-ReadLatency`, `Classify-Latency`, `Invoke-MediaClassification`.

- [ ] Tests — the money tests: vector from this machine's D: probe (avg 8.437 ms, p99 15.877, seek-slope high) → `HDD`, RPM band 5400, confidence high; vector avg 0.09 ms, slope ~0 → `SSD`; avg 1.8 ms flat → `SSD-bridge|SMR`; avg 8 ms flat (no slope) → `HDD` with lower confidence note.
- [ ] Implement `Classify-Latency` purely: thresholds avg>3ms ∧ slope>0.05 ms/GB → HDD (RPM by avg: <7.5→5400, <10→7200, else estimate); avg<0.5 flat → SSD; 0.5–3 flat → SSD-bridge/SMR. `Measure-ReadLatency`: file of size ≥ 256 MB in scratch, random positions across [0, len], 4 KiB reads, compute slope from distance-vs-latency regression (simple least squares — pure function `Get-SeekSlope(points)` in Core for testability). `Invoke-MediaClassification` = probe + report vs stated.
- [ ] Tests pass. Live: run on D: → measured HDD ≈5400 RPM, reported Unspecified → mismatch noted.

## Task 6: Smart

**Files:** `StorageBench/lib/Smart.ps1`, `StorageBench/tests/Smart.Tests.ps1`

**Interfaces:** `Get-SmartReport`, `Test-SmartThreshold` (pure).

- [ ] Tests: thresholds table — pending>0 FAIL; realloc 1–50 WARN, ≥50 FAIL (reallocated>0 caps grade elsewhere; here attribute level); used% 80–95 WARN, >95 FAIL; CRC>0 WARN; NVMe critical warning any → FAIL; attribute absent → UNVERIFIED with note. Ladder precedence: smartctl result wins over reliability counter; reliability counter requires admin — non-admin path skips to fallback and records `WhyMissing`.
- [ ] Implement: try smartctl (`smartctl -a -d auto <device>`; for physical disk with path from `Win32_DiskDrive`; map device numbers), then `Get-StorageReliabilityCounter`, then `MSStorageDriver_FailurePredictData` (parse raw bytes per attribute id), then `MSFT/Win32` status; always record `Source` and each attribute's `Thresholded`.
- [ ] Tests pass. Live on D: non-admin → Status=unavailable (or degraded), notes give exact remedy (elevate / smartctl). Elevated attempt if possible (not in this session).

## Task 7: Bench

**Files:** `StorageBench/lib/Bench.ps1`, `StorageBench/tests/Bench.Tests.ps1`

**Interfaces:** listed above.

- [ ] Tests: seq read returns MBps > 0 and bytes read exact; QD1 latency stats correct on synthetic file (assert avg within tolerance of injected pattern via small real file write/read on D: temp scratch — integration-lite); sustained series length = ceil(total/interval) and `CliffDetected` when final < 60% of initial after passing 128 MB; zone profile returns N zones with monotonic MBps array.
- [ ] Implement: `Measure-Sequential` with 1 MiB unbuffered FileStream (Write: `Flush($true)`; Read: discard); `Measure-RandomQd1` random 4 KiB seeks (capture per-op ms); `Measure-RandomQdN` async: `FileStream` with `useAsync:$true`, Task pool of N, semaphore, collect latencies (fallback: QD1 × threads labeled); `Measure-SustainedWrite` continuous 4 MiB chunks, sample each interval via callback; `Measure-ZoneProfile` reads 32 MiB at each zone pct (zones over a 1 GiB scratch file).
- [ ] Tests pass, then live mini-run on D: (256 MB) — expect ~88 MB/s write, ~93 read, QD1 ~117 IOPS.

## Task 8: Integrity

**Files:** `StorageBench/lib/Integrity.ps1`, `StorageBench/tests/Integrity.Tests.ps1`

**Interfaces:** listed above.

- [ ] Tests: pattern round-trip (write block → verify identical); flip byte 777 in one block → `Verify-PatternBlock` reports `MismatchByte=777` with correct expected/actual; verify on block from different runId fails; spread scan plan math: 1 GB, 16 files, stride → expected coverage; fake wrapped-address test: serve same physical content for two logical ranges (simulate by writing same pattern twice and verifying second read against *first* block's stamp → tool reports CounterfeitSuspected).
- [ ] Implement: block = 4 KiB, header = runId(16B)+fileIdx(8B)+offset(8B)+CRC32(4B)+filler PRNG; `Invoke-IntegrityScan` writes `N` files spread across free space (N by mode: 16/64/256/contiguous), per file writes sampled blocks (stride), then verifies: read back each block, compare header + CRC; any mismatch recorded with offset; counterfeit check = repeated pattern identity across distant blocks; coverage via recorded written range / free space.
- [ ] Tests pass. Live mini: 64 MB spread on D: → clean, ~2 s.

## Task 9: Surface

**Files:** `StorageBench/lib/Surface.ps1`, `StorageBench/tests/Surface.Tests.ps1`

- [ ] Tests: region latency aggregation; block-map legend mapping (≥3 fast, 3–6 ok, 6–12 slow, 12–30 very slow, >30 error); when raw denied → Mode=file and note.
- [ ] Implement: non-admin = read latency per region across scratch file extents; admin = open `\\.\PhysicalDriveN` read-only 1 MiB blocks with latency per 64 MiB region (try/catch deny → fall back). Returns `@($regions)` of `@{Pct;Ms;Status}`.
- [ ] Tests pass (use Core legend fn pure; skip raw path).

## Task 10: Expectations

**Files:** `StorageBench/lib/Expectations.ps1`, `StorageBench/tests/Expectations.Tests.ps1`

- [ ] Tests: class mapping NVMe+Gen4 string info → `NVMe-Gen4`; USB+HDD → `USB-HDD`; ranges exist for all 8 classes; score: seq read 450 MB/s in SATA-SSD class (exp 400–550) → ~0.9; 90 MB/s in NVMe-Gen4 class → < 0.2.
- [ ] Implement: table of classes → `@{SeqRead@{Min;Typ;Max};SeqWrite…;RndReadIOPS…;RndWriteIOPS…}`; score = mean of clamped ratios (ratio against `Typ`).

## Task 11: Grade

**Files:** `StorageBench/lib/Grade.ps1`, `StorageBench/tests/Grade.Tests.ps1`

- [ ] Tests: all six hard overrides (integrity mismatch → F irrespective of 99% health score; pending>0 → D; realloc>0 → C; SMART fail → F; unreadable sector → F; SMART missing → cap B + caveat); weighting math 40/30/30; letter mapping 90+ A, 80 B, 70 C, 60 D, else F; warnings don't cap below A−.
- [ ] Implement per spec §5.7.
- [ ] Tests pass.

## Task 12: Ui

**Files:** `StorageBench/lib/Ui.ps1`, `StorageBench/tests/Ui.Tests.ps1`

**Interfaces:** `New-Ui(mode)` returning object per Global Interfaces.

- [ ] Tests: bar rendering width math; sparkline from series; block map from regions; plain-mode phase line contains title; `New-Ui 'auto'` under redirected output resolves to plain (assert `[Console]::IsOutputRedirected` true in test run → chooses Plain).
- [ ] Implement: plain renderer (scrolling lines: `[phase] title`, progress `[####----] 63% 412 MB/s ETA 0:42`), plus TUI: alternate buffer `ESC[?1049h`, diff repaint at 100 ms, panels via box chars with 24-bit color, gauges, spinner frames `⠁⠂⠄⡀⢀⠠⠐⠈`, sparkline via `Get-Spark` glyphs `▁▂▃▄▅▆▇█`, block map rendering, `ESC[?1049l` on Close + Ctrl+C handler registered by entry point.
- [ ] Tests pass.

## Task 13: Report

**Files:** `StorageBench/lib/Report.ps1`, `StorageBench/tests/Report.Tests.ps1`

- [ ] Tests: JSON round-trip (export → import → key fields equal); HTML contains `<html` and no `http://` external refs (self-contained), contains grade letter; history append creates serial-jsonl and appends line; filename pattern `model-serial-yyyy-MM-dd-HHmmss.json`.
- [ ] Implement: JSON via `ConvertTo-Json -Depth 8`; HTML self-contained with inline CSS, SVG sparkline for sustained series, table for metrics, block map via divs, grade badge; history one JSON line per run.
- [ ] Tests pass.

## Task 14: Entry point

**Files:** `StorageBench/StorageBench.ps1`, `StorageBench/tests/Entry.Tests.ps1` (param parsing/exit codes via mocked modules)

**Interfaces:** per Global Constraints.

- [ ] Tests: param defaults (D, Standard); `-DryRun` with mocked modules → zero writes, exit 0; refuse system/boot volume without `-Force`; exit code mapping.
- [ ] Implement: param block, dot-source order (Core, Safety, Tools, Inventory, Classify, Smart, Bench, Integrity, Surface, Expectations, Grade, Ui, Report), phase orchestration with per-phase UI + skip prompts, Ctrl+C handler (Clear-Scratch + restore terminal + exit 3), preflight print + confirm (`-Yes`), final grade panel, reports written, exit code.
- [ ] Tests pass.

## Task 15: Integration + real run

**Files:** `StorageBench/tests/Integration.Tests.ps1`

- [ ] Integration smoke on D: at tiny sizes (all phases, 64 MB) in plain mode → phase results sane, scratch cleaned, exit 0.
- [ ] Real `-Quick` run on D: (plain mode in this session): expect Identity OK, Classify HDD, SMART unavailable-with-notes, Bench ≈88/93 MB/s and ≈117 IOPS, Integrity 1 GB clean, Grade capped B with caveat, JSON + HTML written.
- [ ] Report files exist and HTML opens with data.

## Task 16: Handoff (no git unless offered)

- [ ] Print final summary; offer `git init` + commit (not done automatically — working dir is not a repo; user instruction: commit only when asked).
- [ ] Provide user command: `cd "C:\Users\aniks\Desktop\New folder\StorageBench"; pwsh .\StorageBench.ps1 -Drive D -Preset Quick` for interactive TUI.
