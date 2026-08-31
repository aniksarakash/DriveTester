# StorageBench — Cross-Platform, Multi-Device, Fast-and-Honest Design Spec

**Date:** 2026-08-31
**Status:** Approved (design), pending implementation plan
**Supersedes:** parts of [2026-08-29-storage-bench-design.md](2026-08-29-storage-bench-design.md) — §2 verified findings, §3 architecture, §5.4 benchmarks, §6 presets, §7 interface. The safety model (§4) and grading weights (§5.7) carry forward unchanged.
**Target platforms:** Windows 10/11 with PowerShell 7.4+, and Linux (glibc, x86-64) with PowerShell 7.4+. WSL2 is supported only against passed-through block devices.

---

## 1. Why this revision exists

The tool as built measures Windows correctly and Linux not at all. It also cannot
measure a modern NVMe drive's random performance on *either* platform, because the
measurement loop is written in PowerShell and the interpreter is slower than the
device.

Both defects are silent. Neither raises an error, produces a warning, or shows up
in a test. Each one produces a plausible-looking number and a letter grade derived
from it. That is worse than a crash: a crash tells you not to trust the output.

This revision makes the tool honest on both platforms, fast enough to test a stack
of drives, and — where it cannot measure honestly — willing to say so instead of
issuing a grade.

### Success criteria

1. An identical command measures the same physical disk on Windows and on native
   Linux and reports throughput within run-to-run variance of the other.
2. Cache bypass is **proven** at runtime on every target, not assumed. A target
   where it cannot be proven is reported and refused, never graded.
3. Random-IOPS figures are bounded by the device, not by the host language.
4. A full single-device run completes in about 60 s on NVMe and about 90 s on HDD.
5. `-All` tests every eligible attached disk without the user naming any of them.
6. WSL2 targets backed by 9p/drvfs are refused with instructions that resolve the
   problem, not merely a rejection.
7. Every published metric carries its own confidence, and grading consumes that
   confidence.

---

## 2. Verified environment findings

All measured on this machine on 2026-08-31 — Windows 11 26200 with PowerShell
7.6.5, and WSL2 Ubuntu 24.04.4 with PowerShell 7.5.4. Probes were throwaway and
are not retained in the tree.

### 2.1 The Linux I/O path is silently wrong in three directions

`lib/Bench.ps1:18` defines `$script:SbNoBuffering = [System.IO.FileOptions]0x20000000`
— the Win32 `FILE_FLAG_NO_BUFFERING` value. `New-BenchStream` then tries
`unbuffered` → `writethrough` → `buffered` and records which one it got.

On Linux, .NET **accepts that flag and ignores it**. No exception is thrown, so the
first attempt always "succeeds" and the run is recorded as `Mode='unbuffered'`.
That claim is false on every Linux run to date.

| Measurement | Current engine | True `O_DIRECT` | Error |
|---|---|---|---|
| Sequential write, 512 MB | 192 MB/s | 546 MB/s | **2.8× understated** |
| Sequential read, 2nd pass | 7,670 MB/s | 1,606 MB/s | **4.8× overstated** |
| 4 KB random read, median | 0.003 ms | 0.127 ms | **42× understated** |

The write figure is understated because .NET maps `FileOptions.WriteThrough` to
`O_SYNC` on Unix, serialising every write against the device. The read figures are
overstated because nothing bypasses the page cache. The errors run in opposite
directions, so no single correction factor exists.

### 2.2 The 0.003 ms figure is the serious one

That is the input to `Invoke-MediaClassification`. It is below the physical floor
of every storage device manufactured, so on Linux the classifier will identify a
5400 RPM spinning disk as NVMe-class, after which `Get-ExpectedRange` compares it
against NVMe expectations and `Invoke-Grade` awards a letter.

The present failure mode is therefore not "throughput numbers are off on Linux".
It is **"a failing hard disk can be graded good on Linux."**

### 2.3 The Windows I/O path is correct

| Measurement | Result | Reading |
|---|---|---|
| Sequential read, pass 1 → pass 2 | 1,619 → 1,701 MB/s | 1.05×, so cache genuinely bypassed |
| 4 KB random read, median | 0.086 ms | plausible for real NVMe |
| Misaligned 4097-byte read | rejected with an exception | flag is enforced by the OS |

No change is required to the Windows cache-bypass strategy. This bounds the work.

### 2.4 The measurement loop cannot reach NVMe speeds on either platform

Measured against a **cached** file, so the device contributes no time and the
figure is the pure software ceiling:

| Loop language | Windows | Linux |
|---|---|---|
| PowerShell | **84,918 IOPS** | 321,094 IOPS |
| C# | 471,716 IOPS | 3,373,449 IOPS |

A mid-range NVMe drive delivers 300,000–700,000 4 KB random IOPS at QD32. The
Windows ceiling of ~85,000 sits *below* that, so the current engine reports
approximately the same random figure for every NVMe drive in existence and then
grades them against each other on it. Error grows as the device approaches the
ceiling, which is precisely the regime that distinguishes a good NVMe from a bad
one.

The inner loop must be C#. This is also the single largest lever on run time, so
accuracy and speed point the same way here.

### 2.5 The kernel will verify cache bypass for us, free

A deliberately misaligned buffer is rejected when — and only when — bypass is
genuinely active:

| Platform | Misaligned span through `RandomAccess` |
|---|---|
| Linux | `REJECTED:IOException` (`EINVAL` from the kernel) |
| Windows | `REJECTED:IOException` |

Identical behaviour on both platforms. This converts cache bypass from an
assumption into a runtime assertion, and it is the mechanism by which the tool
earns the right to publish a number at all.

### 2.6 A single measurement loop spans both platforms

Verified working on Windows 7.6.5 and Linux 7.5.4:

- `Add-Type -CompilerOptions '/unsafe'` compiles.
- `NativeMemory.AlignedAlloc` returns 4096-aligned memory on both (`addr % 4096 == 0`).
- On Linux, a `SafeFileHandle` wrapping a libc `O_DIRECT` file descriptor is
  accepted by `System.IO.RandomAccess`.
- On Windows, `File.OpenHandle` with `FileOptions 0x20000000` is likewise accepted.

| Via `RandomAccess` + aligned buffer | Windows | Linux |
|---|---|---|
| Sequential write | 1,377 MB/s | 937 MB/s |
| Sequential read, pass 1 → 2 | 1,672 → 1,820 (1.09×) | 1,468 → 1,376 (0.94×) |

The Linux read ratio of 0.94× against the broken engine's 4.8× is the fix,
measured. The Windows write figure also improves on `FileStream`'s 1,065 MB/s by
removing a buffering layer that had no purpose under a no-buffering handle.

Therefore the measurement code can be **byte-identical** across platforms, with
divergence confined to acquiring the handle.

### 2.7 WSL2 cannot honestly benchmark a Windows drive

`findmnt -J -T /mnt/c` reports:

```json
{ "target": "/mnt/c", "source": "C:\\", "fstype": "9p",
  "options": "rw,noatime,...,msize=65536,trans=fd,..." }
```

A 64 KB message ceiling over a filesystem bridge. Numbers from `/mnt/*` describe
the bridge, not the disk.

Separately, every WSL2 block device reports `rotational=1` and
`model="Virtual Disk"` — `sda`, `sdb` and `sdc` alike — on a machine whose only
physical disk is NVMe. **On WSL the rotational flag carries no information** and
must be discarded rather than trusted.

---

## 3. Architecture

### 3.1 Platform layer

`lib/Platform.ps1` loads before everything else, detects once, and caches:

```
@{ Os = 'Windows'|'Linux'; IsWsl = bool; WslVersion = 1|2|$null
   Distro = 'Ubuntu 24.04'|$null; Kernel = string; Arch = 'x64'|'arm64'
   Elevated = bool; PwshVersion = version }
```

WSL detection reads `/proc/sys/kernel/osrelease` for `microsoft`/`WSL2`, with
`$env:WSL_DISTRO_NAME` as corroboration.

Exactly four concerns diverge enough to warrant a provider pair:

```
lib/platform/windows/{Inventory,Smart,Tools,Handle}.ps1
lib/platform/linux/{Inventory,Smart,Tools,Handle}.ps1
```

`Platform.ps1` dot-sources one directory. Both sides define the same function
names, so callers are unchanged. `Inventory.ps1`, `Smart.ps1` and `Tools.ps1`
become thin facades that validate arguments and normalise provider output; the
platform detail lives in the provider.

Smaller divergences become primitives in `Platform.ps1` rather than whole provider
pairs — `Get-IsAdmin` (moved out of `Core.ps1`, using `geteuid() == 0` on Linux),
filesystem-root construction, and path-separator rules.

**No PowerShell file outside `lib/Platform.ps1` and `lib/platform/**` may branch on
`$IsWindows` or `$IsLinux`.** Enforced by a test that greps the tree. The embedded
C# in `lib/Io.ps1` does not branch either — it exposes both openers as separate
static methods and each provider's `Handle.ps1` calls the one it wants (§3.5), so
the rule holds without an exemption.

### 3.2 Provider contract

Every provider implements exactly this surface. Return shapes are normalised, so a
consumer cannot tell which platform answered:

| Function | Returns |
|---|---|
| `Get-PlatformDiskList` | all eligible disks: stable id, model, serial, size, bus, media, sector sizes, controller key |
| `Get-PlatformDiskForPath -Path` | the disk backing a filesystem path |
| `Get-PlatformVolumeInfo -Path` | size, free, label, filesystem type, mount options |
| `Get-PlatformVolumeGeometry -Path` | cluster/allocation size, logical and physical sector size, TRIM support |
| `Get-PlatformSmart -Disk` | health record plus the source that produced it |
| `Get-PlatformToolCatalog` | tool definitions with per-platform URL, SHA-256 and executable name |
| `New-PlatformDirectHandle -Path -Access -Create` | `SafeFileHandle` with cache bypass requested |

Sources behind the contract:

| Concern | Windows | Linux |
|---|---|---|
| Disk list | `MSFT_PhysicalDisk`, `Win32_DiskDrive` | `lsblk -J -O`, `/sys/block/*` |
| Path → disk | `Get-Partition -DriveLetter` → `DiskNumber` | `findmnt -J -T` → source → `/sys/block` |
| Filesystem type | `Win32_Volume`, `fsutil fsinfo` | `findmnt -J -T` `fstype` + `options` |
| Geometry | `fsutil fsinfo ntfsinfo`, `MSFT_PhysicalDisk` sector sizes | `lsblk` `log-sec`/`phy-sec`/`min-io`/`opt-io` |
| TRIM | `fsutil behavior query DisableDeleteNotify` | `lsblk` `disc-max` non-zero |
| Rotational | `MSFT_PhysicalDisk.MediaType`, `SpindleSpeed` | `/sys/block/*/queue/rotational` — **discarded on WSL** |
| Controller key | `AdapterSerialNumber`, else `Win32_DiskDrive.SCSIPort` | nearest PCI ancestor of `/sys/block/<dev>`, else `lsblk` `hctl` host |
| SMART | smartctl → `MSStorageDriver_FailurePredict*` → `Get-StorageReliabilityCounter` → `HealthStatus` | smartctl → `nvme smart-log` → `/sys/block/*/device` attributes |

Linux enumeration excludes `loop*`, `ram*`, `zram*`, `dm-*`, `md*` and `sr*`.
This machine reports eight loop and sixteen ram devices, so the filter is not
optional.

### 3.3 Target addressing

`[ValidatePattern('^[A-Za-z]$')][char]$Drive` cannot name a Linux mount point, so
it is replaced by `Resolve-SbTarget`, accepting `D`, `D:`, `D:\`, `/mnt/data`, `/`,
`\\.\PHYSICALDRIVE1` and `/dev/nvme0n1`, and returning:

```
@{ Spec = as typed; FsRoot = where scratch goes; DeviceId = stable device id
   DeviceKind = 'nvme'|'sata'|'usb'|'virtual'|'unknown'; FsType = string
   ControllerKey = string; Trusted = bool; TrustReason = string }
```

A device path resolves to its mounted filesystem, or fails with the actionable
form — *"`/dev/sdb` is mounted at `/mnt/x`; target that instead"*, or *"`/dev/sdb`
is not mounted; mount it first"*. **A raw device never receives a write handle**,
preserving the existing safety invariant.

`-Drive` is retained as an alias of `-Target` so existing invocations keep working.

### 3.4 Trust gate

Evaluated in preflight, before any measurement. A target is untrusted when its
filesystem type is `9p`, `drvfs`, `cifs`, `nfs`, `fuse.*`, `overlay` or `tmpfs`,
or when running under WSL with a path under `/mnt/<letter>`.

An untrusted target is **refused, not degraded**. The message carries the remedy:

```
Refusing to benchmark /mnt/d — it is a 9p passthrough (msize=65536), not the
device. Numbers from here describe the WSL filesystem bridge, not your disk.

To benchmark this disk from WSL, pass it through as real hardware:
  1. Elevated Windows PowerShell:  wsl --mount --bare \\.\PHYSICALDRIVE1
  2. In WSL:                       lsblk                  # find the new device
  3. Mount and target it:          sudo mount /dev/sdX1 /mnt/bench
                                   ./StorageBench.ps1 -Target /mnt/bench

Or run StorageBench from Windows directly, which measures the same disk honestly.
```

Under WSL, reported media type is additionally marked unknowable (per §2.7) and
classification proceeds from measurement alone, labelled as such in the report.

### 3.5 The I/O engine

`lib/Io.ps1` holds one embedded C# type. The measurement loop is identical on both
platforms; only the open differs. The C# type exposes the two openers as separate
static methods and branches on neither — each provider's `Handle.ps1` calls the one
for its platform behind the shared `New-PlatformDirectHandle` name:

- **`OpenDirectWin`** — `File.OpenHandle` with `FileOptions 0x20000000`.
- **`OpenDirectPosix`** — libc `open` with `O_RDWR|O_CREAT|O_TRUNC|O_DIRECT`
  (`0x4000` on x86-64), the descriptor wrapped in
  `SafeFileHandle(fd, ownsHandle: true)`.

Both return a `SafeFileHandle`, so every function downstream of the open is
platform-agnostic by construction rather than by discipline.

Buffers come from `NativeMemory.AlignedAlloc`, aligned to the greater of the
device's physical sector size and 4096. All I/O goes through
`System.IO.RandomAccess`, which is offset-addressed and thread-safe, so queue
depth needs no position juggling.

`FileStream` is removed from the measurement path entirely. Its per-platform
semantics — `WriteThrough` becoming `O_SYNC` — caused the 2.8× write error in §2.1.

#### Bypass proof, and failing closed

Immediately after opening, and before any measurement, the engine issues a read
through a deliberately misaligned span. The kernel must reject it (§2.5).

- **Rejected** → bypass proven; `EngineMode = 'direct-proven'`; measurement proceeds.
- **Accepted** → bypass is not active. `EngineMode = 'buffered-unproven'`, the
  target is marked untrusted, and **no performance grade is issued**.

This replaces the three-attempt ladder in `New-BenchStream`, whose first attempt
succeeded spuriously on Linux. The tool no longer reports the mode it *asked* for;
it reports the mode it *proved*.

The word `unbuffered` is retired from all output in favour of `direct-proven` and
`buffered-unproven`, so an old report can never be confused with a new one.

#### Queue depth

QD1 is a straight loop. QD>1 uses `RandomAccess.ReadAsync`/`WriteAsync` with N
outstanding operations. On Windows this is true overlapped I/O; on Linux .NET
backs async file I/O with the thread pool, so each operation blocks a pool thread
inside `pread`. Real queue depth still reaches the device under `O_DIRECT`. The
asymmetry is recorded in the report rather than hidden, and the thread pool
minimum is raised to N to prevent ramp-up from being measured as latency.

### 3.6 Measurement: convergence under a budget

Fixed byte counts are replaced. Each phase runs in slices; after a minimum of five
slices it stops when the relative standard error of slice throughput falls below
2%, or when the phase budget expires — whichever comes first.

`Rse` is defined as `stdev(slices) / sqrt(n) / mean(slices)`, using the sample
standard deviation (`n-1` denominator). Stated explicitly because the controller
and its unit tests must agree on it to the digit.

Every metric publishes `Value`, `Rse`, `Slices`, `BytesTouched` and `Converged`.
A metric that ran out of budget before converging says so. This is strictly more
honest than a fixed byte count, which reports no confidence at all, and it is
faster in the common case because a consistent device converges early.

A per-phase floor on `BytesTouched` prevents converging inside a DRAM or SLC cache
and calling it a device measurement.

**Budgets.** Both presets are given in full so the arithmetic is checkable:

| Phase | NVMe / SSD | HDD |
|---|---|---|
| Identity, SMART, geometry | 1 s | 1 s |
| Engine self-test and classification | 2 s | 2 s |
| Sequential read | 6 s | 10 s |
| Sequential write | 6 s | 10 s |
| Random QD1 read | 4 s | 8 s |
| Random QD1 write | 4 s | 8 s |
| Random QDn read | 6 s | 6 s |
| Random QDn write | 6 s | 6 s |
| Sustained write and cliff detection | 15 s | 6 s |
| Zone profile | — | 20 s |
| Integrity spot check | 8 s | 12 s |
| Slack | 2 s | 1 s |
| **Total** | **60 s** | **90 s** |

The HDD shape follows the physics: sequential and QD1 get more because seeks
dominate and converge slowly; the zone profile gets 20 s because that is where HDD
truth actually lives; sustained write drops to 6 s because there is no SLC cache to
exhaust. The zone profile is skipped on non-rotational media, where it measures
nothing. Sustained write still runs on HDD — sustained sequential throughput is a
real HDD characteristic — but no SLC boundary exists to find, so "no cliff within
N GB" is the expected and correct HDD result rather than a shortfall.

A phase that is skipped donates its budget to slack rather than to another phase,
so a preset's total is a ceiling and never a target to fill.

Classification reuses the benchmark file rather than writing its own 512 MB,
removing a whole write pass from every run.

#### Cliff detection

Sustained write buckets throughput per 256 MB. The baseline is the **median of the
first three buckets**; a cliff is a drop below 75% of that baseline sustained for
three or more consecutive buckets. Median rather than mean, so one slow opening
bucket cannot set a baseline low enough to hide a real cliff.

If no cliff appears the report says **"no cliff within N GB"**, naming the bytes
actually written — never "no cliff", which would assert something the run did not
test.

### 3.7 Multi-device

`-All` enumerates every eligible disk; `-Target a,b,c` names several.

**Identity, SMART and geometry run in parallel** across all devices. These are
metadata reads with no I/O contention, so parallelism is free.

**Benchmark phases run serially by default.** Two NVMe drives on separate PCIe
lanes still share the root complex, CPU and memory bandwidth; at multi-GB/s that
contention is measurable, and a contended number is a wrong number. At 60 s per
device, four drives is four minutes.

Bus-aware grouping is still built, and `-Parallel auto` opts into it: devices are
grouped by controller key (§3.2), groups run concurrently, members within a group
run serially, and `-MaxParallel` caps concurrency at 2 by default. Any run with
parallel benchmarking active is stamped in the report with a contention warning
and its measurements marked lower-confidence. Where grouping is uncertain, the
scheduler serialises.

Sustained multi-device load also raises thermal throttling risk on laptops, which
the warning names.

`lib/Schedule.ps1` owns grouping and ordering. A device that fails preflight is
skipped with its reason recorded; the run continues and the exit code reflects the
worst outcome across devices.

### 3.8 Grading under confidence

`Invoke-Grade` gains a confidence gate ahead of the existing weights:

- A metric with `Converged = false` is excluded from scoring.
- A target with `EngineMode = 'buffered-unproven'` receives **no performance
  grade**; health and integrity may still be reported.
- If exclusions remove enough evidence that a letter would be guesswork, the tool
  reports `Grade = 'unrated'` with the reason, and exits non-zero.

Refusing to grade is the correct output when the measurement was not trustworthy.
An unrated result is information; a confident letter derived from 0.003 ms is not.

Health 40 / Integrity 30 / Performance 30 and the hard overrides from the previous
spec are unchanged.

### 3.9 Report additions

A `Trust` block, present in both JSON and HTML: platform and distribution, WSL
status, filesystem type, engine mode, whether bypass was proven, and the
queue-depth mechanism used. Per-metric `Rse`, `Slices` and `Converged` accompany
every figure. Multi-device runs gain a comparison table and record the scheduling
mode actually used.

---

## 4. File layout

```
StorageBench/
  StorageBench.ps1    EDIT      -Target/-All/-Parallel/-SelfTest; orchestration
  lib/
    Platform.ps1        NEW     detection, provider dispatch, elevation, path rules
    Target.ps1          NEW     Resolve-SbTarget, trust evaluation
    Io.ps1              NEW     embedded C# engine, aligned buffers, bypass proof
    Measure.ps1         NEW     convergence controller, phase budgets
    Schedule.ps1        NEW     controller grouping, multi-device ordering
    Core.ps1            EDIT    Get-IsAdmin moves to Platform.ps1
    Safety.ps1          EDIT    paths from the target descriptor, not a drive letter
    Bench.ps1           REWRITE delegates to Io.ps1 + Measure.ps1
    Classify.ps1        EDIT    reuses the benchmark file
    Integrity.ps1       EDIT    I/O through Io.ps1
    Surface.ps1         EDIT    I/O through Io.ps1
    Expectations.ps1    EDIT    confidence gating
    Grade.ps1           EDIT    confidence and trust caps, 'unrated'
    Ui.ps1              EDIT    multi-device panel
    Report.ps1          EDIT    Trust block, per-metric confidence
    Inventory.ps1       REWRITE facade over the provider
    Smart.ps1           REWRITE facade over the provider
    Tools.ps1           REWRITE facade over the provider
    platform/
      windows/{Inventory,Smart,Tools,Handle}.ps1    NEW
      linux/{Inventory,Smart,Tools,Handle}.ps1      NEW
  tests/
    (4 existing files, kept green)
    Platform.Tests.ps1  NEW     detection, dispatch, the no-$IsWindows grep rule
    Provider.Tests.ps1  NEW     one shared contract body, both providers, fixtures
    Io.Tests.ps1        NEW     bypass proof fails closed, alignment enforced
    Measure.Tests.ps1   NEW     convergence maths against synthetic samples
    Target.Tests.ps1    NEW     addressing forms, trust gate, refusal text
    Schedule.Tests.ps1  NEW     grouping and ordering
    fixtures/                   captured lsblk/sysfs trees and CIM objects
  tools/
    run-tests.ps1       NEW     identical entry point on Windows and Linux
```

Thirteen new library files — five modules plus eight provider files — four
rewritten, ten edited.

---

## 5. Testing strategy

The 126 existing tests are the regression net and stay green at every step. A
change that breaks one is wrong until proven otherwise.

**Provider contract tests.** One shared test body runs against both providers. The
non-native provider is driven by captured fixtures — real `lsblk -J -O` output,
real `/sys/block` trees, real serialised CIM objects — so the Linux provider is
exercised on Windows and vice versa. This is the mechanism that makes a
single-platform CI run meaningful.

**Engine tests.** The bypass proof must fail closed: given a handle opened without
the bypass flag, the engine must report `buffered-unproven` and must not emit a
performance grade. Alignment enforcement, buffer lifetime, and handle disposal are
asserted directly.

**Convergence tests.** The RSE controller is pure arithmetic over a sample vector
and is tested against synthetic series with known variance, including the
budget-exhausted path and the `BytesTouched` floor.

**Trust-gate tests.** Every refused filesystem type is refused, and the refusal
text contains the remedy — asserted on content, because a message that omits
`wsl --mount --bare` has failed at its only job.

**Cross-platform execution.** `tools/run-tests.ps1` runs the suite unchanged on
Windows and in WSL. Both are run before any push.

**`-SelfTest` mode.** Answers "is this build honest on this machine" against a
small scratch file: proves bypass, checks that the software ceiling exceeds the
measured device figure by a safe margin, and exits non-zero if not. This is the
check that would have caught both defects in §2.

---

## 6. Safety model — unchanged

Carried forward from the previous spec without modification:

- No write handle is ever opened on a raw device.
- All writes are confined to `<target>/.storagebench-scratch/<runId>/`.
- Free-space reserve is `max(2 GB, 5% of volume)`.
- Boot and system volumes are refused without `-Force`.
- No unverified binary executes: SHA-256 is pinned and matched before any fetched
  tool runs. Linux artifacts are added alongside the Windows ones (distribution
  packages for smartmontools and nvme-cli, `fio` in place of diskspd), under the
  same pinning rule.

---

## 7. Deliberately out of scope

- macOS. The provider seam makes it additive later; nothing here targets it.
- `io_uring`. The thread-pool async path reaches sufficient queue depth under
  `O_DIRECT`; adding a second Linux async mechanism is unjustified complexity.
- Raw-device benchmarking on Linux, though `O_DIRECT` on `/dev/*` would permit it.
  The no-write-handle-on-raw-device invariant is worth more than the capability.
- PowerShell 5.1. The engine requires .NET `RandomAccess` and
  `NativeMemory.AlignedAlloc`, so 7.4+ is a hard floor. 5.1 gets a clear message.
- Benchmarking through 9p/drvfs with a correction factor. §2.1 shows the errors run
  in opposite directions, so no correction factor exists.
- arm64 Linux. `O_DIRECT` is `0x4000` on x86-64 but `0x10000` on arm64; the
  constant is resolved per architecture, but only x86-64 is verified here.

---

## 8. Order of work

Sequenced so the tree is green and pushable at every boundary, and so the
highest-risk item is proven first.

1. **`lib/Io.ps1` and the bypass proof.** The engine, both handle openers, aligned
   buffers, and the misaligned-span assertion, with tests. Highest risk, so it
   goes first; everything else depends on it.
2. **`lib/Platform.ps1` and the provider seam.** Detection, dispatch, and the
   no-`$IsWindows` rule, with the existing Windows code moved behind the seam
   unchanged. The 126 tests must still pass, proving the move was mechanical.
3. **Linux providers.** Inventory, SMART and Tools against `lsblk`, `findmnt`,
   `/sys`, smartctl and nvme-cli, with fixtures captured from this machine.
4. **`lib/Target.ps1` and the trust gate.** Addressing, refusal, and the WSL
   remedy text.
5. **`lib/Measure.ps1` and phase budgets.** Convergence, then rewire `Bench.ps1`,
   `Classify.ps1`, `Integrity.ps1` and `Surface.ps1` onto it.
6. **Confidence in grading and reporting.** The gate, `unrated`, and the `Trust`
   block.
7. **`lib/Schedule.ps1` and multi-device.** `-All`, grouping, `-Parallel auto`.
8. **Documentation.** README and RUNNING.md off "Windows only"; the WSL passthrough
   procedure; revised preset timings.

Each step ends with the full suite green on Windows *and* in WSL, then a commit and
a push.

---

## 9. Open items

None blocking. Two to settle during implementation:

- The `Rse` threshold is set at 2% from judgement, not measurement. Step 5 should
  check it against real run-to-run variance on this machine's NVMe and adjust once,
  with the measured basis recorded here.
- `-Parallel auto`'s contention penalty is currently qualitative — a warning plus a
  confidence downgrade. If step 7 can measure the actual contention between two
  devices on this machine, the penalty should become quantitative.
