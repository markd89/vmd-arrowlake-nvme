#!/usr/bin/env bash
# install-binary.sh — install the PREBUILT patched VMD module (binary/) for
# Intel Arrow Lake (Core Ultra 200) laptops where VMD hides the NVMe drives.
#
# v1.0 | 2026-11-18 16:05 | B (sandbox agent)
# Initial version: sha256 → kernel-match → vermagic → backup-first install →
# depmod/initramfs → modprobe --dry-run kABI gate → verify. Any gate failure
# = nothing modified; fall back to the build route (../build-vmd.sh).
#
# The prebuilt module targets EXACTLY this kernel:
#   7.2.12+deb13-amd64  (Debian 13, backports kernel 7.2.12)
# On any other kernel the loader would refuse the module anyway; this script
# checks first so you learn it in seconds instead of after a reboot.
#
# Usage:
#   sudo ./install-binary.sh             verify + install
#   ./install-binary.sh --check          gates only, change nothing
#   ./install-binary.sh --help
#
# Exit codes: 0 ok | 1 preflight/gate fail | 2 backup fail | 3 verify fail
# Reboot required to load the patched module.
set -euo pipefail

KVER="$(uname -r)"
EXPECTED_KVER="7.2.12+deb13-amd64"
CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --help|-h) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_DIR}/binary"
KO="${BIN_DIR}/vmd-7.2.12-v10.ko"
SHA="${KO}.sha256"
BACKUP_ROOT="${REPO_DIR}/backups"

tool() { command -v "$1" 2>/dev/null || { for d in /usr/sbin /usr/bin /sbin /bin; do [ -x "$d/$1" ] && { echo "$d/$1"; return; }; done; echo ""; }; }
MODINFO="$(tool modinfo)"
DEPMOD="$(tool depmod)"
UPDATE_INITRAMFS="$(tool update-initramfs)"
LSINITRAMFS="$(tool lsinitramfs)"
MODPROBE="$(tool modprobe)"

echo "==> vmd-arrowlake-nvme binary install"
echo "    module   : ${KO}"
echo "    requires : kernel ${EXPECTED_KVER}"

# ---------- gate 1: artifact integrity ----------
if [[ ! -f "${KO}" ]]; then echo "FAIL: ${KO} missing — incomplete checkout?"; exit 1; fi
(cd "${BIN_DIR}" && sha256sum -c "$(basename "${SHA}")") || {
    echo "FAIL: sha256 mismatch — the downloaded .ko is corrupt or tampered with."
    echo "      Re-download the repo, or better: build from source (../build-vmd.sh)."
    exit 1
}
echo "OK gate 1: sha256 matches (${KO})"

# ---------- gate 2: running kernel is the one this module targets ----------
if [[ "${KVER}" != "${EXPECTED_KVER}" ]]; then
    echo "FAIL: this prebuilt module targets kernel ${EXPECTED_KVER} only;"
    echo "      you are running ${KVER}."
    echo "      Build from source instead:  sudo ${REPO_DIR}/build-vmd.sh"
    echo "      (it produces the same patched module for YOUR kernel)"
    exit 1
fi
echo "OK gate 2: running kernel matches (${KVER})"

# ---------- gate 3: vermagic identity ----------
VERMAGIC_KO=$("${MODINFO}" "${KO}" | sed -n 's/^vermagic:[[:space:]]*//p')
if [[ "${VERMAGIC_KO}" != "${KVER} SMP preempt mod_unload "* ]]; then
    echo "FAIL: vermagic mismatch: ko='${VERMAGIC_KO}' kernel='${KVER}'"
    exit 1
fi
echo "OK gate 3: vermagic matches"

# ---------- gates 4+: install phase (nothing below runs with --check) ----------
if [[ ${CHECK_ONLY} -eq 1 ]]; then
    echo
    echo "CHECK ONLY: all gates pass. Nothing was modified."
    echo "Install with:  sudo ./install-binary.sh"
    exit 0
fi
if [[ $EUID -ne 0 ]]; then
    echo "FAIL: install needs root (writes /lib/modules + initramfs). Re-run with sudo."; exit 1
fi
for t in "${MODINFO}" "${DEPMOD}" "${UPDATE_INITRAMFS}" "${LSINITRAMFS}" "${MODPROBE}"; do
    if [[ -z "${t}" || ! -x "${t}" ]]; then
        echo "FAIL: required tool not found (searched PATH + /usr/{s}bin): modinfo depmod update-initramfs lsinitramfs modprobe"; exit 1
    fi
done

# ---------- backup stock module FIRST (verify by reading back) ----------
STOCK=$("${MODINFO}" -n vmd 2>/dev/null || true)
if [[ -z "${STOCK}" ]]; then
    echo "FAIL: no stock vmd module found via modinfo — is VMD support enabled in this kernel?"; exit 1
fi
TS=$(date +%Y%m%d-%H%M%S)
BK="${BACKUP_ROOT}/${KVER}/binary-${TS}"
mkdir -p "${BK}"
if [[ "${STOCK}" == *.xz ]]; then
    cp "${STOCK}" "${BK}/vmd.stock.ko.xz"
else
    cp "${STOCK}" "${BK}/vmd.stock.ko"
fi
cp /lib/modules/"${KVER}"/modules.dep "${BK}/modules.dep" 2>/dev/null || true
cp "/boot/initrd.img-${KVER}" "${BK}/initrd.img" 2>/dev/null || true
sync
BK_FILE=$(ls "${BK}"/vmd.stock.ko* 2>/dev/null | head -1)
if [[ -z "${BK_FILE}" ]] || [[ ! -s "${BK_FILE}" ]]; then
    echo "FAIL: stock module backup missing or empty at ${BK} — nothing was modified."; exit 2
fi
if [[ "${BK_FILE}" == *.xz ]] && ! xz -t "${BK_FILE}" 2>/dev/null; then
    echo "FAIL: backed-up stock module fails xz integrity — nothing was modified."; exit 2
fi
echo "OK backup: ${BK_FILE}"

# ---------- install ----------
DEST="/lib/modules/${KVER}/updates/drivers/pci/controller"
mkdir -p "${DEST}"
if [[ "${STOCK}" == *.xz ]]; then
    xz -C crc32 -c "${KO}" > "${DEST}/vmd.ko.xz"
else
    cp "${KO}" "${DEST}/vmd.ko"
fi
INSTALLED=$(ls "${DEST}"/vmd.ko* 2>/dev/null | head -1)
if [[ -z "${INSTALLED}" || ! -s "${INSTALLED}" ]]; then
    echo "FAIL: install file missing/empty at ${DEST}"; exit 3
fi
echo "OK installed: ${INSTALLED}"

"${DEPMOD}" -a "${KVER}"
"${UPDATE_INITRAMFS}" -u -k "${KVER}"

# ---------- kABI gate: does the module RESOLVE against this exact kernel? ----------
# vermagic equality is not enough (a Debian point update can keep the string
# while changing symbols). modprobe --dry-run does full dependency resolution
# without loading anything.
if ! "${MODPROBE}" --dry-run vmd 2>/dev/null; then
    echo "FAIL: modprobe --dry-run vmd failed — the module does not resolve cleanly"
    echo "      against this kernel (likely a point update kept the vermagic string"
    echo "      but changed the kABI). NOTHING IS BROKEN — the previous module"
    echo "      stays in place only if you now restore it:"
    echo "        sudo cp \"${BK_FILE}\" /lib/modules/${KVER}/updates/drivers/pci/controller/$(basename "${INSTALLED}")"
    echo "        sudo depmod -a ${KVER} && sudo update-initramfs -u -k ${KVER}"
    echo "      Or simply build from source for this exact kernel:"
    echo "        sudo ${REPO_DIR}/build-vmd.sh"
    exit 3
fi
echo "OK kABI gate: modprobe --dry-run vmd resolves"

# ---------- verify ----------
RESOLVED=$("${MODINFO}" -n vmd)
if [[ "${RESOLVED}" != "${DEST}"* ]]; then
    echo "FAIL: modinfo resolves vmd to '${RESOLVED}' — updates/ override did not take effect"; exit 3
fi
if "${LSINITRAMFS}" "/boot/initrd.img-${KVER}" | grep -q "pci/controller/vmd"; then :; else
    echo "FAIL: patched vmd not present in initramfs"; exit 3
fi
SRCVER_KO=$("${MODINFO}" "${KO}" | sed -n 's/^srcversion:[[:space:]]*//p')
SRCVER_INST=$("${MODINFO}" -n vmd | xargs "${MODINFO}" 2>/dev/null | sed -n 's/^srcversion:[[:space:]]*//p')
if [[ "${SRCVER_INST}" != "${SRCVER_KO}" ]]; then
    echo "FAIL: installed srcversion '${SRCVER_INST}' != expected '${SRCVER_KO}'"; exit 3
fi
echo "OK verify: modinfo -n vmd -> ${RESOLVED} (srcversion ${SRCVER_INST})"
echo
echo "DONE. Reboot to load the patched module."
echo "After reboot, check:"
echo "  lspci | grep '^1000[0-9]:'      <- NVMe controllers in a 10000:+ domain"
echo "  lsblk -d -o NAME,SIZE,MODEL     <- your NVMe drives listed"
echo "Revert: sudo ${REPO_DIR}/revert-vmd.sh"
