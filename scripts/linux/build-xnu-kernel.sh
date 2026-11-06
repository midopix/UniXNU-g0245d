#!/usr/bin/env bash
# Report, then run, the XNU kernel build for g0245d.
#
#   bash scripts/linux/build-xnu-kernel.sh --check     # materials only
#   bash scripts/linux/build-xnu-kernel.sh             # ./unixnu build kernel
#
# Materials are fetched by the UniXNU CLI into out/feeds and out/ipsw, not into
# this repository, so the checks below look where the CLI writes. The five board
# patches in patches/xnu/series are the only inputs that cannot be downloaded;
# see docs/xnu-materials.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TREE="${TREE:-$(cd "$REPO/../unixnu-src" 2>/dev/null && pwd || true)}"

[[ -n "${TREE}" ]] || { echo "error: set TREE=/path/to/unixnu-src" >&2; exit 1; }

LACK=0
have() { if [[ -e "$1" ]]; then echo "  [ok]  $2"; else echo "  [--]  $2"; LACK=$((LACK+1)); fi; }

echo "--- sources"
have "${TREE}" "UniXNU source tree"
have "${TREE}/out/feeds" "Apple open-source feeds (unixnu fetch)"
have "${TREE}/unixnu" "unixnu CLI"

echo "--- kernel material"
KC="$(find "${TREE}/out/ipsw" -name 'kernelcache*' -print -quit 2>/dev/null || true)"
have "${KC:-/nonexistent}" "kernelcache"
DT="$(find "${TREE}/out/ipsw" -name 'DeviceTree.*.im4p' -print -quit 2>/dev/null || true)"
have "${DT:-/nonexistent}" "DeviceTree"

echo "--- board patches"
while read -r patch; do
  [[ -z "${patch}" || "${patch}" == \#* ]] && continue
  have "${REPO}/patches/xnu/${patch}" "${patch}"
done < "${REPO}/patches/xnu/series"

if [[ "${1:-}" == "--check" ]]; then
  echo
  if [[ ${LACK} -gt 0 ]]; then
    echo "${LACK} item(s) missing"
    exit 1
  fi
  echo "all materials present"
  exit 0
fi

if [[ ${LACK} -gt 0 ]]; then
  echo "error: ${LACK} item(s) missing; run with --check for the list" >&2
  exit 1
fi

cd "${TREE}"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=submodule.fetchJobs GIT_CONFIG_VALUE_0=1
./unixnu build kernel --device "${REPO}"
