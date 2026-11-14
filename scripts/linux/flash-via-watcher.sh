#!/bin/bash
# ============================================================================
# 自动刷系统的状态/结果查看器（智能体在 WorkBuddy 沙箱内也能用）
#
# 用法:
#   bash linux/flash-via-watcher.sh --status    # 守护是否在线 + 是否已武装 + 设备可见性
#   bash linux/flash-via-watcher.sh --result    # 上一次刷机结果
#   bash linux/flash-via-watcher.sh --arm <img> <md5> [serial]   # 武装（同 flash-arm.sh）
#
# 自动刷由宿主侧守护(flash-watcher.sh)完成；本脚本只读写协议文件，不碰 fastboot。
# ============================================================================
set -uo pipefail

D=/home/myth/WorkBuddy/2026-11-12-19-08-50/g0245d
HBT="$D/linux/.flash-heartbeat"
ARM="$D/linux/.auto-flash"
RES="$D/linux/.flash-result"

alive() {
  [ -f "$HBT" ] || return 1
  local t now
  t=$(stat -c %Y "$HBT" 2>/dev/null) || return 1
  now=$(date +%s)
  [ $((now - t)) -le 20 ]
}

if [ "${1:-}" = "--status" ]; then
  if alive; then
    echo "✓ 刷机守护在线: $(cat "$HBT")"
  else
    echo "✗ 刷机守护未运行（或心跳过期）"
    echo "  在系统「终端」跑一次（只需一次，之后开机自启）:"
    echo "  bash $D/linux/install-flash-watcher.sh"
  fi
  if [ -f "$ARM" ]; then
    echo "· 已武装: $(sed -n '1p' "$ARM")  (md5=$(sed -n '2p' "$ARM"))"
  else
    echo "· 未武装（不会自动刷；要刷先 arm 最新镜像）"
  fi
  exit 0
fi

if [ "${1:-}" = "--result" ]; then
  if [ -f "$RES" ]; then
    cat "$RES"
  else
    echo "(尚无刷机结果)"
  fi
  exit 0
fi

if [ "${1:-}" = "--arm" ]; then
  shift
  exec bash "$D/linux/flash-arm.sh" "$@"
fi

# 默认 = 状态
exec bash "$0" --status
