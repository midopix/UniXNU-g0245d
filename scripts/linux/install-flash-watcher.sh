#!/bin/bash
# ============================================================================
# 一键安装「刷机守护」到 systemd --user（开机自启，永久在沙箱外运行）
#
# 用法（必须在系统「终端」里跑，不要从 WorkBuddy 里跑）：
#   bash ~/WorkBuddy/2026-11-12-19-08-50/g0245d/linux/install-flash-watcher.sh
#
# 装完之后：智能体在 WorkBuddy 会话里 arming 最新镜像，守护检测到设备进
# fastboot 就自动刷 + 自动重启，不再受沙箱反复横跳影响。
# ============================================================================
set -uo pipefail

D=/home/myth/WorkBuddy/2026-11-12-19-08-50/g0245d
UNIT_SRC="$D/linux/g0245d-flash.service"
UNIT_DIR="$HOME/.config/systemd/user"

chmod +x "$D/linux/flash-watcher.sh" "$D/linux/flash-boot.sh" 2>/dev/null

# --- 自检：不能从 WorkBuddy 沙箱里装 ---
dev_fs=$(awk '$5=="/dev"{fs="";for(i=1;i<=NF;i++)if($i=="-"){fs=$(i+1);break} v=fs} END{print v}' /proc/self/mountinfo)
if [ "$dev_fs" != "devtmpfs" ] || [ ! -d /dev/bus/usb ]; then
  echo "✗ 当前 shell 在 WorkBuddy 沙箱内（/dev=$dev_fs），装出来的守护也看不见 USB。"
  echo "  请打开系统「终端」再跑这条命令。"
  exit 4
fi

# --- 有 systemd user 实例就用 systemd，否则退回 nohup ---
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  mkdir -p "$UNIT_DIR"
  cp "$UNIT_SRC" "$UNIT_DIR/g0245d-flash.service"
  systemctl --user daemon-reload
  systemctl --user enable --now g0245d-flash.service
  sleep 2
  echo "--- 服务状态 ---"
  systemctl --user --no-pager status g0245d-flash.service | head -12
  echo
  echo "✓ 已安装为 systemd 用户服务（开机自启，无需再管）"
  echo "  日志: $D/linux/.flash-watcher.log"
  echo "  停用: systemctl --user disable --now g0245d-flash.service"
else
  echo "· systemd 用户实例不可用，改用后台进程（重启后失效，需重跑本脚本）"
  pkill -f 'flash-watcher.sh' 2>/dev/null
  nohup bash "$D/linux/flash-watcher.sh" >> "$D/linux/.flash-watcher.log" 2>&1 &
  sleep 2
  echo "✓ 已在后台启动，pid=$!"
fi

# --- 验证心跳 ---
sleep 3
if [ -f "$D/linux/.flash-heartbeat" ]; then
  echo "✓ 心跳正常: $(cat "$D/linux/.flash-heartbeat")"
else
  echo "✗ 没看到心跳文件，检查 $D/linux/.flash-watcher.log"
  exit 5
fi

echo
echo "现在可以让智能体在 WorkBuddy 里直接刷机了：它会写请求文件，守护在沙箱外执行 fastboot。"
