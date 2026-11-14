#!/bin/bash
# 一键刷 boot 分区（通用）：环境自检 → 校验 md5 → 校验序列号 → 只刷 boot → 重启
# 用法:
#   bash linux/flash-boot.sh --check                              # 只做环境自检 + 探测设备
#   bash linux/flash-boot.sh <img> <期望md5> [序列号]              # 自检通过后刷入
# 铁律：只刷 boot；原厂 aboot/xbl/rpm/tz/system/userdata 一律不动。
set -euo pipefail

D=/home/myth/WorkBuddy/2026-11-12-19-08-50/g0245d
SERIAL_DEFAULT=S002170002517
export PATH="$D/workspace/tools/platform-tools-linux:$PATH"

# ---------- 环境自检：确认当前 shell 不在 WorkBuddy 沙箱里 ----------
# 沙箱会在真实 devtmpfs 之上再叠一层 10MiB tmpfs 到 /dev（只白名单 bind 进
# null/zero/random/urandom/full/tty 几个节点），并挂 seccomp 过滤器拦截 mknod/mount。
# 结果：/dev/bus/usb 不存在，fastboot 永远看不到手机。
# 注意：/proc/self/mountinfo 里 /dev 会出现多条记录（外层 devtmpfs + 内层 tmpfs），
# 必须取**最后一条**（最内层、实际生效的那层）。
dev_fs=$(awk '$5=="/dev"{fs="";for(i=1;i<=NF;i++)if($i=="-"){fs=$(i+1);break} v=fs} END{print v}' /proc/self/mountinfo)
seccomp=$(awk '/^Seccomp:/{print $2}' /proc/self/status)
if [ "$dev_fs" != "devtmpfs" ] || [ ! -d /dev/bus/usb ]; then
  cat <<EOF
✗ 当前环境在 WorkBuddy 沙箱内：/dev 最内层挂的是「${dev_fs}」，/dev/bus/usb 不可见
  （Seccomp=$seccomp）
  沙箱用 tmpfs 盖住 /dev 并用 seccomp 拦住 mknod/mount，fastboot 在这里永远看不到手机。
  解决：① 在系统「终端」里直接跑本脚本（不经过 WorkBuddy 沙箱）；或
        ② 从桌面图标重启 WorkBuddy（图标已带关闭沙箱参数），再让我跑。
EOF
  exit 4
fi

if [ "${1:-}" = "--check" ]; then
  echo "✓ /dev 是 devtmpfs（未沙箱化），Seccomp=$seccomp"
  echo "✓ USB 节点: $(ls /dev/bus/usb/*/* 2>/dev/null | wc -l) 个"
  echo -n "  fastboot 可见设备: "
  devs=$(fastboot devices 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  echo "${devs:-<无>}"
  if [ "${2:-$SERIAL_DEFAULT}" != "" ] && fastboot devices 2>/dev/null | grep -q "${2:-$SERIAL_DEFAULT}"; then
    echo "✓ 目标设备 ${2:-$SERIAL_DEFAULT} 在线，可以刷"
  else
    echo "· 目标设备未在线（手机没插 / 没进 fastboot），插上并进 fastboot 后再跑"
  fi
  exit 0
fi

if [ "${1:-}" = "--off" ]; then
  # 远程关机：只在手机停在 fastboot 时可用（冻屏/进 XNU 后 USB 命令通道已断，只能长按电源 15 秒）
  if fastboot devices 2>/dev/null | grep -q "${2:-$SERIAL_DEFAULT}"; then
    echo "· 设备在 fastboot，发送关机…"
    fastboot -s "${2:-$SERIAL_DEFAULT}" oem poweroff 2>&1 || fastboot -s "${2:-$SERIAL_DEFAULT}" reboot 2>&1
    echo "POWEROFF_SENT"
  else
    echo "✗ fastboot 看不到设备 —— 无法远程关机。"
    echo "  若屏幕冻在 XNU：长按电源键 15 秒硬关机，再插充电器。"
  fi
  exit 0
fi

IMG="${1:?用法: flash-boot.sh <img> <md5> [serial] | --check | --off}"
EXPECT="${2:?需要期望 md5}"
SERIAL="${3:-$SERIAL_DEFAULT}"

# 兜底：相对路径按工程根解析（守护以 systemd 启动时 CWD 不是工程根）
[ -f "$IMG" ] || IMG="$D/$IMG"
[ -f "$IMG" ] || { echo "✗ 找不到 $IMG"; exit 1; }
ACTUAL=$(md5sum "$IMG" | awk '{print $1}')
if [ "$ACTUAL" != "$EXPECT" ]; then
  echo "✗ md5 不匹配：实际 $ACTUAL ≠ 期望 $EXPECT（拒绝刷入）"
  exit 2
fi
echo "✓ md5 校验通过: $ACTUAL  ($(stat -c %s "$IMG") bytes)"

fastboot devices 2>/dev/null | grep -q "$SERIAL" \
  || { echo "✗ fastboot 看不到设备 $SERIAL，请先进入 fastboot（音量下 + 电源）"; exit 3; }
echo "✓ 设备 $SERIAL 在线"

fastboot -s "$SERIAL" flash boot "$IMG"
fastboot -s "$SERIAL" reboot
echo "FLASH_DONE $(basename "$IMG") md5=$ACTUAL"
