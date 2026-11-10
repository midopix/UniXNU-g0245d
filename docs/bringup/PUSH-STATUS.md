# 推送状态（2026-11-10 19:06 全部完成）

四个目标全部推送成功，`bash workspace/github/push-now.sh` 打印 `ALL PASS`，SHA 已用 `git ls-remote` 逐个独立回验。

| 目标 | 分支 | 远端 SHA | 本次（11-10）增量 |
|---|---|---|---|
| `midopix/UniXNU-g0245d` | `main` | `d7fef62` | v122..v128 帧缓冲画带诊断补丁、`patches/xnu/series` 更正 |
| `midopix/uefi-g0245d` | `main` | `5cc6839` | 无变化 |
| `midopix/UniXNU`（fork） | `device/g0245d-msm8996` | `32207c4` | `scripts/prepare-xnu-source.py` 离线头文件 blob 校验缓存 |
| `midopix/DarwinBoot`（fork） | `g0245d-bringup` | `a7b2e17` | 无变化 |

注：表中 SHA 指本轮功能提交。设备仓在此之后还有一个只更新本文件的 docs 提交，远端 HEAD 会比 `d7fef62` 新一个提交；其余三个目标没有新增提交。

累计内容（11-09 及更早）：设备仓 payload 24 MiB、`zzz-g0245d-early-boot-marks.patch`、`docs/bringup/` 交接文档与参考补丁；UEFI 仓 `EnglishDxe`（DSC+FDF）、PMIC 按键 DTEST 修复、Msm8996 寄存器定义；UniXNU fork payload FAT32 簇数判断、`rotate=0` 语义、不转发固件 DT、notice 带原因、DarwinBoot 指针；DarwinBoot fork 窗口自适应、24bpp `DiagDraw`（走 `Gop->Blt`）、交接前大字停留、绿/红判定带。

## 本次本地提交

- `d7fef62`「xnu: add v122-v128 framebuffer stage patches for early boot hang」：8 文件、+924 行。诊断链把死点收窄到 `arm_init()`：`lr` 保存/恢复、rebase-safe 立即数、Apple 寄存器排除、可见区重映射、`arm_vm_init` 页表边界细分。v127 实拍 K=0（第三组全暗、主带与细分带仍亮）确认内核没走完 `arm_init()`。
- `32207c4`「scripts: restore XNU headers from a blob-verified offline cache」：+25/−1。重新 clone 时优先用 `.cache/sources/headers` 的 git blob SHA 校验副本，改 series 后不再依赖 GitHub 拉取 26 个头文件。

未上传（本机产物，不属于仓库边界）：`workspace/tmp/g0245d-v12*.img`、构建日志、实拍照片/视频、`out/`、`.cache/`、`local-src/`、`wait-flash-*.sh`（含设备序列号）、`.lock`，以及 `workspace/tools/` 下与剪贴板路径耦合的照片判读脚本。

- 设备仓：https://github.com/midopix/UniXNU-g0245d
- UEFI overlay：https://github.com/midopix/uefi-g0245d
- 内核包 fork：https://github.com/midopix/UniXNU/tree/device/g0245d-msm8996
- DarwinBoot fork：https://github.com/midopix/DarwinBoot/tree/g0245d-bringup

## 凭据说明（下次别再踩）

- 能写的是**用户 PAT**；GitHub **连接器是 App 安装令牌，对 `midopix/*` 只读**，写操作一律
  `403 Resource not accessible by integration`。看到这个 403 不代表 token 失效。
- PAT 只在单条命令的进程环境里出现，沙箱每次 Bash 都是新进程，命令结束即丢。
  想免去重复粘贴，写一次文件即可（在所有 git 工作树之外，不会被误提交）：

  ```bash
  install -m600 /dev/stdin ~/.workbuddy/github-token <<< '<PAT>'
  ```

## 重新推送（日常）

```bash
cd ~/WorkBuddy/2026-11-06-14-39-31/g0245d
bash workspace/github/push-now.sh                # token 从 ~/.workbuddy/github-token 读
bash workspace/github/push-now.sh <PAT>          # 或直接传
bash workspace/github/push-now.sh <PAT> --with-fork
```

脚本逐个推、推完 `git ls-remote` 回验 SHA、直连失败自动切 `127.0.0.1:7890`，
最后打印 `ALL PASS` 或失败清单；token 不落盘、不回显。

## 已存档的补丁（不依赖任何 fork，供他人复现）

`docs/bringup/` 下三份，`git apply` 即可恢复到本机当前状态：

| 文件 | 内容 |
|---|---|
| `g0245d-darwinboot.patch` | DarwinBoot：窗口自适应、24bpp DiagDraw（走 `Gop->Blt`）、交接前大字停留、绿/红判定带、诊断变量、视频非致命、`UniXNUBootDiag` 上报 |
| `g0245d-unixnu-lib.patch` | UniXNULib（Boot/Config/Inject/Internal/Main/Menu）+ `scripts/unixnu/payload.py`（FAT32 簇数判断、`rotate=0` 语义、不转发固件 DT、notice 带原因） |
| `g0245d-device-config.patch` | `board.toml`（payload 192→24 MiB）与 `patches/xnu/series` 的差异（已在主分支直接生效，仅作对照） |

Mu_Basecore `FatPkg` 的两处 `DEBUG` 插桩不在任何仓库里，属于可选诊断，代码片段见
`docs/bringup/README.md` 第 6 节。
