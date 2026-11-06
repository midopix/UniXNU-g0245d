#!/usr/bin/env bash
# Flash (or dry-run) a g0245d UniXNU boot image.
#
#   bash scripts/linux/flash.sh --check          # verify the image only
#   bash scripts/linux/flash.sh --wait 300       # poll for fastboot, then boot it
#
# The device stays untouched: `fastboot boot` loads the image into RAM, so a bad
# build costs a power cycle, not a reflash. Refuse to run against an image whose
# md5 matches a known-stale build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
IMG="${IMG:-${REPO}/build/g0245d/boot/g0245d-uefi.img}"

# Images that have already been on this device and must not be flashed again by
# accident. Extend as new builds are validated.
KNOWN_OLD=(
  "f85aa23dcc66d333d617ed8cdee3176d"   # v98, pre-timer-fix
  "b56add5ca7f1a1d9c0348cd5975cd35f"   # v97, timer frequency only
)

MODE="check"
WAIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check" ;;
    --wait)  MODE="flash"; WAIT="${2:-300}"; shift ;;
    --flash) MODE="flash" ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift
done

[[ -f "${IMG}" ]] || { echo "error: ${IMG} not found; run scripts/linux/pack-boot.sh" >&2; exit 1; }

MD5="$(md5sum "${IMG}" | cut -d' ' -f1)"
SIZE="$(stat -c %s "${IMG}")"
echo ">>> ${IMG}"
echo "    ${SIZE} bytes  md5 ${MD5}"

head -c 8 "${IMG}" | grep -q "ANDROID!" || { echo "error: no ANDROID! magic" >&2; exit 1; }

for old in "${KNOWN_OLD[@]}"; do
  if [[ "${MD5}" == "${old}" ]]; then
    echo "error: this image is a known-stale build (${old})." >&2
    echo "       Rebuild before flashing; pass IMG=... only for a deliberate re-test." >&2
    exit 1
  fi
done

if [[ "${MODE}" == "check" ]]; then
  echo ">>> image ok (dry run)"
  exit 0
fi

command -v fastboot >/dev/null || { echo "error: fastboot not found" >&2; exit 1; }

if [[ "${WAIT}" -gt 0 ]]; then
  echo ">>> waiting up to ${WAIT}s for a fastboot device (hold volume-down + power)"
  deadline=$(( $(date +%s) + WAIT ))
  until fastboot devices 2>/dev/null | grep -q .; do
    [[ $(date +%s) -lt ${deadline} ]] || { echo "error: no device within ${WAIT}s" >&2; exit 1; }
    sleep 2
  done
fi

fastboot devices
echo ">>> fastboot boot ${IMG}"
fastboot boot "${IMG}"

cat <<'EOF'
>>> the device is rebooting into the image.
    An `avb footer` warning here is expected and does not block the boot.
EOF
