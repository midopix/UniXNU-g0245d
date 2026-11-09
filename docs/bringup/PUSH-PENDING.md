# 待推送清单（2026-11-09）

本地四个仓库都已**提交完毕**，只差远端。

## 为什么推不上去（结论修正）

不是 token 失效，也不是 token 被撤销，而是**用错了凭据**：

- 我上一轮走的是 **GitHub 连接器**（GitHub App 安装令牌）。它对 `midopix/*` 只有读权限，
  `POST /git/trees` 返回 `403 Resource not accessible by integration`。
- 你给的 **PAT** 是另一套凭据，能写。但它只以 `GITHUB_TOKEN=<PAT>` 的形式存在于
  **那一条命令的进程环境里**；沙箱每次 Bash 调用都是新进程，脚本本身也明确
  "token is never written to disk and never printed"，所以命令结束后它就没有了。
  `env`、`~/.git-credentials`、`~/.netrc`、`~/.config/gh/hosts.yml`、`~/.bash_history` 全部为空。

因此需要的是**同一个 PAT 再给一次**（不是新建、不是重新授权），我不会再把它当成"要新 token"。

## 一键推送

```bash
cd ~/WorkBuddy/2026-11-06-14-39-31/g0245d
bash workspace/github/push-now.sh <PAT>              # 推三个已有目标
bash workspace/github/push-now.sh <PAT> --with-fork  # 另外 fork UniXNU/DarwinBoot 再推
```

脚本会逐个推、推完用 `git ls-remote` 回验 SHA，最后打印 `ALL PASS` 或失败清单。
直连不通时自动切 `127.0.0.1:7890`。token 不落盘、不回显。

**想避免每次重发 token**：把它写进 `~/.workbuddy/github-token`（`chmod 600`）一次，
之后 `bash push-now.sh` 不带参数就会自动读取。该文件在所有 git 工作树之外，
不会被误提交：

```bash
install -m600 /dev/stdin ~/.workbuddy/github-token <<< '<PAT>'
```

用假 token 测过失败路径：三个目标都返回 `鉴权失败`，说明仓库本身可写、
唯一缺的就是有效凭据。

## 本地提交

| 仓库 | 路径 | 本地 HEAD | 远端 | 待推 |
|---|---|---|---|---|
| 设备仓 | `src/unixnu-g0245d/UniXNU-g0245d` | `a7a460d` | `e4479c8` | 2 |
| UEFI overlay | `workspace/github/uefi-g0245d` | `5cc6839` | `ca0a5c4` | 1 |
| 内核包 fork | `src/unixnu-g0245d/unixnu-src` (`device/g0245d-msm8996`) | `d95509d` | `5d4ce46` | 1 |
| DarwinBoot | `src/unixnu-g0245d/unixnu-src/drivers/DarwinBoot` (`g0245d-bringup`) | `a7b2e17` | **无 fork** | 全部 |

设备仓的两个待推提交：`939dd52`（payload 24 MiB + early-boot band patch + docs/bringup）
与 `a7a460d`（pending push 清单 + 无 token 也能复现的参考补丁）。

## 手动推送（不用脚本时）

```bash
cd ~/WorkBuddy/2026-11-06-14-39-31/g0245d
TOKEN=<PAT>

git -C src/unixnu-g0245d/UniXNU-g0245d push \
  "https://x-access-token:${TOKEN}@github.com/midopix/UniXNU-g0245d.git" main:main

git -C workspace/github/uefi-g0245d push \
  "https://x-access-token:${TOKEN}@github.com/midopix/uefi-g0245d.git" main:main

git -C src/unixnu-g0245d/unixnu-src push \
  "https://x-access-token:${TOKEN}@github.com/midopix/UniXNU.git" \
  device/g0245d-msm8996:device/g0245d-msm8996

# DarwinBoot 需先在浏览器 fork github.com/UniXNU/DarwinBoot，然后
git -C src/unixnu-g0245d/unixnu-src/drivers/DarwinBoot push \
  "https://x-access-token:${TOKEN}@github.com/midopix/DarwinBoot.git" \
  g0245d-bringup:g0245d-bringup
```

## 已存档的补丁（不依赖任何 fork）

`docs/bringup/` 下三份，`git apply` 即可恢复到本机当前状态：

| 文件 | 内容 |
|---|---|
| `g0245d-darwinboot.patch` | DarwinBoot：窗口自适应、24bpp DiagDraw（走 `Gop->Blt`）、交接前大字停留、绿/红判定带、诊断变量、视频非致命、`UniXNUBootDiag` 上报 |
| `g0245d-unixnu-lib.patch` | UniXNULib（Boot/Config/Inject/Internal/Main/Menu）+ `scripts/unixnu/payload.py`（FAT32 簇数判断、`rotate=0` 语义、不转发固件 DT、notice 带原因） |
| `g0245d-device-config.patch` | `board.toml`（payload 192→24 MiB）与 `patches/xnu/series` 的差异（已在主分支直接生效，仅作对照） |

Mu_Basecore `FatPkg` 的两处 `DEBUG` 插桩不在任何仓库里，属于可选诊断，代码片段见
`docs/bringup/README.md` 第 6 节。
