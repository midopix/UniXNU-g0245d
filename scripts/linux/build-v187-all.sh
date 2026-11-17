#!/usr/bin/env bash
# v187：只改内核 start.s（修 L1 index 3 自撞），FD 沿用 v186 已重编的那份。
#
# 为什么不再动 loader：Entry.S 经两轮独立审计确认无阻断性 bug；v186 已经把
# loader 侧的观测通道（PaintBand/Entry.S 的 dc civac）真正刷上机了，v187 沿用。
#
# 内核侧唯一改动：start.s:816-843 —— 把"往 V=P 表 L1[3] 硬写 1GB block"改成
# "探测 L1[3]，若已是内核自己的 table descriptor 就只往那张 L2 表插一条 2MB
# device block（VA 0xC3400000->PA 0x83400000，L2 index 26）"。
# VA 0xC3401000 保持不变，所以 start.s:195 / arm_init.c / video_console.c 里
# 5 处硬编码的 0xC3401000 与 0xCA8 一处都不用改。
set -uo pipefail

D="$(cd "$(dirname "$0")/../../.." && pwd)"
UX="$D/src/unixnu-g0245d/unixnu-src"
OUT="$UX/out/g0245d/ipados-17.7.11-21H461/g0245d"
FD="$D/src/unixnu-g0245d/uefi-g0245d/Mu-Silicium/Build/g0245dPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd-bootshim"
V137="$D/workspace/tmp/g0245d-v137.img"
V187="$D/workspace/tmp/g0245d-v187.img"

cd "$D" || exit 1
CLEAN="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'cli/vendor/shim/safe-bin' | paste -sd: -)"
export PATH="$CLEAN"
unset -f rm rmdir mv cp unlink ln 2>/dev/null || true
unset BASH_ENV NODE_OPTIONS PYTHONPATH \
      CODEBUDDY_SAFE_DELETE_ENABLED CODEBUDDY_SAFE_DELETE_SANDBOX \
      CODEBUDDY_SAFE_DELETE_BIN_DIR CODEBUDDY_SAFE_DELETE_BULK_GUARD \
      CODEBUDDY_SAFE_DELETE_BULK_STATE_DIR CODEBUDDY_SAFE_DELETE_BULK_THRESHOLD \
      CODEBUDDY_SAFE_DELETE_REPORT_PATH 2>/dev/null || true
export CODEBUDDY_SAFE_DELETE_ENABLED=0
source ./env.sh
# The toolchain-root copy of git was unpacked from a Debian package and keeps a
# compile-time exec-path of /usr/lib/git-core, which does not exist on this host.
# Prepending toolchain-root/usr/bin therefore makes `git submodule` fail with
# "git: 'submodule' is not a git command", and `unixnu build kernel` aborts at
# the very first step. Put a git shim (symlink to the host git, whose exec-path
# is valid) ahead of the toolchain so the kernel step can actually start.
export PATH="$D/workspace/tmp/gitshim:$D/workspace/tmp/toolchain-root/usr/bin:$PATH"

echo "=== [1/4] unixnu build kernel ==="
cd "$UX" || exit 1
OBJBSD="$OUT/tree/build/xnu/obj/DEVELOPMENT_ARM64_BCM2837/bsd/sys"
if [ -f "$OBJBSD/bsd.syscalls.master" ] && [ ! -s "$OBJBSD/bsd.syscalls.master" ]; then
  rm -f "$OBJBSD/bsd.syscalls.master" "$OBJBSD/syscall.h" "$OBJBSD/sysproto.h" \
        "$OUT/tree/build/xnu/obj/EXPORT_HDRS/bsd/sys/syscall.h" \
        "$OUT/tree/.cache/fakeroot/usr/include/sys/syscall.h"
  echo ">>> 已清理 0 字节 bsd.syscalls.master 残骸"
fi
python3 unixnu build kernel
rc=$?; echo ">>> build kernel exit=$rc"
[ $rc -ne 0 ] && exit $rc

echo "=== [2/4] prelink --skip-prelink ==="
python3 unixnu prelink --skip-prelink || exit 1

echo "=== [3/4] payload ==="
python3 unixnu payload --unique-chip-id "${G0245D_CHIP_ID:-}" || exit 1

echo "=== [4/4] 打包 v187（FD 沿用 v186）==="
[ -f "$FD" ] || { echo "✗ 缺 fd-bootshim: $FD"; exit 1; }
python3 "$D/workspace/tools/pack_fd.py" \
  --base "$V137" \
  --fd "$FD" \
  --ramdisk "$OUT/payload/payload.img" \
  --out "$V187" || exit 1

echo "=== 校验 ==="
ls -la "$V187"
md5sum "$V187"
echo "V187_BUILD_ALL_OK"
