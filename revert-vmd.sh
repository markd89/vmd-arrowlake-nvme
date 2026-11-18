#!/usr/bin/env bash
# revert-vmd.sh — restore the stock VMD module from the backup made by
# build-vmd.sh (backups/<kver>/<timestamp>/).
#
# v1.0 | 2026-11-18 15:55 | B (sandbox agent)
# Initial version: backup-dir selection, restore to the STOCK module's
# original path, depmod + initramfs regen, read-back verification.
#
# Usage:
#   sudo ./revert-vmd.sh              revert the most recent backup for this kernel
#   sudo ./revert-vmd.sh --kver=X     revert for another kernel
#   sudo ./revert-vmd.sh --list       show available backups, change nothing
#
# Exit codes: 0 ok | 1 preflight fail | 2 restore fail | 3 verify fail
# Reboot required to unload the patched module.
set -euo pipefail

KVER="$(uname -r)"
LIST_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --kver=*) KVER="${arg#--kver=}" ;;
        --list) LIST_ONLY=1 ;;
        --help|-h) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="$REPO_DIR/backups/${KVER}"

tool() { command -v "$1" 2>/dev/null || { for d in /usr/sbin /usr/bin /sbin /bin; do [ -x "$d/$1" ] && { echo "$d/$1"; return; }; done; echo ""; }; }
MODINFO="$(tool modinfo)"
DEPMOD="$(tool depmod)"
UPDATE_INITRAMFS="$(tool update-initramfs)"
LSINITRAMFS="$(tool lsinitramfs)"

# ---------- find newest backup ----------
if [[ ! -d "${BACKUP_ROOT}" ]]; then
    echo "FAIL: no backups for kernel ${KVER} under ${BACKUP_ROOT}"
    echo "      (build-vmd.sh creates one before it touches anything)"
    exit 1
fi
LATEST=$(ls -1 "${BACKUP_ROOT}" | sort | tail -1)
BK="${BACKUP_ROOT}/${LATEST}"
BK_FILE=$(ls "${BK}"/vmd.stock.ko* 2>/dev/null | head -1)
if [[ -z "${BK_FILE}" ]] || [[ ! -s "${BK_FILE}" ]]; then
    echo "FAIL: backup ${BK} has no stock module in it — refusing to continue."; exit 1
fi

echo "==> vmd-arrowlake-nvme revert script"
echo "    kernel : ${KVER}"
echo "    backup : ${BK_FILE}"
if [[ ${LIST_ONLY} -eq 1 ]]; then
    echo "    (list only — nothing changed)"
    ls -1 "${BACKUP_ROOT}" | sed 's/^/    available backup: /'
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    echo "FAIL: revert needs root (writes /lib/modules + initramfs). Re-run with sudo."; exit 1
fi
for t in "${MODINFO}" "${DEPMOD}" "${UPDATE_INITRAMFS}"; do
    if [[ -z "${t}" || ! -x "${t}" ]]; then
        echo "FAIL: required tool not found: modinfo/depmod/update-initramfs"; exit 1
    fi
done

# ---------- snapshot the CURRENT (patched) state before restoring ----------
CUR=$("${MODINFO}" -n vmd 2>/dev/null || true)
if [[ -n "${CUR}" && -f "${CUR}" ]]; then
    CUR_BK="${BACKUP_ROOT}/${LATEST}/patched-at-revert.ko$( [[ "${CUR}" == *.xz ]] && echo .xz )"
    if [[ ! -f "${CUR_BK}" ]]; then
        cp "${CUR}" "${CUR_BK}"
        echo "OK: current (patched) module saved as ${CUR_BK}"
    fi
fi

# ---------- restore to the stock module's ORIGINAL path ----------
if [[ "${BK_FILE}" == *.xz ]]; then
    if ! xz -t "${BK_FILE}" 2>/dev/null; then
        echo "FAIL: backup fails xz integrity test — refusing to install a corrupt module."; exit 2
    fi
fi
# canonical kernel-tree name for the stock module file
if [[ "${BK_FILE}" == *.xz ]]; then
    STOCK_NAME="vmd.ko.xz"
else
    STOCK_NAME="vmd.ko"
fi
# destination: the patched module's dir if it lives in the kernel tree,
# otherwise (patched copy in updates/ or none) the stock kernel-tree location
STOCK_DIR="/lib/modules/${KVER}/kernel/drivers/pci/controller"
if [[ -n "${CUR}" && -f "${CUR}" && "${CUR}" != */updates/* ]]; then
    STOCK_DIR="$(dirname "${CUR}")"
fi
mkdir -p "${STOCK_DIR}"
cp "${BK_FILE}" "${STOCK_DIR}/${STOCK_NAME}"
# remove the patched updates/ copy so it cannot shadow the restored stock one
if [[ -n "${CUR}" && "${CUR}" == */updates/* ]]; then
    rm -f "${CUR}"
    rmdir --ignore-fail-on-non-empty "$(dirname "${CUR}")" 2>/dev/null || true
fi
if [[ ! -s "${STOCK_DIR}/${STOCK_NAME}" ]]; then
    echo "FAIL: restored module missing at ${STOCK_DIR}/${STOCK_NAME}"; exit 2
fi
echo "OK restored: ${STOCK_DIR}/${STOCK_NAME}"

"${DEPMOD}" -a "${KVER}"
"${UPDATE_INITRAMFS}" -u -k "${KVER}"

# ---------- verify ----------
RESOLVED=$("${MODINFO}" -n vmd 2>/dev/null || true)
if [[ "${RESOLVED}" == */updates/* ]]; then
    echo "FAIL: modinfo still resolves vmd into updates/: ${RESOLVED}"; exit 3
fi
if "${LSINITRAMFS}" "/boot/initrd.img-${KVER}" 2>/dev/null | grep -q "updates/.*pci/controller/vmd"; then
    echo "FAIL: initramfs still contains the patched updates/ module"; exit 3
fi
echo "OK verify: modinfo -n vmd -> ${RESOLVED:-'(not found — vmd will load from the base kernel image)'}"
echo
echo "DONE. Reboot to load the stock module."
