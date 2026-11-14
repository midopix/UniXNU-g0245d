#!/bin/bash
# ============================================================================
# G0245D 设备驱动自动刷守护（宿主机侧，必须在 WorkBuddy 沙箱**外**运行）
#
# 工作原理（设备驱动 + 武装制）：
#   - 每 2 秒轮询 `fastboot devices`，看本机序列号(S002170002517)是否进入 fastboot；
#   - 只有「已武装」(linux/.auto-flash 存在) 且本次 fastboot 会话尚未尝试过时，
#     才自动调用 flash-boot.sh 刷入并重启；
#   - 刷成功 → 自动解除武装（删 .auto-flash），避免设备重启后又被反复刷；
#   - 刷失败 → 保留武装，但本次会话标记已尝试，设备离开 fastboot 后才允许重试；
#   - 设备离开 fastboot（重启/拔线）后清除会话标记，下次进入可重新尝试。
#
# 为什么是「武装制」而不是无脑自动刷：
#   这台设备只用于 bring-up，但用户有时进 fastboot 是为了救砖/看 log，
#   盲目见 fastboot 就刷会把上一版画面当新结论，也会在失败时无限重刷。
#   武装 = 智能体确认「有新镜像要上」后才允许自动刷，检测+执行全自动。
#
# 与智能体的协作：智能体只负责「武装」(flash-arm.sh <img> <md5>) 和「读结果」
# (.flash-result)，真正的 fastboot 在沙箱外的宿主进程里跑，不受沙箱横跳影响。
#
# 协议文件（都在 linux/ 下）：
#   .auto-flash      武装文件：第1行=img路径 第2行=md5 第3行=序列号(可省)
#   .flash-result    刷机输出 + RC=<退出码> + TIME=<时间>
#   .flash-heartbeat 每 5 秒刷新，确认守护活着
#   .flash-attempted 本次 fastboot 会话已尝试过（防刷失败后狂刷）
# ============================================================================
set -uo pipefail

D=/home/myth/WorkBuddy/2026-11-12-19-08-50/g0245d
SERIAL_DEFAULT=S002170002517
export PATH="$D/workspace/tools/platform-tools-linux:$PATH"

ARM="$D/linux/.auto-flash"
RES="$D/linux/.flash-result"
HBT="$D/linux/.flash-heartbeat"
LOG="$D/linux/.flash-watcher.log"
ATTEMPTED="$D/linux/.flash-attempted"

# --- 守护自己必须在沙箱外（否则看不到 USB）---
dev_fs=$(awk '$5=="/dev"{fs="";for(i=1;i<=NF;i++)if($i=="-"){fs=$(i+1);break} v=fs} END{print v}' /proc/self/mountinfo)
if [ "$dev_fs" != "devtmpfs" ] || [ ! -d /dev/bus/usb ]; then
  echo "[$(date '+%F %T')] ✗ 守护在沙箱内（/dev=$dev_fs），无法工作。" | tee -a "$LOG"
  echo "  请从系统「终端」或 systemd 启动本脚本，不要从 WorkBuddy 里启动。" | tee -a "$LOG"
  exit 4
fi

echo "[$(date '+%F %T')] watcher 启动 /dev=$dev_fs pid=$$ serial=$SERIAL_DEFAULT" | tee -a "$LOG"
last_hb=0
device_present="no"

while true; do
  now=$(date +%s)
  if [ $((now - last_hb)) -ge 5 ]; then
    printf '%s pid=%s\n' "$(date '+%F %T')" "$$" > "$HBT"
    last_hb=$now
  fi

  present="no"
  if fastboot devices 2>/dev/null | grep -q "$SERIAL_DEFAULT"; then
    present="yes"
  fi

  if [ "$present" = "yes" ]; then
    if [ "$device_present" = "no" ]; then
      # 设备刚进入 fastboot：清除上次会话的"已尝试"标记，允许本次尝试
      rm -f "$ATTEMPTED"
      echo "[$(date '+%F %T')] 检测到设备进入 fastboot" >> "$LOG"
    fi

    # 已武装 且 本次会话尚未尝试 → 自动刷
    if [ -f "$ARM" ] && [ ! -f "$ATTEMPTED" ]; then
      img=$(sed -n '1p' "$ARM")
      md5=$(sed -n '2p' "$ARM")
      ser=$(sed -n '3p' "$ARM")
      [ -z "${ser:-}" ] && ser="$SERIAL_DEFAULT"
      touch "$ATTEMPTED"   # 先标记，防轮询重入导致多刷
      echo "[$(date '+%F %T')] 自动刷机开始: $img md5=$md5 serial=$ser" >> "$LOG"
      out=$(bash "$D/linux/flash-boot.sh" "$img" "$md5" "$ser" 2>&1); rc=$?
      printf '%s\nRC=%d\nTIME=%s\n' "$out" "$rc" "$(date '+%F %T')" > "$RES.tmp"
      mv -f "$RES.tmp" "$RES"
      if [ "$rc" = "0" ]; then
        rm -f "$ARM"   # 成功 → 解除武装（设备即将重启）
        echo "[$(date '+%F %T')] 自动刷机成功，已解除武装（设备重启中）" >> "$LOG"
      else
        echo "[$(date '+%F %T')] 自动刷机失败 RC=$rc，保留武装，待设备离开 fastboot 后重试" >> "$LOG"
      fi
    fi
  else
    if [ "$device_present" = "yes" ]; then
      echo "[$(date '+%F %T')] 设备离开 fastboot（已重启或拔线），清除会话标记" >> "$LOG"
    fi
    # 设备不在 → 清会话标记，下次进入可重试
    rm -f "$ATTEMPTED"
  fi

  device_present="$present"
  sleep 2
done
