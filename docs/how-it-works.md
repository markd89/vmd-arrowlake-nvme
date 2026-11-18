# How it works

This is the plain-language version. For the authoritative detail, read the
patches themselves (`src/0001`–`0008`) — they are short and well-commented.

## The problem

On Intel Arrow Lake (Core Ultra 200 series) laptops with **VMD enabled in
BIOS**, the NVMe controllers are not attached to the normal PCI root
complex. Instead they hang behind a *Volume Management Device* — a PCI
device (`8086:ad0b`) that owns its own PCI domains and buses. The OS only
sees drives if the `vmd` kernel driver enumerates the buses **behind** the
VMD device correctly.

Two things go wrong on these machines:

1. **The bus numbers changed.** Arrow Lake VMD puts its first root bus at
   a different offset than previous generations. An in-tree driver that
   guesses the old offset enumerates nothing.
2. **There is a second root bus.** Starting with Arrow Lake, VMD reports a
   *bus restriction* value of 3, which means: there are TWO root buses
   (BUS0 and BUS1), each with its own set of root ports. The in-tree driver
   was written for a single bus — it creates BUS0, and everything behind
   BUS1 is invisible. On the validated Acer Predator PH18-73, the two NVMe
   drives sit **one per bus**, so a single-bus driver finds exactly one (or
   zero, combined with problem 1).

## The fix stack (three layers)

The module in this repo is built from the Linux **7.4-rc1** `vmd.c`, which
already contains layer 1 and 2, plus the 7-patch series for layer 3:

| Layer | What | Status |
|---|---|---|
| 1 | Arrow Lake bus enumeration: `case 3 → busn_start = 224` | in mainline since 7.3-rc1 |
| 2 | ARL004 quirk: `VMD_FEAT_INTERRUPT_QUIRK` on device `0xad0b` — flush DMA writes before handling MSI | in mainline (commit `2c88c2dc1852`) |
| 3 | Second Root Bus v10 series (7 patches by Szymon Durawa): BUS1 enumeration, resource partitioning between BUS0/BUS1, emulated PCI domain for BUS1, PCI_PRIMARY_BUS read emulation for BUS1 root ports | **not yet upstream** at the time of writing — this is what the repo exists to distribute |

Layer 3 is where all the new code is: ~592 lines added, ~135 removed, all
inside `drivers/pci/controller/vmd.c`. Patches 1–6 are refactors that move
code into helpers (no functional change); patch 7 is the functional change
that creates BUS1.

## The local compatibility patch (0008)

Debian 13's 7.2.12 kernel headers (and Ubuntu 7.0's) predate the addition
of the `PCI_DEVICE_ID_INTEL_VMD_28C1` constant that the 7.4-rc1 `vmd.c`
uses. Patch 0008 defines it numerically behind `#ifndef`, so it is a no-op
on kernels whose headers already have it. This same workaround was needed
by other community builds (documented in gvozd188/vmd-arl004 for Ubuntu).

## Why one module covers different machines

- **Drives on BUS0 only** (many single-NVMe machines): layers 1+2 alone may
  be enough — a stock 7.4+ kernel might already see the drive. The v10
  series does not change that path.
- **Drives on BUS1** (validated Predator PH18-73 has one drive there): only
  layer 3 makes them visible.
- **Drives on both**: needs all three layers.

## What "domain 10000:" means

A PCI *domain* is a numbering space that lets a system have more than 256
buses. VMD creates emulated domains for its buses; with BUS1 support you
can see two of them (`10000:`, `10001:`, …) in `lspci` output. The domains
are a bookkeeping construct — the drives behind them are ordinary NVMe
devices (`/dev/nvme0n1`, …) once enumerated. Nothing about your data layout
changes: VMD here is not RAID (the validated machine's drives are
independent despite the "RAID bus controller" class code in `lspci`).
