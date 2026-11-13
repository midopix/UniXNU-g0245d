#!/usr/bin/env bash
# G0245D 工具链自检：按「构建阶段」分组逐项验证，缺什么一眼看出来。
#
#   bash linux/check-toolchain.sh          只检查，不改动任何东西
#   bash linux/check-toolchain.sh --verbose 额外打印每项的版本行
#
# 判定依据不是 PATH 里有个同名文件，而是**真的执行它一次**（--version / -v / 空跑），
# 因为解包出来的工具常常缺共享库、缺 shebang 解释器，存在但跑不起来。

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

# shellcheck source=/dev/null
source "$ROOT/env.sh" >/dev/null 2>&1

PASS=0; FAIL=0; MISSING=()
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'

# run_ok <cmd...> : 真正跑一次，退出码 0 且输出非空才算通过
run_ok() {
  local out
  out="$("$@" 2>&1 | head -3)"
  [ -n "$out" ] && return 0
  return 1
}

# chk <显示名> <命令...>  —— 命令不存在或跑不起来都算缺失
chk() {
  local name="$1"; shift
  local path; path="$(command -v "$1" 2>/dev/null)"
  if [ -z "$path" ]; then
    printf '  %s✗%s %-22s %s(找不到命令)%s\n' "$RED" "$RST" "$name" "$DIM" "$RST"
    FAIL=$((FAIL+1)); MISSING+=("$name")
    return 1
  fi
  local ver=""
  if run_ok "$@"; then
    ver="$("$@" 2>&1 | head -1 | cut -c1-60)"
    printf '  %s✓%s %-22s %s\n' "$GRN" "$RST" "$name" "$path"
    [ "$VERBOSE" = 1 ] && [ -n "$ver" ] && printf '     %s%s%s\n' "$DIM" "$ver" "$RST"
    PASS=$((PASS+1))
    return 0
  else
    printf '  %s✗%s %-22s %s存在但跑不起来: %s%s\n' "$RED" "$RST" "$name" "$DIM" "$path" "$RST"
    FAIL=$((FAIL+1)); MISSING+=("$name (ran fail)")
    return 1
  fi
}

# chk_file <显示名> <路径>   仅判存在且可执行
chk_file() {
  local name="$1" path="$2"
  if [ -x "$path" ]; then
    printf '  %s✓%s %-22s %s\n' "$GRN" "$RST" "$name" "$path"; PASS=$((PASS+1))
  else
    printf '  %s✗%s %-22s %s缺失%s\n' "$RED" "$RST" "$name" "$DIM" "$RST"
    FAIL=$((FAIL+1)); MISSING+=("$name")
  fi
}

echo "G0245D 工具链自检  $(date '+%F %T')"
echo "  工程根: $ROOT"
echo "  沙箱  : /dev=$(awk '$5=="/dev"{fs="";for(i=1;i<=NF;i++)if($i=="-"){fs=$(i+1);break} v=fs} END{print v}' /proc/self/mountinfo 2>/dev/null)  Seccomp=$(awk '/^Seccomp:/{print $2}' /proc/self/status)"
echo

echo "── 1. 主机编译环境 ──────────────────────────────"
chk "python3"        python3 --version
chk "git"            git --version
chk "cmake"          cmake --version
chk "ninja"          ninja --version
chk "nasm"           nasm -v
chk "iasl"           iasl -v
chk "dtc"            dtc --version
chk "flex"           flex --version
chk "bison"          bison --version
chk "m4"             m4 --version
chk "pkg-config"     pkg-config --version
echo

echo "── 2. LLVM（UEFI 构建：CLANGPDB 需要 clang + lld-link）──"
chk "clang"          clang --version
chk "clang++"        clang++ --version
chk "lld-link"       lld-link --version
chk "ld.lld"         ld.lld --version
chk "llvm-ar"        llvm-ar --version
chk "llvm-objcopy"   llvm-objcopy --version
chk "llvm-objdump"   llvm-objdump --version
chk "llvm-nm"        llvm-nm --version
chk "llvm-strip"     llvm-strip --version
chk "llvm-config"    llvm-config --version
echo

echo "── 3. 定制 clang（XNU 内核：带 __builtin_xnu_type_* 补丁）──"
UT="$UNIXNU_TOOLCHAIN"
chk_file "xnu clang"      "$UT/llvm/bin/clang"
chk_file "xnu clang++"    "$UT/llvm/bin/clang++"
# 定制 clang 必须真的能编译，而不是只有文件在
TMPC="$(mktemp -d)"; printf 'int f(int a){return a*3;}\n' > "$TMPC/t.c"
if "$UT/llvm/bin/clang" --target=arm64-apple-ios -c "$TMPC/t.c" -o "$TMPC/t.o" >"$TMPC/log" 2>&1; then
  printf '  %s✓%s %-22s arm64-apple-ios 编译通过\n' "$GRN" "$RST" "xnu clang smoke"; PASS=$((PASS+1))
else
  printf '  %s✗%s %-22s 编译失败: %s\n' "$RED" "$RST" "xnu clang smoke" "$(head -1 "$TMPC/log" | cut -c1-70)"; FAIL=$((FAIL+1)); MISSING+=("xnu clang smoke")
fi
rm -rf "$TMPC"
echo

echo "── 4. Apple cctools / 链接器（XNU 与 kext 链接）──"
CLT="$UT/CommandLineTools/usr/bin"
chk_file "ld"               "$CLT/ld"
chk_file "otool"            "$CLT/otool"
chk_file "nm"               "$CLT/nm"
chk_file "strip"            "$CLT/strip"
chk_file "ar"               "$CLT/ar"
chk_file "ranlib"           "$CLT/ranlib"
chk_file "lipo"             "$CLT/lipo"
chk_file "install_name_tool" "$CLT/install_name_tool"
chk_file "segedit"          "$CLT/segedit"
chk_file "vtool"            "$CLT/vtool"
chk_file "codesign_allocate" "$CLT/codesign_allocate"
chk_file "bitcode_strip"    "$CLT/bitcode_strip"
chk_file "libtool"          "$CLT/libtool"
chk_file "mig"              "$CLT/mig"
chk_file "xnu-host-cc"      "$CLT/xnu-host-cc"
chk_file "migcom"           "$UT/CommandLineTools/usr/libexec/migcom"
chk_file "iig"              "$UT/XcodeDefault.xctoolchain/usr/bin/iig"
echo

echo "── 5. XNU 构建辅助工具 ──────────────────────────"
chk_file "xcrun (shim)"     "$UT/bin/xcrun"
chk_file "plutil (shim)"    "$UT/bin/plutil"
chk_file "codesign (shim)"  "$UT/bin/codesign"
chk "lzfse"                 lzfse -h
chk "unifdef"               unifdef -h
chk "tcsh"                  tcsh --version
# xcrun shim 的 -find 解析必须真的能问到 unifdef（v138 构建时这里返回空导致 0 字节 syscalls）
if [ -n "$(XNU_TOOLCHAIN_BIN="$CLT $UT/XcodeDefault.xctoolchain/usr/bin" "$UT/bin/xcrun" -sdk iphoneos -find unifdef 2>/dev/null)" ]; then
  printf '  %s✓%s %-22s xcrun -find unifdef 解析正常\n' "$GRN" "$RST" "xcrun -find"; PASS=$((PASS+1))
else
  printf '  %s✗%s %-22s xcrun -find unifdef 返回空（会导致 bsd.syscalls.master 为 0 字节）\n' "$RED" "$RST" "xcrun -find"; FAIL=$((FAIL+1)); MISSING+=("xcrun -find")
fi
echo

echo "── 6. 打包 / 镜像工具 ───────────────────────────"
chk "mkfs.vfat"             mkfs.vfat --help
chk "mcopy"                 mcopy --version
chk "mdir"                  mdir --version
chk "python3-PIL"           python3 -c "from PIL import Image; print('pillow', Image.__version__)"
chk "python3-numpy"         python3 -c "import numpy; print('numpy', numpy.__version__)"
echo

echo "── 7. 刷机工具 ──────────────────────────────────"
chk "fastboot"              fastboot --version
chk "adb"                   adb version
if ls -d /dev/bus/usb >/dev/null 2>&1; then
  printf '  %s✓%s %-22s %s\n' "$GRN" "$RST" "/dev/bus/usb" "$(ls /dev/bus/usb/*/* 2>/dev/null | wc -l) 个节点"
  PASS=$((PASS+1))
else
  printf '  %s!%s %-22s 不可见（沙箱内或未接设备），刷机必须离开沙箱\n' "$YEL" "$RST" "/dev/bus/usb"
fi
if lsusb 2>/dev/null | grep -qi '18d1'; then
  printf '  %s✓%s %-22s 设备在线: %s\n' "$GRN" "$RST" "fastboot 设备" "$(fastboot devices 2>/dev/null | tr '\n' ' ')"
  PASS=$((PASS+1))
else
  printf '  %s-%s %-22s 当前无 18d1 设备（未进 fastboot 或未插线）\n' "$DIM" "$RST" "fastboot 设备"
fi
echo

echo "── 8. Python 依赖（UEFI 构建 / 判读 / 调试）──────"
# 每项都真 import 一次：venv 没被识别为虚拟环境时 pip 会装到 ~/.local，
# 光看 pip list 会误判成"已装"，只有 import 才作数。
for mod in yaml serial Crypto unicorn zxingcpp cv2 lz4 build coloredlogs edk2toollib edk2toolext antlr4; do
  if python3 -c "import $mod" >/dev/null 2>&1; then
    printf '  %s✓%s %-22s\n' "$GRN" "$RST" "$mod"; PASS=$((PASS+1))
  else
    printf '  %s✗%s %-22s %s未安装%s\n' "$RED" "$RST" "$mod" "$DIM" "$RST"
    FAIL=$((FAIL+1)); MISSING+=("python:$mod")
  fi
done
echo

echo "── 汇总 ─────────────────────────────────────────"
printf '  通过 %s%d%s 项，缺失 %s%d%s 项\n' "$GRN" "$PASS" "$RST" "$([ "$FAIL" -gt 0 ] && echo "$RED" || echo "$GRN")" "$FAIL" "$RST"
if [ "$FAIL" -gt 0 ]; then
  printf '  缺失清单:\n'
  for m in "${MISSING[@]}"; do printf '    - %s\n' "$m"; done
  exit 1
fi
echo "  全部就绪（构建链、Apple 工具、打包、刷机）"
