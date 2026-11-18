# DKMS install — auto-rebuild on kernel updates

DKMS rebuilds the module automatically every time a kernel update brings
new headers. Use this INSTEAD of the standalone `build-vmd.sh` route (the
two install to the same place; running both is harmless but confusing).

Prerequisites:

```bash
sudo apt-get install -y dkms build-essential patch xz-utils linux-headers-$(uname -r)
```

Expected: installs with no errors. If `dkms` "has no installation
candidate", enable the `contrib`/`non-free` areas or your distro's
equivalent — on Debian, `dkms` is in `main`, so a missing candidate means
restricted apt sources.

## Steps

Run from the repo root (the folder containing this `dkms/` folder).

**1. Assemble and register the source tree:**

```bash
sudo ./dkms/setup-dkms.sh
```

What you should see (failure at any gate stops the script):

```
==> Assembling /usr/src/vmd-arrowlake-0.7
==> Registering with DKMS
DONE. Source registered at /usr/src/vmd-arrowlake-0.7
Next (see INSTALL-DKMS.md):
  sudo dkms build -m vmd-arrowlake -v 0.7 -k $(uname -r)
  ...
```

**2. Build for your running kernel:**

```bash
sudo dkms build -m vmd-arrowlake -v 0.7 -k "$(uname -r)"
```

Expected tail of output:

```
...
  DKMS: build completed.
```

**Failure mode:** `Your kernel headers for kernel X.Y.Z cannot be found`
— install `linux-headers-$(uname -r)`. **Unknown-symbol warnings** during
compile mean your kernel is older than the v10 series needs — see
[../docs/troubleshooting.md](../docs/troubleshooting.md).

**3. Install the module and regenerate module dependencies:**

```bash
sudo dkms install -m vmd-arrowlake -v 0.7 -k "$(uname -r)"
```

Expected tail:

```
...
  DKMS: install completed.
```

**4. Update the initramfs** (DKMS does not do this step):

```bash
sudo update-initramfs -u -k "$(uname -r)"
```

Expected: a few lines ending with `update-initramfs: ...`.

**5. Reboot, then verify:**

```bash
modinfo -n vmd
```

Expected: `/lib/modules/.../updates/drivers/pci/controller/vmd.ko` (or
`.ko.xz`), i.e. the DKMS-installed copy, not the stock path. Then:

```bash
lspci | grep "^1000[0-9]:"
```

Expected: your NVMe controllers in a `10000:`-prefixed domain.

## Uninstall

```bash
sudo dkms remove -m vmd-arrowlake -v 0.7 --all
sudo update-initramfs -u -k all
```

DKMS restores the stock module automatically on remove; after the
initramfs update and a reboot the stock `vmd` driver is back.

## Notes

- On future kernel updates, DKMS rebuilds automatically (that is the point
  of this route). If a future kernel lacks symbols the series needs, the
  DKMS build fails for that kernel and the old kernel keeps working —
  check `dkms status`.
- The source tree lives at `/usr/src/vmd-arrowlake-0.7/`; re-run
  `sudo ./dkms/setup-dkms.sh` after pulling updated patches.
