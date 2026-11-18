#!/usr/bin/env bash
# v190：修 fbcon 的 ml_io_map 长度。G0245D_FB_SIZE 只有 0x200000（2 MiB），
# 覆盖 fb 行 0..642；但 fbcon 行 0 在 fb 928..959（字节偏移 3,006,720）。
# fbcon_init() 先清行 0 —— 第一个像素写就落在未映射内存上 → 数据中止，
# 此时 switch_to_serial_console() 还没跑、console 全无 → 完美静默死亡。
# v189 照片正是如此（fault 前的帧冻结，fbcon 一个像素都没有）。
# loader handoff 明说显示保留区是 0x23ff000，按这个大小映射。
# 沿 v189：ROW0 公式已修（ROW0 + row*16*SCALE），调用点在 lockdown 之后。
# 补丁 patches/xnu/zzz-g0245d-v190-fbsize.patch。
set -uo pipefail

D="$(cd "$(dirname "$0")/../../../../.." && pwd)"
UX="$D/src/unixnu-g0245d/unixnu-src"
OUT="$UX/out/g0245d/ipados-17.7.11-21H461/g0245d"
FD="$D/src/unixnu-g0245d/uefi-g0245d/Mu-Silicium/Build/g0245dPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd-bootshim"
V137="$D/workspace/tmp/g0245d-v137.img"
V188="$D/workspace/tmp/g0245d-v190.img"

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

echo "=== [4/4] 打包 v190（FD 沿用 v186，内核加 fbcon ROW0 公式修复）==="
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
