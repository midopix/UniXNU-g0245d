# 公开仓约定（发布清洁化）

> 中文摘要：本仓是**纯源码**发布仓。设备序列号、个人路径、Apple/OEM 二进制一律不进仓。
> 历史上曾有这些敏感信息，已在 2026-11-16 用 `git filter-branch` 全历史重写清除。

## 一、脱敏约定

| 信息 | 仓内形态 | 使用方式 |
|---|---|---|
| 设备序列号 | `G0245D_SERIAL` 环境变量 / `<SERIAL>` 占位符 | 刷机前 `export G0245D_SERIAL=<你的序列号>` |
| 工程根路径 | 脚本相对定位 `$(cd "$(dirname "$0")/../../.." && pwd)` | clone 到任意目录都能跑 |
| 个人 home | `$HOME` | 标准 shell 变量 |
| chip-id | `G0245D_CHIP_ID` 环境变量 / `<CHIP-ID>` | `export G0245D_CHIP_ID=<你的chip-id>` |

刷机脚本（如 `scripts/linux/flash-arm.sh`）在 `G0245D_SERIAL` 未设置时会拒绝操作，
不会误刷到别的设备——这是刻意的安全设计。

## 二、仓内不含什么（合规红线）

- **Apple 固件二进制**：kernelcache / IPSW / 系统卷（`out/ipsw/`）——受版权保护，仅本地保留。
- **OEM 固件镜像**：QFIL 的 aboot / tz / modem / NON-HLOS 等——`proprietary-files.txt`
  只记录**哈希和路径清单**，实体由使用者自行从官方渠道获取并校验。
- **原始刷机照片**、个人绝对路径、设备序列号、设备种子。

## 三、发布前自检

每次提交前跑：

```sh
python3 scripts/linux/check-public-safety.py
```

它检查四类问题：设备序列号（S+12位数字模式）、个人绝对路径（`/home/<user>/`）、
16 位数字 chip-id、以及 >2MB 的非文本文件（防止固件误入）。退出码非 0 即禁止发布。

## 四、完整复现仍需的材料

源码仓本身不足以构建固件。需要：
1. 按 `docs/pitfalls.md` 在用户目录准备工具链（clang/lld/sdk fakeroot 等）；
2. 按 `proprietary-files.txt` 准备厂商 DXE 固件（否则 `SPMI.inf is not found`）；
3. 按 `board.toml` 的 pin 获取 XNU feeds / kernelcache / DeviceTree（本地缓存在
   `unixnu-src/out/`，不进 git）。

这些材料的获取与校验流程见 `docs/xnu-materials.md`。
