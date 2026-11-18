# Troubleshooting

## Build failures

### `FAIL: make failed` — unknown symbols

Look at `built/vmd-<kver>/build.log`. If you see errors like:

```
ERROR: Module "vmd" not found in ...
WARNING: "msi_create_parent_irq_domain" [...] undefined!
WARNING: "pci_bus_find_emul_domain_nr" [...] undefined!
WARNING: "pci_enable_link_state_locked" [...] undefined!
WARNING: "handle_untracked_irq" [...]
```

**Meaning:** your kernel is older than the v10 series requires. The series
uses helper functions that were only exported in recent kernels (6.15+,
roughly; Debian 7.2.12 and Ubuntu 7.0-era kernels have them).

**Fix:** use a newer kernel, or fall back to the case-3-only build (below).

### `FAIL: patch did not apply cleanly: ...`

The source in `src/` is fixed; the patches apply to it deterministically.
This failure means the files in `src/` were modified. Re-clone or restore
the repo and do not edit `src/vmd.c` — the patches are the intended way to
change the source.

### `FAIL: kernel build directory /lib/modules/<kver>/build not found`

Kernel headers for the **running** kernel are not installed.

```bash
sudo apt-get install -y linux-headers-$(uname -r)
```

If apt cannot find them, your running kernel is not from your distro's
repos (e.g. a backports or custom kernel) — install the headers package
that matches it exactly.

## After install / reboot

### NVMe drives still missing

1. Confirm the patched module actually loaded:
   ```bash
   modinfo -n vmd          # must print .../updates/drivers/pci/controller/vmd.ko.xz
   dmesg | grep -i vmd
   ```
   If `modinfo -n` does not show `updates/`, the module was not replaced —
   re-run `sudo ./build-vmd.sh` and read its output carefully.

2. Confirm VMD bound:
   ```bash
   lspci -k -d 8086:ad0b   # "Kernel driver in use: vmd" must appear
   ```

3. Check the new domains exist:
   ```bash
   lspci | grep "^1000[0-9]:"
   ```
   - **Bus 0 devices only, one drive missing** → the machine's second drive
     is behind BUS1; make sure you built with the full 8-patch stack (the
     `OK patches: 8 applied cleanly` line), not a case-3-only fallback.
   - **Nothing at all** → VMD bound but enumerates nothing; see the next
     section.

4. If VMD is bound but no domain appears, capture diagnostics before
   asking anyone anything:
   ```bash
   sudo dmesg | grep -iE "vmd|nvme" > vmd-diagnostics.txt
   sudo lspci -nn -vv > lspci-full.txt
   ```

### Machine won't boot after install

Boot the previous kernel from the GRUB menu (Advanced options), then:

```bash
sudo ./revert-vmd.sh        # restores the stock module from backups/
sudo update-initramfs -u -k all
reboot
```

The stock module is always in `backups/<kver>/<timestamp>/` — the install
script refuses to touch anything until that backup has been verified on
disk.

### VMD bound but `dmesg` shows interrupt-related errors on Arrow Lake

Make sure the ARL004 quirk is in the build: `grep -c INTERRUPT_QUIRK
built/vmd-<kver>/drivers/pci/controller/vmd.c` must be ≥ 1. If 0, the
build used a pre-7.4-rc1 base — re-clone.

## The case-3-only fallback (older kernels)

If your kernel cannot host the v10 series (missing-symbol errors above),
you can build a **partial** fix that handles layer 1 (Arrow Lake bus
enumeration) only. It makes single-NVMe-on-BUS0 machines work; BUS1 drives
stay hidden.

This repo does not ship the fallback patch. The change is a one-line
edit of `src/vmd.c`'s `vmd_bus_enumeration()`-related switch (documented in
the upstream thread linked in README Credits) — but only attempt it if you
understand what you are changing; the script in this repo builds the full
stack only.
