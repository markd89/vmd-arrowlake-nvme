# vmd-arrowlake-nvme

A patched Linux kernel module (`vmd.ko`) that makes the NVMe SSDs visible on
Intel **Arrow Lake** (Core Ultra 200 series) laptops where Intel VMD hides
them from the operating system.

Built and validated on an Acer Predator PH18-73 with two NVMe drives. It is
**not Acer-specific** — it applies to any laptop with this Intel platform
(MSI Vector 17 HX AI and Acer Predator PH16-73/PHN16-73 have been confirmed
in community testing).

> **Scope:** this repo covers the kernel module only — building it,
> installing it, and reverting it. It does not cover rescue ISOs or imaging
> tools (Clonezilla etc.), though the same module works inside them.
>
> **Support:** none is offered. This is published as-is so that others can
> reproduce the fix. Bug reports with specific, verified corrections are
> welcome and may help the next person.

---

## Does this apply to me?

Run this on the affected machine:

```bash
lspci -nn | grep -i "8086:ad0b"
```

**If you see a line like this**, VMD is present and this fix is for you:

```
00:0e.0 RAID bus controller [0104]: Intel Corporation Core Ultra 200 Series Processors VMD [8086:ad0b]
```

Then check whether your NVMe drives are hidden (the symptom this repo fixes):

```bash
lspci | grep -c "^1000[0-9]:" ; lsblk -d -o NAME,SIZE,MODEL
```

**Broken state (what you probably have):** the count is `0` — no PCI domain
starting with `1000` exists — and `lsblk` shows no `nvme0n1`/`nvme1n1`
devices, only any external/USB drives.

**Fixed state (what you want after applying this):** one or more `10000:`
PCI domains exist, each containing an NVMe controller, and `lsblk` lists
your internal drives. Real example from the validated machine:

```
10000:e2:00.0 Non-Volatile memory controller [0108]: SK hynix PCB01 NVMe Solid State Drive
10000:e3:00.0 Non-Volatile memory controller [0108]: SK hynix Platinum P41/PC801 NVMe Solid State Drive
```

**If `8086:ad0b` did not appear**, your machine either has no VMD or uses a
different Intel VMD device ID. This repo's module is built for the
Core Ultra 200 series device ID (`0xad0b`); other generations need the
matching upstream kernel, not this patch set.

## What the fix is (30 seconds)

Three things, layered:

1. **Arrow Lake bus enumeration** (`busn_start = 224`) — already upstream in
   kernels ≥ 6.16-ish (7.3-rc1): tells the VMD driver where Arrow Lake puts
   its root bus.
2. **ARL004 interrupt quirk** — already upstream (commit `2c88c2dc1852`):
   flushes DMA writes before handling MSI on Arrow Lake VMD.
3. **Second Root Bus support (v10 series, 7 patches)** — *not yet upstream*
   at the time of writing: Arrow Lake VMD exposes a **second root bus
   (BUS1)**, and the in-tree driver only creates the first. This patch
   series teaches the driver to enumerate both, with BUS1 getting its own
   emulated PCI domain. On machines like the validated Predator PH18-73,
   the NVMe controllers sit behind **both** buses — without this series,
   some drives stay invisible even with 1+2.

The module is built from the Linux 7.4-rc1 `vmd.c` plus those 7 patches and
one small local compatibility patch. Full detail: [docs/how-it-works.md](docs/how-it-works.md).

## Quick start

Prerequisites (Debian/Ubuntu family):

```bash
sudo apt-get install -y build-essential patch xz-utils linux-headers-$(uname -r)
```

Expected result: the install completes without errors. If
`linux-headers-$(uname -r)` "has no installation candidate", your kernel is
not from your distro's repos — install the matching headers for the kernel
you boot (e.g. backports kernels need backports headers).

Build and install:

```bash
sudo ./build-vmd.sh
```

What you should see, in order — each is a gate; the script stops if any fail:

```
OK preflight
OK patches: 8 applied cleanly
OK build: built/vmd-<your-kernel>/drivers/pci/controller/vmd.ko
  vermagic  : <your-kernel> SMP preempt mod_unload
OK backup: backups/<your-kernel>/<timestamp>/vmd.stock.ko.xz
OK installed: /lib/modules/<your-kernel>/updates/drivers/pci/controller/vmd.ko.xz
OK verify: modinfo -n vmd -> /lib/modules/<your-kernel>/updates/...
DONE. Reboot to load the patched module.
```

**Common failure and what it means:** `FAIL: make failed` with lines like
`ERROR: Module "vmd" not found` or `unknown symbol msi_create_parent_irq_domain`
in `built/vmd-<kver>/build.log` — your kernel is older than the v10 series
requires. See [docs/troubleshooting.md](docs/troubleshooting.md) for the
case-3-only fallback.

Then **reboot**, and verify:

```bash
lspci | grep "^1000[0-9]:"
```

Expected: at least one line (your NVMe controllers now live in a `10000:`+ domain). Then:

```bash
lsblk -d -o NAME,SIZE,MODEL
```

Expected: your internal NVMe drives are listed.

To undo the installation at any time:

```bash
sudo ./revert-vmd.sh
```

## Alternative: DKMS (auto-rebuild on kernel updates)

The standalone script above must be re-run after every kernel update. If you
prefer the module to rebuild automatically, use the DKMS route instead:
see [dkms/INSTALL-DKMS.md](dkms/INSTALL-DKMS.md). Pick one route — running
both is harmless (DKMS and the script install to the same path) but
confusing.

## Validated on

| Machine | Drives found | Kernel | Result | Evidence |
|---|---|---|---|---|
| Acer Predator PH18-73 (Core Ultra 9 285HX, BIOS V1.09) | 2× NVMe (SK hynix PCB01 + Platinum P41/PC801), both behind VMD, one on each root bus | Debian 13 `7.2.12+deb13-amd64` | both drives visible in PCI domain `10000:`, stable under load | captured 2026-11-16 |
| MSI Vector 17 HX AI; Acer Predator PH16-73 / PHN16-73-class | single NVMe | Ubuntu kernels (via [gvozd188/vmd-arl004](https://github.com/gvozd188/vmd-arl004), which this repo's approach follows) | drive visible | community validation |

**Known gaps in validation:** the two-bus machines (drives on *both* BUS0
and BUS1) are the newest wrinkle — that is exactly what the v10 series adds,
and the Predator PH18-73 is the primary proof. Single-NVMe machines are the
better-trodden path. RAID-on-CPU (VMD on ADL/Raptor Lake generations,
different device IDs) is out of scope.

## Credits — the people who wrote the code

This repo exists to distribute **their** work in a buildable form.

- **Szymon Durawa** (`szymon.durawa@linux.intel.com`, Intel) — author of the
  Second Root Bus v10 patch series (`patches/0001`–`0007`, kept verbatim,
  including his `Signed-off-by`).
  Source thread: <https://patchew.org/linux/20261106184256.4130-1-szymon.durawa@linux.intel.com/>
- **Nirmal Patel** (Intel) — `Suggested-by` on the series.
- **Asutosh Pathak** (Intel) — `Reviewed-by` on the series.
- Upstream kernel contributors — the Arrow Lake bus enumeration and the
  ARL004 interrupt quirk (patches 1 and 2 of the stack) are already in the
  mainline kernel; this repo merely builds on the 7.4-rc1 state of `vmd.c`.
- **gvozd188** — [vmd-arl004](https://github.com/gvozd188/vmd-arl004), the
  earlier community repo for single-NVMe Ubuntu machines, whose documented
  header-shim workaround this repo also uses (`patches/0008`).
- Build/installation scripts and packaging for this repo: prepared from a
  working installation on the Predator PH18-73 (see the git history).

## License

GPL-2.0 — the module derives from Linux kernel source
(`drivers/pci/controller/vmd.c`), so the whole repo is distributed under the
GNU General Public License version 2, provided here verbatim in [LICENSE](LICENSE).
