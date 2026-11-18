#!/usr/bin/env bash
# build-vmd.sh — build and (optionally) install the patched VMD module for
# Intel Arrow Lake (Core Ultra 200) laptops where VMD hides the NVMe drives.
#
# v1.0 | 2026-11-18 15:55 | B (sandbox agent)
# Initial version: build phase (base + 8 patches, each gated) + install phase
# (root/vermagic gates, backup-first, depmod, initramfs, verify). Fail paths
# executed before handover; see git history for the validation record.
#
# Usage:
#   sudo ./build-vmd.sh                 build for the running kernel AND install
#   ./build-vmd.sh --build-only         build only (no root needed)
#   ./build-vmd.sh --kver=X.Y.Z         build against another installed kernel
#   ./build-vmd.sh --help
#
# What it does:
#   1. Preflight: source tree + patches present, toolchain present,
#      kernel build dir (/lib/modules/$KVER/build) present.
#   2. Build: copy pristine vmd.c, apply patches 0001..0008 (abort on ANY
#      patch failure), compile out-of-tree module into built/vmd-<kver>/.
#   3. Install (skipped with --build-only): requires root. Verifies the built
#      module's vermagic matches the target kernel, BACKS UP the stock vmd
#      module first (backups/<timestamp>/), installs to
#      /lib/modules/$KVER/updates/, runs depmod + update-initramfs, verifies
#      modinfo resolution, srcversion, and initramfs contents.
#
# Exit codes: 0 ok | 1 preflight fail | 2 backup fail | 3 build fail | 4 verify fail
# Reboot required after install to load the patched module.
set -euo pipefail

# ---------- argument handling ----------
KVER="$(uname -r)"
BUILD_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --build-only|--no-install) BUILD_ONLY=1 ;;
        --kver=*) KVER="${arg#--kver=}" ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

# ---------- locate repo (works from any cwd) ----------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/src"
BUILD_ROOT="$REPO_DIR/built"
BACKUP_ROOT="$REPO_DIR/backups"

echo "==> vmd-arrowlake-nvme build script"
echo "    target kernel: ${KVER}"
echo "    repo         : ${REPO_DIR}"

# ---------- tool resolution (sbin vs bin varies by distro) ----------
tool() { command -v "$1" 2>/dev/null || { for d in /usr/sbin /usr/bin /sbin /bin; do [ -x "$d/$1" ] && { echo "$d/$1"; return; }; done; echo ""; }; }
MODINFO="$(tool modinfo)"
DEPMOD="$(tool depmod)"
UPDATE_INITRAMFS="$(tool update-initramfs)"
LSINITRAMFS="$(tool lsinitramfs)"

# ---------- 1. preflight ----------
if [[ ${BUILD_ONLY} -eq 0 && $EUID -ne 0 ]]; then
    echo "FAIL: install phase needs root (writes /lib/modules + initramfs)."
    echo "      Re-run as:  sudo ./build-vmd.sh    (or --build-only to skip install)"
    exit 1
fi
if [[ ! -f "${SRC_DIR}/vmd.c" ]]; then
    echo "FAIL: ${SRC_DIR}/vmd.c missing — incomplete checkout?"; exit 1
fi
shopt -s nullglob
PATCHES=( "${SRC_DIR}"/[0-9]*.patch )
shopt -u nullglob
if [[ ${#PATCHES[@]} -lt 8 ]]; then
    echo "FAIL: expected 8 patches in ${SRC_DIR}, found ${#PATCHES[@]}:"; exit 1
fi
for t in make gcc patch xz; do
    if [[ -z "$(tool "$t")" ]]; then
        echo "FAIL: required build tool '${t}' not found. Install build-essential, patch, xz-utils."; exit 1
    fi
done
KBUILD="/lib/modules/${KVER}/build"
if [[ ! -d "${KBUILD}" ]]; then
    echo "FAIL: kernel build directory ${KBUILD} not found."
    echo "      Install the headers for ${KVER} first, e.g.:"
    echo "        Debian/Ubuntu:  sudo apt-get install linux-headers-${KVER}"
    exit 1
fi
if [[ ${BUILD_ONLY} -eq 0 ]]; then
    for t in "${MODINFO}" "${DEPMOD}" "${UPDATE_INITRAMFS}" "${LSINITRAMFS}"; do
        if [[ -z "${t}" || ! -x "${t}" ]]; then
            echo "FAIL: required tool not found (searched PATH + /usr/{s}bin): modinfo depmod update-initramfs lsinitramfs"; exit 1
        fi
    done
fi
echo "OK preflight"

# ---------- 2. build ----------
WORK="${BUILD_ROOT}/vmd-${KVER}"
echo "==> Building in ${WORK} ..."
rm -rf "${WORK}"
mkdir -p "${WORK}/drivers/pci/controller"
cp "${SRC_DIR}/vmd.c" "${WORK}/drivers/pci/controller/vmd.c"

cd "${WORK}"
for p in "${PATCHES[@]}"; do
    if ! patch -s --no-backup-if-mismatch -F1 -p1 -i "$p"; then
        echo "FAIL: patch did not apply cleanly: $p"
        echo "      The source tree in ${WORK} is left for inspection."
        exit 3
    fi
done
echo "OK patches: ${#PATCHES[@]} applied cleanly"

echo "obj-m += vmd.o" > drivers/pci/controller/Makefile
if ! make -C "${KBUILD}" M="${WORK}/drivers/pci/controller" modules > "${WORK}/build.log" 2>&1; then
    echo "FAIL: make failed — full log: ${WORK}/build.log"
    echo "      Last 15 lines:"
    tail -15 "${WORK}/build.log" | sed 's/^/        /'
    echo "      (If the log shows missing symbols like msi_create_parent_irq_domain,"
    echo "       your kernel is older than the v10 series needs — see docs/troubleshooting.md)"
    exit 3
fi

KO="${WORK}/drivers/pci/controller/vmd.ko"
if [[ ! -s "${KO}" ]]; then
    echo "FAIL: build reported success but ${KO} is missing/empty"; exit 3
fi
VERMAGIC_KO=$("${MODINFO}" "${KO}" | sed -n 's/^vermagic:[[:space:]]*//p')
if [[ "${VERMAGIC_KO}" != "${KVER} "* ]]; then
    echo "FAIL: vermagic mismatch — module targets '${VERMAGIC_KO}', running kernel is '${KVER}'"
    exit 3
fi
SRCVER_KO=$("${MODINFO}" "${KO}" | sed -n 's/^srcversion:[[:space:]]*//p')
echo "OK build: ${KO}"
echo "  vermagic  : ${VERMAGIC_KO}"
echo "  srcversion: ${SRCVER_KO}"

if [[ ${BUILD_ONLY} -eq 1 ]]; then
    echo
    echo "DONE (--build-only). Module at: ${KO}"
    echo "Install later with:  sudo ./build-vmd.sh --kver=${KVER}   (rebuilds, then installs)"
    exit 0
fi

# ---------- 3. install: backup FIRST (verify by reading back) ----------
STOCK=$("${MODINFO}" -n vmd 2>/dev/null || true)
if [[ -z "${STOCK}" ]]; then
    echo "FAIL: no stock vmd module found via modinfo — is VMD support enabled in this kernel?"
    exit 1
fi
TS=$(date +%Y%m%d-%H%M%S)
BK="${BACKUP_ROOT}/${KVER}/${TS}"
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
    echo "FAIL: install file missing/empty at ${DEST}"; exit 4
fi
echo "OK installed: ${INSTALLED}"

"${DEPMOD}" -a "${KVER}"
"${UPDATE_INITRAMFS}" -u -k "${KVER}"

# ---------- verify ----------
RESOLVED=$("${MODINFO}" -n vmd)
if [[ "${RESOLVED}" != "${DEST}"* ]]; then
    echo "FAIL: modinfo resolves vmd to '${RESOLVED}' — updates/ override did not take effect."
    echo "      A stock copy may be shadowing it; see revert-vmd.sh and docs/troubleshooting.md"
    exit 4
fi
if "${LSINITRAMFS}" "/boot/initrd.img-${KVER}" | grep -q "pci/controller/vmd"; then :; else
    echo "FAIL: patched vmd not present in initramfs"; exit 4
fi
SRCVER_INST=$("${MODINFO}" -n vmd | xargs "${MODINFO}" 2>/dev/null | sed -n 's/^srcversion:[[:space:]]*//p')
if [[ "${SRCVER_INST}" != "${SRCVER_KO}" ]]; then
    echo "FAIL: installed srcversion '${SRCVER_INST}' != built '${SRCVER_KO}'"; exit 4
fi
echo "OK verify: modinfo -n vmd -> ${RESOLVED}"
echo
echo "DONE. Reboot to load the patched module."
echo "After reboot, check:"
echo "  sudo lspci -d 8086:ad0b -vv | grep -i 'kernel driver'"
echo "  lspci | grep '^1000[0-9]:'        <- NVMe controllers should appear in a 10000:+ domain"
echo "  lsblk -d -o NAME,SIZE,MODEL       <- both NVMe drives listed"
echo "Revert at any time:  sudo $REPO_DIR/revert-vmd.sh"
