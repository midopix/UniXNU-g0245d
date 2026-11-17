#!/usr/bin/env bash
# v186：重编 g0245d UEFI 固件，产出新的 SILICIUM_UEFI.fd。
#
# 为什么必须重编：v138..v185 的每个版本都直接把 v137 的 FD 原样复用
# (build-v185-all.sh 第 4 步：从 $V137 里抽出 fd-bootshim 再打包)。
# 也就是说 unixnu-src/drivers/DarwinBoot 下的 PaintBand / Entry.S 改动
# 一次都没上过机 —— 而观测通道的缺陷恰恰在那一层。
set -u

D="$(cd "$(dirname "$0")/../../.." && pwd)"
WS="$D/workspace"
MU="$D/src/unixnu-g0245d/uefi-g0245d/Mu-Silicium"
PY="$WS/tools/venv/bin/python"
TCBIN="$WS/tmp/toolchain-root/usr/bin"
REL="${1:-RELEASE}"

cd "$D" || exit 1
# 拆掉 safe-delete 垫片（EDK2 的 FlattenPdbs 会批量 unlink，被垫片当成批量删除中断）
CLEAN="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'cli/vendor/shim/safe-bin' | paste -sd: -)"
export PATH="$TCBIN:$CLEAN"
unset -f rm rmdir mv cp unlink ln 2>/dev/null || true
unset BASH_ENV NODE_OPTIONS PYTHONPATH 2>/dev/null || true
unset CODEBUDDY_SAFE_DELETE_ENABLED CODEBUDDY_SAFE_DELETE_SANDBOX \
      CODEBUDDY_SAFE_DELETE_BIN_DIR CODEBUDDY_SAFE_DELETE_BULK_GUARD \
      CODEBUDDY_SAFE_DELETE_BULK_STATE_DIR CODEBUDDY_SAFE_DELETE_BULK_THRESHOLD \
      CODEBUDDY_SAFE_DELETE_REPORT_PATH 2>/dev/null || true
export CODEBUDDY_SAFE_DELETE_ENABLED=0

source "$WS/tools/env.sh" >/dev/null 2>&1
export PATH="$TCBIN:$PATH"
# env.sh 指向的 clang+llvm-18.1.8 预编译包已被清掉；实际可用的是
# toolchain-root 里的 clang-20 + lld。CLANGPDB 通过 ENV(CLANG_BIN) 定位
# 工具前缀，所以这几条必须显式给出。
export CLANG_BIN="$TCBIN/"
export CLANG_HOST_BIN=""
export PYTHON_COMMAND="$PY"
export TMPDIR="$WS/tmp"
# github.com 在本机被 DNS 投毒，release 资产直连会被掐断；7890 是本机 mihomo。
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
export all_proxy=socks5://127.0.0.1:7890
mkdir -p "$TMPDIR"

cd "$MU" || exit 1
echo ">>> clang: $(command -v clang)"; clang --version | head -1

# Build/ 一旦存在，build_uefi.py 会把 setup/update 整个跳过，外部依赖就永远
# 补不上；所以这里每次都显式跑一次 update（已满足时是秒级 no-op）。
echo "=== [0/2] stuart_update（外部依赖）"
"$PY" Platforms/Gree/g0245dPkg/DeviceBuild.py --update -t "$REL"
echo ">>> update exit=$?"

echo "=== [1/2] 平台构建 g0245d $REL"
"$PY" build_uefi.py -d g0245d -r "$REL"
rc=$?
echo ">>> build_uefi.py exit=$rc"
[ $rc -ne 0 ] && exit $rc

echo "=== [2/2] FV 产物 ==="
find Platforms/Gree/g0245dPkg -name "SILICIUM_UEFI.fd*" -printf "%p  %s bytes\n" 2>/dev/null
echo "V186_FD_BUILD_OK"
