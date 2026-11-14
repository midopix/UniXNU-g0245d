#!/bin/bash
# ============================================================================
# 武装自动刷：写好最新镜像路径 + md5，守护检测到设备进 fastboot 就自动刷。
#
# 用法: bash linux/flash-arm.sh <img> <md5> [serial]
#
# 这替代了原来「在 WorkBuddy 里手动跑 flash-boot.sh」的步骤：
#   智能体每出新镜像就 arm 一次；之后用户只要把手机进 fastboot 插上，
#   宿主侧守护就会自动刷 + 自动重启，智能体从 .flash-result 读结果。
# ============================================================================
set -uo pipefail

D=/home/myth/WorkBuddy/2026-11-12-19-08-50/g0245d
ARM="$D/linux/.auto-flash"
SER_DEFAULT=S002170002517

IMG="${1:?用法: flash-arm.sh <img> <md5> [serial]}"
MD5="${2:?需要期望 md5}"
SER="${3:-$SER_DEFAULT}"

# 相对路径一律以工程根 $D 为基准 —— 守护是 systemd 服务，工作目录不是工程根，
# 传相对路径会让 flash-boot.sh 的 [ -f "$IMG" ] 找不到文件（曾导致 RC=1 不刷）。
case "$IMG" in
  /*) ;;
  *)  IMG="$D/$IMG" ;;
esac
[ -f "$IMG" ] || { echo "✗ 找不到 $IMG"; exit 1; }
ACTUAL=$(md5sum "$IMG" | awk '{print $1}')
if [ "$ACTUAL" != "$MD5" ]; then
  echo "✗ md5 不匹配：实际 $ACTUAL ≠ 期望 $MD5（拒绝武装）"
  exit 2
fi

# 武装同时清掉上次会话的"已尝试"标记，确保这次一定能刷
rm -f "$D/linux/.flash-attempted"
printf '%s\n%s\n%s\n' "$IMG" "$MD5" "$SER" > "$ARM.tmp"
mv -f "$ARM.tmp" "$ARM"

echo "✓ 已武装自动刷: $IMG"
echo "  实际 md5=$ACTUAL 与期望一致"
echo "  手机进 fastboot 插上后，守护会自动刷入并重启（刷完自动解除武装）"
echo "  查看守护状态: bash linux/flash-via-watcher.sh --status"
echo "  查看结果:     cat linux/.flash-result"
