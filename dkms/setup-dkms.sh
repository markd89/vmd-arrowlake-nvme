#!/usr/bin/env bash
# setup-dkms.sh — assemble /usr/src/vmd-arrowlake-0.7 from this repo's src/
# so that `dkms add/build/install` can run (see INSTALL-DKMS.md).
#
# v1.0 | 2026-11-18 16:05 | B (sandbox agent)
# Initial version: assembles the DKMS source tree, verifies layout, registers.
#
# Usage:  sudo ./setup-dkms.sh
# Exit codes: 0 ok | 1 preflight/verify fail | 2 registration fail
set -euo pipefail

PKG_NAME="vmd-arrowlake"
PKG_VER="0.7"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${REPO_DIR}/src"
DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VER}"

if [[ $EUID -ne 0 ]]; then
    echo "FAIL: needs root (writes /usr/src). Re-run with sudo."; exit 1
fi
command -v dkms >/dev/null 2>&1 || { echo "FAIL: dkms not installed:  sudo apt-get install -y dkms"; exit 1; }
if [[ ! -f "${SRC_DIR}/vmd.c" ]]; then echo "FAIL: ${SRC_DIR}/vmd.c missing"; exit 1; fi

echo "==> Assembling ${DKMS_SRC}"
rm -rf "${DKMS_SRC}"
mkdir -p "${DKMS_SRC}/drivers/pci/controller"
cp "${SRC_DIR}/vmd.c" "${DKMS_SRC}/drivers/pci/controller/vmd.c"
cp "${SRC_DIR}"/[0-9]*.patch "${DKMS_SRC}/"
cp "${REPO_DIR}/dkms/dkms.conf" "${DKMS_SRC}/dkms.conf"
echo "obj-m += vmd.o" > "${DKMS_SRC}/drivers/pci/controller/Makefile"

# verify layout before registering (read-back, never claim)
for f in drivers/pci/controller/vmd.c drivers/pci/controller/Makefile dkms.conf; do
    [[ -s "${DKMS_SRC}/${f}" ]] || { echo "FAIL: assembled tree missing ${f}"; exit 1; }
done
NPATCHES=$(ls "${DKMS_SRC}"/[0-9]*.patch | wc -l)
[[ "${NPATCHES}" -eq 8 ]] || { echo "FAIL: expected 8 patches, found ${NPATCHES}"; exit 1; }

echo "==> Registering with DKMS"
if dkms status -m "${PKG_NAME}" | grep -q "added\|installed"; then
    dkms remove -m "${PKG_NAME}" -v "${PKG_VER}" --all >/dev/null
fi
dkms add -m "${PKG_NAME}" -v "${PKG_VER}"
echo
echo "DONE. Source registered at ${DKMS_SRC}"
echo "Next (see INSTALL-DKMS.md):"
echo "  sudo dkms build -m ${PKG_NAME} -v ${PKG_VER} -k \$(uname -r)"
echo "  sudo dkms install -m ${PKG_NAME} -v ${PKG_VER} -k \$(uname -r)"
