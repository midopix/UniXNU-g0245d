#!/usr/bin/env bash
# Build the g0245d UEFI firmware volume.
#
#   MU=/path/to/Mu-Silicium bash scripts/linux/build-firmware.sh [RELEASE|DEBUG]
#
# MU points at a Mu-Silicium checkout with this repository's overlay applied
# (Platforms/Gree/g0245dPkg, Resources/Configs/g0245d.toml, Resources/MuPatches).
# build_uefi.py applies the board MuPatches, sets PACKAGES_PATH and calls the
# EDK II build with AARCH64 RELEASE_CLANGPDB.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
REL="${1:-RELEASE}"
MU="${MU:-$(cd "$REPO/../uefi-g0245d/Mu-Silicium" 2>/dev/null && pwd || true)}"

if [[ -z "${MU}" || ! -f "${MU}/build_uefi.py" ]]; then
  echo "error: set MU=/path/to/Mu-Silicium (build_uefi.py not found)" >&2
  exit 1
fi
if [[ ! -f "${MU}/Platforms/Gree/g0245dPkg/g0245d.dsc" ]]; then
  echo "error: the g0245d overlay is not applied to ${MU}" >&2
  echo "       expected Platforms/Gree/g0245dPkg/g0245d.dsc" >&2
  exit 1
fi

# The vendor DXE images are not in Git; a source-only checkout stops at
# "SPMI.inf is not found".
if [[ ! -f "${MU}/Binaries/g0245d/QcomPkg/Drivers/SPMI/SPMI.inf" ]]; then
  echo "error: Binaries/g0245d is missing the vendor DXE set (SPMI.inf)" >&2
  echo "       restore it from the QFIL package before building; the files are" >&2
  echo "       listed by hash in proprietary-files.txt" >&2
  exit 1
fi

export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"
export MAX_CONCURRENT_THREAD_NUMBER="${MAX_CONCURRENT_THREAD_NUMBER:-1}"

echo ">>> building g0245d ${REL} in ${MU}"
python3 "${MU}/build_uefi.py" -d g0245d -r "${REL}"

FD="${MU}/Build/g0245dPkg/${REL}_CLANGPDB/FV/SILICIUM_UEFI.fd"
[[ -f "${FD}" ]] || { echo "error: ${FD} not produced" >&2; exit 1; }

# The packer refuses to run unless the FD size matches [uefi_fd] size exactly.
python3 - "${FD}" "${REPO}/board.toml" <<'PY'
import sys, tomllib
from pathlib import Path

fd, board = Path(sys.argv[1]), Path(sys.argv[2])
want = int(tomllib.load(open(board, "rb"))["uefi_fd"]["size"], 0)
got = fd.stat().st_size
print(f">>> FD {got} bytes, [uefi_fd] size {want}")
if got != want:
    sys.exit(f"error: FD size mismatch (board.toml says {want:#x})")
PY

echo ">>> ${FD}"
