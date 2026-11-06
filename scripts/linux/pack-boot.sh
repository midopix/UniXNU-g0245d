#!/usr/bin/env bash
# Pack the g0245d boot image: gzip(BootShim + FD) + appended DTB in a v0 container.
#
#   UEFI=/path/to/uefi-g0245d bash scripts/linux/pack-boot.sh [--check]
#
# Everything device-specific lives in scripts/package-g0245d-boot.py; this wrapper
# only resolves the two inputs it needs (the BootShim source and a built FD) and
# checks the result carries a valid Android header before it can reach a device.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
UEFI="${UEFI:-$(cd "$REPO/../uefi-g0245d" 2>/dev/null && pwd || true)}"
REL="${REL:-RELEASE}"
OUT="${OUT:-${REPO}/build/g0245d/boot/g0245d-uefi.img}"

[[ -n "${UEFI}" && -d "${UEFI}" ]] || { echo "error: set UEFI=/path/to/uefi-g0245d" >&2; exit 1; }
[[ -f "${UEFI}/BootShim/BootShim.S" ]] || { echo "error: ${UEFI}/BootShim/BootShim.S missing" >&2; exit 1; }

FD="${UEFI}/Mu-Silicium/Build/g0245dPkg/${REL}_CLANGPDB/FV/SILICIUM_UEFI.fd"
if [[ ! -f "${FD}" ]]; then
  echo "error: ${FD} not found; build the firmware first" >&2
  echo "       bash scripts/linux/build-firmware.sh ${REL}" >&2
  exit 1
fi

if [[ "${1:-}" == "--check" ]]; then
  echo "UEFI   ${UEFI}"
  echo "FD     $(stat -c %s "${FD}") bytes"
  echo "output ${OUT}"
  exit 0
fi

python3 "${REPO}/scripts/package-g0245d-boot.py" \
  --uefi "${UEFI}" -b "${REL}" -o "${OUT}"

# The header check aboot performs: ANDROID! at offset 0, page size 4096.
python3 - "${OUT}" <<'PY'
import hashlib, sys
from pathlib import Path

img = Path(sys.argv[1]).read_bytes()
if img[:8] != b"ANDROID!":
    sys.exit("error: packed image has no ANDROID! magic")
page = int.from_bytes(img[36:40], "little")
if page != 4096:
    sys.exit(f"error: unexpected page size {page}")
print(f">>> {sys.argv[1]}")
print(f">>> {len(img)} bytes  md5 {hashlib.md5(img).hexdigest()}")
PY
