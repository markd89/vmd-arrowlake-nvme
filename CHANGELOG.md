# Changelog

## [0.7.0] — 2026-11-18

Initial public release of the repo packaging.

### Added
- `src/vmd.c` — pristine Linux 7.4-rc1 VMD controller driver (byte-verified
  reconstruction: applying the full patch stack reproduces the exact source
  of the validated `vmd-7.2.12-v10.ko` build).
- `src/0001..0007` — Second Root Bus v10 series by Szymon Durawa (Intel),
  verbatim, applied on top of 7.4-rc1.
- `src/0008` — local compat shim: `PCI_DEVICE_ID_INTEL_VMD_28C1` for kernels
  whose headers predate the constant (Debian 13 / Ubuntu 7.0-era).
- `build-vmd.sh` — gated build + install: preflight, 8-patch gate, vermagic
  gate, backup-first install, depmod + initramfs, verify-at-end. Exit codes
  0/1/2/3/4 documented in the header.
- `revert-vmd.sh` — restores the stock module from the verified backup;
  snapshots the patched module before restoring.
- `dkms/` — DKMS route (auto-rebuild on kernel updates): `dkms.conf`,
  `setup-dkms.sh`, end-user instructions.
- `docs/how-it-works.md`, `docs/troubleshooting.md`.
- Validated-on table: Acer Predator PH18-73, 2× NVMe visible in domain
  `10000:` on Debian 13 kernel 7.2.12+deb13-amd64 (evidence 2026-11-16);
  community validation of the same series on MSI/Acer single-NVMe machines
  via gvozd188/vmd-arl004.
