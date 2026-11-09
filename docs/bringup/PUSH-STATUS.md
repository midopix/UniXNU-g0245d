# 推送状态（2026-11-09 19:05 全部完成）

四个目标全部推送成功，SHA 已用 `git ls-remote` 独立回验。

| 目标 | 分支 | 远端 SHA | 内容 |
|---|---|---|---|
| `midopix/UniXNU-g0245d` | `main` | `00df1ab` | payload 24 MiB、`patches/xnu/zzz-g0245d-early-boot-marks.patch`、`docs/bringup/` 交接文档与参考补丁 |
| `midopix/uefi-g0245d` | `main` | `5cc6839` | `EnglishDxe`（DSC+FDF）、PMIC 按键 DTEST 修复、Msm8996 寄存器定义 |
| `midopix/UniXNU`（fork） | `device/g0245d-msm8996` | `d95509d` | payload FAT32 簇数判断、`rotate=0` 语义、不转发固件 DT、notice 带原因、DarwinBoot 指针 |
| `midopix/DarwinBoot`（fork，本次新建） | `g0245d-bringup` | `a7b2e17` | 窗口自适应、24bpp `DiagDraw`（走 `Gop->Blt`）、交接前大字停留、绿/红判定带、诊断变量 |

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
