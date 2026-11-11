# G0245D × UniXNU —— macOS 迁移包（2026-11-11 17:56 快照）

本包只带**无法重新下载、且续工必需**的东西：全部自研补丁、设备包、文档、判读工具、
关键镜像与原始固件。可重新 clone / 重新构建的内容一律**不带**（清单见 §4）。

> 好消息：UniXNU 的 `cli.py` 只接受 `Linux` 和 `Darwin` 两种宿主
> （`scripts/unixnu/cli.py:339-342`），**macOS 是它的原生平台**。在 macOS 上不需要
> Linux 那套伪造 fakeroot 的 `unixnu-toolchain`，直接用 Xcode + Homebrew llvm 更省事。

---

## 1. 解压后的目录

```
g0245d/
├── MIGRATION-TO-MACOS.md        ← 本文件：换机怎么恢复
├── PROGRESS-AND-ROADMAP.md      ★ 现在做到哪 + 后面怎么做（死点地图 / 决策树 / 工程债）
├── PENDING-FLASH-v137.md        ★ 唯一未验证版本的手册（刷机 / 判读 / 分支）
├── INVENTORY.txt                ← 全量文件清单 + 关键文件 md5
├── env.macos.sh                 ← macOS 环境变量模板（替换原 env.sh）
├── env.sh / setup-linux.sh      ← 原 Linux 版，仅作参考（路径写死 /home/myth）
├── src/unixnu-g0245d/
│   ├── UniXNU-g0245d/           ★ 设备包：patches/xnu/ 下 v122–v137 全部自研补丁
│   ├── UniXNU-msm8996-common/     公共设备包
│   ├── unixnu-src/                构建框架（含 .git，分支 device/g0245d-msm8996）
│   └── uefi-g0245d/
│       ├── Mu-Silicium/{BootShim,Platforms,Silicon/{Qualcomm/Msm8996Pkg, Silicium/SiliciumPkg},build_uefi.py}
│       ├── uefi-local-changes.patch   ★ UEFI 侧未提交改动（13 个文件）
│       ├── Status.md.current          UEFI 构建状态快照
│       ├── build_uefi.py.current      build_uefi.py 当前版本
│       ├── Mu-g0245d.img             编译好的 UEFI fd（948K）
│       └── Mu-g0245d-new/            新版 UEFI 工作目录
├── workspace/
│   ├── G0245D_UNIXNU_STATUS.md  ★ 主状态报告（第 17 章 = 11 月 XNU 早期诊断全过程）
│   ├── tools/                     自研工具（pack_fd.py / auto_capture_bands.py 等）
│   ├── tmp/                       判读器、补丁生成器、刷机守护脚本 + 3 个关键镜像
│   ├── firmware/g0245d/boot.img   ★ 原始 boot 分区备份（45M，救砖用）
│   ├── github/  GITHUB_UPLOAD/    四目标推送脚本与记录
│   └── build_v*.log               最近几版构建日志
├── upstream-watch/             上游巡查报告与研判（含 state.json 基线）
├── local-src/                  本地补丁源快照
├── re/  linux/                 逆向分析脚本、Linux 专用辅助脚本
└── .workbuddy/                 会话记忆
```

★ = 丢了就真没了，务必先备份这几个。

---

## 2. macOS 恢复步骤

### 2.1 装依赖

```bash
xcode-select --install                 # CLT
# 完整 Xcode 需要（构建 xnu 要用 iPhoneOS SDK / migcom / iig）
#   App Store 装 Xcode，然后 sudo xcode-select -s /Applications/Xcode.app
brew install llvm lld dtc cmake ninja python3 android-platform-tools
pip3 install numpy pillow
# EDK2 构建还要：nasm
brew install nasm
```

### 2.2 生成环境变量

```bash
cd ~/g0245d
cp env.macos.sh env.local.sh      # 然后按需改里面的路径
source env.local.sh
```

`env.macos.sh` 用 `$HOME` 做根，不再写死 `/home/myth/...`。它同时把 Homebrew 的
`llvm/bin`、`lld/bin` 放到 PATH 前面（`kernel.py:toolchain_path()` 期望的位置）。

### 2.3 恢复 UEFI（Mu-Silicium）侧

Mu-Silicium 主体没带（6.1G，可 clone）。恢复方式二选一：

**方式 A：clone 上游 + 打本包补丁（推荐，历史干净）**

```bash
cd src/unixnu-g0245d/uefi-g0245d
git clone https://github.com/Project-Silicium/Mu-Silicium.git
cd Mu-Silicium && git checkout cccd3106          # 本包导出 patch 时的 HEAD
git apply ../../uefi-local-changes.patch          # 13 个文件的本地改动
cp ../../build_uefi.py.current build_uefi.py      # 若 patch 已含此文件可跳过
```

**方式 B：直接用本包里的快照覆盖（不依赖 patch 能否应用）**

```bash
cd src/unixnu-g0245d/uefi-g0245d
git clone https://github.com/Project-Silicium/Mu-Silicium.git
cd Mu-Silicium && git submodule update --init --recursive
# 把包里这些目录整体覆盖进去：
#   BootShim/  Platforms/  Silicon/Qualcomm/Msm8996Pkg/  Silicon/Silicium/SiliciumPkg/
#   build_uefi.py
```

> 包里没带 `Mu_Basecore`、`Binaries`、`Resources`、`Silicium-ACPI`、`Common`、`Build`，
> 都是子模块或可重建产物，`git submodule update` 会拉回来。

### 2.4 恢复内核构建树

`unixnu-src/` 带了源码和 `.git`，但**没带 `out/`**（10G 的 xnu feeds 与构建产物）。

```bash
cd src/unixnu-g0245d/unixnu-src
git log --oneline -1                     # 应为 8de8c23
python3 unixnu build kernel --skip-prelink
```

第一次会重新下载/解包 xnu 源码到 `out/feeds/`（需要网络，约 6G，耗时较长）。
`out/g0245d/ipados-17.7.11-21H461/g0245d/tree/` 会被重新生成。

⚠️ 若这一步在 macOS 上报错，优先看 `scripts/unixnu/kernel.py` 的
`platform.system() == 'Linux'` 分支——macOS 走的是原生 Xcode 路径，
需要**完整 Xcode**（不只是 CLT），否则找不到 iPhoneOS SDK。

### 2.5 打包 boot 镜像并刷机

```bash
cd src/unixnu-g0245d/unixnu-src && python3 unixnu build payload --unique-chip-id 0089960000000001
cd ../../../workspace
python3 tools/pack_fd.py \
  --base tmp/g0245d-v137.img \
  --fd ../src/unixnu-g0245d/uefi-g0245d/Mu-Silicium/Build/g0245dPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd-bootshim \
  --ramdisk ../src/unixnu-g0245d/unixnu-src/out/g0245d/ipados-17.7.11-21H461/g0245d/payload/payload.img \
  --out tmp/g0245d-vNNN.img
fastboot flash boot tmp/g0245d-vNNN.img && fastboot reboot
```

> `--base` 用任意一个已能用的镜像做模板（本包带了 v127 / v131 / v137）。
> `pack_fd.py` 只替换 UEFI fd 与 ramdisk，头部结构沿用 base。

---

## 3. 当前进度（接手先看这段）

> 完整版在 `PROGRESS-AND-ROADMAP.md`（含死点地图、决策树、工程债清单）；
> 待验证版本的操作卡在 `PENDING-FLASH-v137.md`。本节只给最短摘要。

**死点已从 `arm_init()` stage 19 推进到 `arm_vm_init()` 的调用点之前**，中途真修掉两个 bug。

已验证的里程碑（帧缓冲白带判读，band 13→21）：

| band | 里程碑 | 状态 |
|---|---|---|
| 13 | `thread_bootstrap` 返回 | ✅ |
| 14 | `cpu_bootstrap` 返回 | ✅ |
| 15 | `rtclock_early_init` 返回 | ✅ |
| 16 | `kernel_debug_string_early` 返回 | ✅ |
| 17 | `kernel_startup_bootstrap` 返回 | ✅ |
| 18 | `processor_bootstrap` 返回 | ✅ |
| 19–21 | `arm_vm_init` 调用点及之前 | ❌ 全灭 |

**已修复的真 bug：**

1. **v131 — 时基为 0 导致 `timebase_callback` panic**
   `pe_identify_machine()` 开头 `if (pe_arm_get_soc_base_phys() == 0) return;`，
   该函数只在 DT 有 `name="arm-io"` 节点时成功（Apple 结构），本板没有 →
   提前返回 → `gPEClockFrequencyInfo` 全 0 → `rtclock_early_init()` 回调
   `num=0 < den=1` → `panic("rtclock timebase_callback: invalid constant")`，
   而此时无串口 → 静默挂死。补丁删掉该提前 return，让默认 24MHz 生效。
   **修完 band 一路亮到 18。**

2. **v137 — `PE_get_default()` 掉进 IOKit + `memsize` 未初始化**
   ADT 里没有 `/defaults` 节点（`hardware.dtb` 与 `make-adt.py` 都没有），
   `PE_get_default("hw.memsize", ...)` 必然走 `IODTGetDefault()` →
   `IORegistryEntry::fromPath("/defaults", gIODTPlane)`，在 `arm_init()` 阶段
   调 IOKit 注册表。且 `memsize` 是未初始化的 `uint32_t`，一旦返回 TRUE 就
   `xmaxmem = 栈垃圾`，而 `arm_vm_init()` 拿它**截断 mem_size**：
   `if (memory_size != 0 && mem_size > memory_size) mem_size = memory_size;`
   → 整个 physmap/页表几何按错误尺寸建出来。补丁删掉该分支 + 初始化 memsize。
   **v137 已构建并刷入，等一张实拍判读。**

**当前待做**：拍 v137 结果 → 按 §5 判读 → 若 K≥7 说明窗口通了、继续往
`arm_vm_init()` 内部推；若仍 K=6 则按 19/20 的亮灭定位到具体语句。

---

## 4. 刻意没带的内容（怎么重新拿）

| 内容 | 体积 | 恢复方式 |
|---|---|---|
| `workspace/tmp/ipsw-cache` | 6.4G | `unixnu` 构建时自动重新下载 IPSW |
| `workspace/tmp/tc-work` | 5.0G | 同上，工具链构建工作区 |
| `workspace/tmp/unixnu-toolchain` | 180M | **Linux 专用 fakeroot 工具链，macOS 不能用也不需要** |
| `workspace/tmp/toolchain-root` | 324M | Linux 版 flex/bison/tcsh，macOS 用 Homebrew 代替 |
| `workspace/tmp/local-src` | 301M | 由 `tools/make-local-src.sh` 重新生成 |
| `workspace/tmp/photo` | 139M | 历史照片，判读结论已落文档 |
| `src/.../unixnu-src/out` | 10G | `unixnu build kernel` 重新生成 |
| `Mu-Silicium/.git` | 3.3G | `git clone` |
| `Mu-Silicium/{Build,Mu_Basecore,Binaries,Resources,Silicium-ACPI,Common,Conf}` | ~2.2G | 子模块 / 重新构建 |
| `Mu-Silicium/Silicon/`（除两个子包） | ~609M | `git clone` |
| 历史镜像 `g0245d-v107..v136.img` | ~1.6G | 只带 v127 / v131 / v137 三个关键版 |
| 顶层 `tmp/*-probe`、`build_*.log` | ~43M | 探针截图与构建日志，可重现 |

详见仓库内 `DOWNLOADABLE.md`（上一轮 Windows→Linux 迁移时写的同类清单）。

---

## 5. 判读流程（接手必读）

内核画带的约定：`g0245d_paint_stage(N)` 在帧缓冲固定行画一条白带；
**屏幕第三组细带的亮带条数 = K = 最后到达的 band**。

```bash
python3 workspace/tmp/analyze_bands_native.py <照片路径>
```

- 主带 8 条：pitch ≈ 64 fb 行；第三组：pitch ≈ 32 fb 行（正好一半）
- **必须用原生分辨率**做行程检测，不能再缩放到固定宽度（会锚错主带 → 误报 K）
- 判读前先确认 `workspace/tmp/wait-flash-v*.log` 里已 `flash 成功` + `全部完成`，
  否则会把上一版的画面当新结论（踩过一次）

---

## 6. macOS 特有的坑

1. **`unixnu-toolchain` 是 Linux x86_64 ELF**，拷到 macOS 上跑不了，别浪费时间。
   用 Homebrew 的 llvm/lld + 完整 Xcode。
2. **必须完整 Xcode**：构建 xnu 要 iPhoneOS SDK、`migcom`、`iig`，CLT 里没有。
3. **APFS 默认大小写不敏感**：EDK2 某些目录里有仅大小写不同的文件名，
   建议把项目放在**大小写敏感的 APFS 卷**（磁盘工具 → 新建 APFS 卷 → 区分大小写）。
4. **BSD 与 GNU 工具差异**：`sed -i` 需要 `-i ''`；`md5sum` → `md5`；`stat -c` 不可用。
   本包里的 `workspace/tmp/*.sh` 是 GNU 风格，搬到 macOS 要改或用 `brew install coreutils`
   后加 `g` 前缀（`gsed`/`gmd5sum`）。
5. **fastboot**：`brew install android-platform-tools`。
6. **串口路线仍然可用**：`console=ttyHSL0,115200,n8` 已在 `board.toml` 的
   `kernel_args` 里，有 USB-串口线就能抓 printk，不必依赖拍照判读。

---

## 7. 关键文件索引

| 想看什么 | 去哪 |
|---|---|
| 11 月 XNU 早期诊断全过程 | `workspace/G0245D_UNIXNU_STATUS.md` 第 17 章 |
| 官方交接文档 / 上手步骤 | `src/unixnu-g0245d/UniXNU-g0245d/docs/bringup/README.md` §9 |
| 补丁序列与每版意图 | `src/unixnu-g0245d/UniXNU-g0245d/patches/xnu/series` |
| 最新补丁 | `patches/xnu/zzz-g0245d-v137-maxmem-path.patch` |
| 现在做到哪 / 后面怎么做 | `PROGRESS-AND-ROADMAP.md` |
| 待刷版本 v137 操作卡 | `PENDING-FLASH-v137.md` |
| 设备配置 | `src/unixnu-g0245d/UniXNU-g0245d/board.toml` |
| 刷机记录 | `workspace/tmp/wait-flash-v*.log` |
| 上游巡查 | `upstream-watch/UPSTREAM-TRIAGE-2026-11-11.md` |
| 可下载清单 | `DOWNLOADABLE.md` |
