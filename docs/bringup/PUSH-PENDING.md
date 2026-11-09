# 待推送清单（2026-11-09）

本地四个仓库都已**提交完毕**，只差远端。GitHub App 令牌对 `midopix/*` 只有读权限
（`POST /git/trees` 返回 403 Resource not accessible by integration），
所以需要一次性 PAT（classic，勾 `repo`）才能推。

## 本地提交

| 仓库 | 路径 | 提交 |
|---|---|---|
| 设备仓 | `src/unixnu-g0245d/UniXNU-g0245d` | `939dd52` payload 24 MiB + early-boot band patch + docs/bringup |
| UEFI overlay | `workspace/github/uefi-g0245d` | `5cc6839` EnglishDxe + PMIC key DTEST fix + Msm8996 regs |
| 内核包（fork） | `src/unixnu-g0245d/unixnu-src` | `d95509d` payload FAT32 sizing / menu rotate=0 / DarwinBoot hand-off fixes |
| DarwinBoot（子模块） | `src/unixnu-g0245d/unixnu-src/drivers/DarwinBoot` | `a7b2e17` bring-up diagnostics |

## 一键推送（给 token 后）

```bash
cd ~/WorkBuddy/2026-11-06-14-39-31/g0245d
TOKEN=<PAT>

# 1. 设备仓
git -C src/unixnu-g0245d/UniXNU-g0245d push \
  "https://x-access-token:${TOKEN}@github.com/midopix/UniXNU-g0245d.git" main:main

# 2. UEFI overlay
git -C workspace/github/uefi-g0245d push \
  "https://x-access-token:${TOKEN}@github.com/midopix/uefi-g0245d.git" main:main

# 3. 内核包 —— 需要先有 fork（当前没有）；有二选一：
#    a) 在浏览器里 fork github.com/UniXNU/UniXNU，然后
#       git -C src/unixnu-g0245d/unixnu-src push \
#         "https://x-access-token:${TOKEN}@github.com/midopix/UniXNU.git" \
#         device/g0245d-msm8996:device/g0245d-msm8996
#    b) 不 fork：两份补丁已在 docs/bringup/ 里存档（见下），够别人复现
# 4. DarwinBoot 同理：fork github.com/UniXNU/DarwinBoot 后推 g0245d-bringup
#    （无 fork 时同样以 docs/bringup/g0245d-darwinboot.patch 存档）
```

推送前如需走代理：`export https_proxy=http://127.0.0.1:7890`。

## 已存档的补丁（不依赖任何 fork）

`docs/bringup/` 下三份，`git apply` 即可恢复到本机当前状态：

| 文件 | 内容 |
|---|---|
| `g0245d-darwinboot.patch` | DarwinBoot：窗口自适应、24bpp DiagDraw（走 `Gop->Blt`）、交接前大字停留、绿/红判定带、诊断变量、视频非致命、`UniXNUBootDiag` 上报 |
| `g0245d-unixnu-lib.patch` | UniXNULib（Boot/Config/Inject/Internal/Main/Menu）+ `scripts/unixnu/payload.py`（FAT32 簇数判断、`rotate=0` 语义、不转发固件 DT、notice 带原因） |
| `g0245d-device-config.patch` | `board.toml`（payload 192→24 MiB）与 `patches/xnu/series` 的差异（已在主分支直接生效，仅作对照） |

Mu_Basecore `FatPkg` 的两处 `DEBUG` 插桩不在任何仓库里，属于可选诊断，代码片段见
`docs/bringup/README.md` 第 6 节。
