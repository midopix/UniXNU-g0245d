#!/usr/bin/env bash
# v189：修 fbcon 的 ROW0 坐标 bug。v188 写成 (ROW0+row)*16*SCALE，把 960 的
# 屏幕行基也乘了 32 —— y0=30720 全部越过 1919，g0245d_fbcon_px() 里
# y_fb = 1919 - y_screen 按 uint32_t 回绕，>= 高度守卫把每个像素都丢掉，
# 连 "V183 FBCON OK" 都没上屏（v188 照片只有 v187 时代的 paint_stage/fb_mark 条）。
# 公式改为 ROW0 + row*16*SCALE：行 0 -> 屏幕 960..991 -> fb 928..959，
# 行 17 -> fb 384..415，全部落在实机证明可见的 fb 8..972 区间。
# 其余沿 v188：fbcon 调用点在 startup.c lockdown 之后，serial gate 打开。
# 补丁 patches/xnu/zzz-g0245d-v189-fbcon-row0-fix.patch。
set -uo pipefail

D="$(cd "$(dirname "$0")/../../../../.." && pwd)"
UX="$D/src/unixnu-g0245d/unixnu-src"
OUT="$UX/out/g0245d/ipados-17.7.11-21H461/g0245d"
FD="$D/src/unixnu-g0245d/uefi-g0245d/Mu-Silicium/Build/g0245dPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd-bootshim"
V137="$D/workspace/tmp/g0245d-v137.img"
V188="$D/workspace/tmp/g0245d-v189.img"

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

echo "=== [4/4] 打包 v189（FD 沿用 v186，内核加 fbcon ROW0 公式修复）==="
[ -f "$FD" ] || { echo "✗ 缺 fd-bootshim: $FD"; exit 1; }
python3 "$D/workspace/tools/pack_fd.py" \
  --base "$V137" \
  --fd "$FD" \
  --ramdisk "$OUT/payload/payload.img" \
  --out "$V188" || exit 1

echo "=== 校验 ==="
ls -la "$V188"
md5sum "$V188"
echo "V189_BUILD_ALL_OK"
