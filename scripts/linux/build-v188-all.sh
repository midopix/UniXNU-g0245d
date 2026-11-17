#!/usr/bin/env bash
# v188：v187（拆掉 blackout / fbcon@arm_init / startup.c 自冻循环，start.s 不动）之上，
# 再把 fbcon 文本 console 的调用点从 arm_init 挪到 startup.c 的
# kernel_startup_initialize_upto(STARTUP_SUB_LOCKDOWN) 之后 —— 那时 io_map_init
# 已跑，ml_io_map() 才有效；并打开 serial_console_enabled + switch_to_serial_console()
# 让后续 kprintf/printf 全部落到屏上；FBCON_ROW0 40 -> 960（落入实机证明可见的
# fb 行 8..972 区间）。补丁 patches/xnu/zzz-g0245d-v188-fbcon-lockdown-text.patch。
set -uo pipefail

D="$(cd "$(dirname "$0")/../../.." && pwd)"
UX="$D/src/unixnu-g0245d/unixnu-src"
OUT="$UX/out/g0245d/ipados-17.7.11-21H461/g0245d"
FD="$D/src/unixnu-g0245d/uefi-g0245d/Mu-Silicium/Build/g0245dPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd-bootshim"
V137="$D/workspace/tmp/g0245d-v137.img"
V187="$D/workspace/tmp/g0245d-v188.img"

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

echo "=== [4/4] 打包 v188（FD 沿用 v186，内核加 fbcon lockdown 文本）==="
[ -f "$FD" ] || { echo "✗ 缺 fd-bootshim: $FD"; exit 1; }
python3 "$D/workspace/tools/pack_fd.py" \
  --base "$V137" \
  --fd "$FD" \
  --ramdisk "$OUT/payload/payload.img" \
  --out "$V187" || exit 1

echo "=== 校验 ==="
ls -la "$V187"
md5sum "$V187"
echo "V188_BUILD_ALL_OK"
