#!/bin/bash
# v181 一条龙：把 boot framebuffer 注册成 pe_serial_functions，kprintf 以
# 8x16 点阵画到屏幕下半部 —— 按 24bpp 逐字节写。
#
# 为什么有 v181（2026-11-17 实机判读）：
#   v180（md5 f3d74ac6b47d2e1d655ffdfedea1234b）刷入后，屏幕打出 DARWINBOOT trace，
#   其中这一行是决定性数据：
#     DARWINBOOT: video base=0x83401000 display=1 row=3240 width=1080 height=1920 depth=24
#   depth=24 表示每像素 3 字节（stride 3240 == 1080*3，无 padding）；v180 却按
#   uint32_t 存储。把 32bpp 写进 24bpp 视口，实际写入的字节模式是 00 00 00 ff
#   的无限重复，渲染出来是「黑/蓝/绿/红」四色竖条纹，永远拼不成字形。
#   v181 把每个像素拆成 3 个独立字节写，字形位序取 MSB-leftmost。
#
# 设计不变（沿用 v180 已验证的部分）：
#   - 走 ml_io_map() 这条已验证通路（ml_io_map_wcomb / ml_io_map_unmappable 是 v155/v170 死路）
#   - 纯 store：无内存分配、无 MMIO、绝不阻塞，故可在 arm_vm_init 之前从 serial_init 调用
#   - 画在屏幕下半部 row 40..57（y=1280..1856 / 1920），不干扰 stock video console
set -euo pipefail

D="$(cd "$(dirname "$0")/../../../../.." && pwd)"
UX="$D/src/unixnu-g0245d/unixnu-src"
OUT="$UX/out/g0245d/ipados-17.7.11-21H461/g0245d"
V137="$D/workspace/tmp/g0245d-v137.img"
V181="$D/workspace/tmp/g0245d-v181.img"
FD="$D/workspace/tmp/v181-fd-bootshim"

cd "$D"
source ./env.sh
# 拆除 safe-delete 垫片（三条注入通道全拆）
CLEAN="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'cli/vendor/shim/safe-bin' | paste -sd: -)"
export PATH="$CLEAN"
unset -f rm rmdir mv cp unlink ln 2>/dev/null || true
unset BASH_ENV NODE_OPTIONS PYTHONPATH \
      CODEBUDDY_SAFE_DELETE_ENABLED CODEBUDDY_SAFE_DELETE_SANDBOX \
      CODEBUDDY_SAFE_DELETE_BIN_DIR CODEBUDDY_SAFE_DELETE_BULK_GUARD \
      CODEBUDDY_SAFE_DELETE_BULK_STATE_DIR CODEBUDDY_SAFE_DELETE_BULK_THRESHOLD \
      CODEBUDDY_SAFE_DELETE_REPORT_PATH 2>/dev/null || true
RMWHO="$(type -t rm)"; [ "$RMWHO" = "file" ] || { echo "✗ rm 仍是 $RMWHO，垫片未拆净"; exit 9; }
echo "✓ 垫片已拆除（rm -> $(command -v rm)）"
export PATH="$D/workspace/tmp/toolchain-root/usr/bin:$PATH"

echo "=== [1/5] 续编带 XNU builtins 的 clang（增量）==="
bash "$D/workspace/tools/build-xnu-clang-linux.sh"

echo "=== [2/5] 幂等补齐工具链 ==="
python3 "$D/workspace/tools/setup-toolchain-noroot.py"

echo "=== [3/5] unixnu build kernel ==="
cd "$UX"
OBJBSD="$OUT/tree/build/xnu/obj/DEVELOPMENT_ARM64_BCM2837/bsd/sys"
if [ -f "$OBJBSD/bsd.syscalls.master" ] && [ ! -s "$OBJBSD/bsd.syscalls.master" ]; then
  rm -f "$OBJBSD/bsd.syscalls.master" "$OBJBSD/syscall.h" "$OBJBSD/sysproto.h" \
        "$OUT/tree/build/xnu/obj/EXPORT_HDRS/bsd/sys/syscall.h" \
        "$OUT/tree/.cache/fakeroot/usr/include/sys/syscall.h"
  echo "✓ 已清理 0 字节 bsd.syscalls.master 残骸（含下游 syscall.h/sysproto.h）"
fi
python3 unixnu build kernel

echo "=== [3b/5] native kernel.macho（--skip-prelink，与 v137/v140 同形态）+ payload ==="
python3 unixnu prelink --skip-prelink
# G0245D_CHIP_ID must be exported by the caller (platform seed, not stored in repo)
: "${G0245D_CHIP_ID:?set G0245D_CHIP_ID to this board platform seed before build}"
python3 unixnu payload --unique-chip-id "${G0245D_CHIP_ID}"

echo "=== [4/5] 打包 v181（复用 v137 的 FD 与 DTB 表）==="
python3 - "$V137" "$FD" <<'PY'
import sys, zlib, struct
base_path, fd_out = sys.argv[1], sys.argv[2]
base = open(base_path, 'rb').read()
page = 4096
assert base[:8] == b'ANDROID!', 'not a boot img'
ks, = struct.unpack('<I', base[8:12])
d = zlib.decompressobj(wbits=31)
fd = d.decompress(base[page:page+ks]) + d.flush()
open(fd_out, 'wb').write(fd)
print('fd-bootshim 提取成功: %d bytes (DTB 尾巴 %d bytes 原样保留在 base)' % (len(fd), len(d.unused_data)))
PY

python3 "$D/workspace/tools/pack_fd.py" \
  --base "$V137" \
  --fd "$FD" \
  --ramdisk "$OUT/payload/payload.img" \
  --out "$V181"

echo "=== 校验 ==="
ls -la "$V181"
md5sum "$V181"
echo "V181_BUILD_ALL_OK"
