# G0245D 项目交接文档 · 2026-11-09 收工

> 给"新会话的自己"看：读完这一篇就能接着干，不必回溯聊天记录。
> 详细日志在 `.workbuddy/memory/2026-11-09.md`，长期结论在 `.workbuddy/memory/MEMORY.md`。

---

## 0. 一句话现状（更新于 2026-11-11 18:00）

UEFI→内核跳转已打通（`ExitBootServices` → `kernel __start` 执行，见 §2）。内核早期经 **v122–v137 帧缓冲画带诊断**，
死点已从 `arm_init()` stage 19 附近 **推进到 `arm_vm_init()` 调用点之前**；
`rtclock_early_init` → `kernel_startup_bootstrap` → `qsort(4006 条)` → `kernel_startup_initialize_upto(LOCKS)`
这一整段已确认走通（v131 的 K=9 实拍）。期间修掉两个真 bug：**`arm-io` 缺失导致的时基 panic**（v131）、
**`PE_get_default` 早调 IOKit + 未初始化 `memsize` 截断内存**（v137）。

**v137 镜像已构建/打包（md5 `df5c40f3407e318647e5eb9d737b0816`），尚未刷入设备**——刷入后按 §10.5 的判读表定分支。
完整路线图见 `docs/bringup/PROGRESS-AND-ROADMAP.md`，待刷手册见 `docs/bringup/PENDING-FLASH-v137.md`。

> 11-09 版「卡在 `common_start` 到开 MMU 之间、v121 待刷」已过时；11-11 上午版「v128 待刷」也已过时。
> 演进见 §9（到 v128）与 §10（v129–v137）。

---

## 1. 环境速查

```bash
cd ~/WorkBuddy/2026-11-06-14-39-31/g0245d
source env.sh                       # XNU 构建必须；否则报 /opt/unixnu-linux/clang missing
export CODEBUDDY_SAFE_DELETE_BULK_THRESHOLD=20000   # 构建里的批量 rm 会被 hook 拦
```

| 用途 | 命令 |
|---|---|
| UEFI 单次构建（~40 s） | `bash workspace/tools/build-g0245d-linux.sh RELEASE` |
| 打包 + 刷 boot（自动等 fastboot） | `bash workspace/tools/finish-build.sh vNNN [--allow-same-fd]` |
| 只做 payload（24 MiB FAT） | `cd src/unixnu-g0245d/unixnu-src && ./unixnu payload -D ../UniXNU-g0245d --unique-chip-id 0089960000000001` |
| 内核构建（~14 min） | 见 §5 的三条硬规则 |
| 解码 Advanced Logger 二维码录像 | `workspace/tools/decode-advanced-log.py <mp4> --out out.log`（需 `FFMPEG_BIN=` 指向 imageio 的 ffmpeg） |

- 手机录像落在 `/home/myth/视频/`，无需网盘。
- 刷机只写 boot 分区，保留原厂 LK；刷完 `fastboot devices` 变空 = 正常开机。
- GitHub 只有 3 个仓可写：`midopix/UniXNU-g0245d`、`midopix/uefi-g0245d`、`midopix/UniXNU-msm8996-common`。
  **没有 UniXNU/DarwinBoot 的 fork**，所以这两处改动以补丁形式存在 `docs/bringup/`（见 §6）。

---

## 2. 今天打通的链路（都有实机证据）

```
LK/aboot → boot.img ramdisk 槽里的 payload(24 MiB FAT)
  → UniXNURamDiskDxe 发布 initrd BlockIo
  → DiskIoDxe → PartitionDxe（MBR 报错属误报，不影响）
  → EnglishDxe 提供 UnicodeCollation2      ← 今天补的，之前 FAT 根本绑不上
  → FatDxe 绑定成功 → SimpleFileSystem
  → UniXNU 读到 EFI\UniXNU\unixnu.toml（菜单标题变成 config: EFI\UniXNU\unixnu.toml）
  → DarwinBoot 校验内核/ADT/命令行 → 分配 56 MiB 窗口
  → ExitBootServices 成功（屏幕顶部绿带）→ br 到 kernel __start
  → 内核执行（底部白带 2 条）→ 之后静默
```

关键证据帧：`workspace/tmp/v118-probe/final.png`（绿带）、`workspace/tmp/v119-probe/band_zone.png`（两条白带）。

---

## 3. 当前断点与下一步（**11-09 当时的计划，已被 §9 取代**）

> ⚠️ 本节是 11-09 收工时的下一步清单：当时准备「刷 v121 + 看白带 stage 1–5」。
> 该计划已被 v122–v128 画带诊断取代——v121 已被 v128 取代，白带 stage 法也升级为 9 槽细分带。
> **交接请从 §9 接手。**

### 3.1 已确认

| 项目 | 结论 |
|---|---|
| `EnglishDxe` 缺失导致 FAT 不绑定 | 已修（DSC+FDF），实机验证 |
| `DarwinBoot` 拒绝调用方传设备树 | 已修（`RunXnu` 不再转发固件 FDT，它自己读 `<kernel>.adt`） |
| 视频门槛（只认 32bpp BGRA） | 已改为按帧缓冲几何描述任意位深，非致命 |
| 窗口要 256 MiB 连续段 | 已改为自适应（本机拿到 **56 MiB @ 0x95004000**） |
| 大字诊断被 24bpp 挡住 / 上下颠倒 | 已修：`DiagDraw` 走 `Gop->Blt`（面板 bottom-up 扫描，直接写帧缓冲会翻） |
| `OSLAR_EL1`（Apple 专属） | **不是**问题：stage 0 在它之后，实机画出来了 |
| BCM2837 定时器路由写 `0x40000040` | **未编译**：`XNU_NATIVE_ARCH_TIMER` 由 `XNU_ARMCPU=1` 回退为 1 |

### 3.2 待办（按顺序）

1. **刷 v121**（镜像已就绪，等手机进 fastboot）：
   ```bash
   bash workspace/tools/finish-build.sh v121 --allow-same-fd
   ```
   产物：`workspace/tmp/g0245d-v121.img`，md5 `5942bc1495d615e13f405ca7712953e4`
2. **上机看白带数量**（屏幕底部，32 行高、64 行间隔，从下往上：0,1,2,3,4,5）：

   | 出现到第几条 | 含义 | 下一个查什么 |
   |---|---|---|
   | stage 1 | 死在 `common_start` 之后第一条 | 读 `sysreg_restore` 的 TCR / `MSR TCR_EL1` |
   | stage 3 | 死在 TTBR0(`set_mmu_ttb`)/TTBR1 | `set_mmu_ttb` 的 ASID/KTRR 分支 |
   | stage 4 | 死在 MAIR 组装或 `tlbi vmalle1` | MAIR 常量、`HCR_EL2` trap 位 |
   | stage 5 | 死在 TLB/icache 失效、`VBAR_EL1` | `ExceptionVectorsBase` 换算 |
   | stage 2 | 全部设置通过，死在**开 MMU 那一刻** | `bootstrap_pagetables` 内容 / `create_bootstrap_mapping` |
3. 一旦到 stage 2 就说明 MMU 开了 → 之后必须做**内核输出通道**（见 §4），否则永远只剩白带可看。

> **判读纪律**：视频先说清分辨率与朝向，**放大裁剪到看清单条白带**再下结论。
> 今天我就是只看缩略图得出过"0 条白带 / OSLAR 非法"的错误结论，被用户纠正。

---

## 4. 内核输出通道（下一块基础设施，未开工）

本树 arm64 **没有 framebuffer 控制台**：

- `pexpert/arm64` 里对 `PE_state.video` **零引用**（只有 i386 与 32 位 arm 会写）；
- `osfmk/console/video_console.c` 的 `vc_paint_char` 只支持 8/16/30/32，**没有 24**；
- 本机面板是 **24bpp RGB888**（`FrameBufferSize 0x5EEC00 / (1080*1920) = 3`，GOP 报 `PixelBitMask`）。

要看见 panic 需要：`vc_paint_char`/`vc_render_font` 加 24bpp 分支 + arm64 把 `boot_args->Video`
接进 `PE_state.video` + 让 `vc_initialize` 拿到正确几何（注意 24bpp 下还需处理 `mFbFlip` 的行序）。
另一条路是串口 `ttyHSL0`（toml 里已带），但本机没有可用 UART。

---

## 5. 内核构建：三条硬规则（今天踩出来的）

```bash
cd src/unixnu-g0245d/unixnu-src
source ~/WorkBuddy/2026-11-06-14-39-31/g0245d/env.sh
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
export CODEBUDDY_SAFE_DELETE_BULK_THRESHOLD=20000
./unixnu build kernel -D ../UniXNU-g0245d --unique-chip-id 0089960000000001 --skip-prelink
```

1. **必须带代理**：`prepare-xnu-source.py` 要从 GitHub 抓 DriverKit 头文件，否则 `TimeoutError`
   （偶发 `SSL UNEXPECTED_EOF`，重试即可）。
2. **必须 `--skip-prelink`**：默认 prelink 产 **51 MB** 内核，payload 只有 24 MiB、boot 分区约 64 MiB，
   装不下；`--skip-prelink` 产 **18,256,840 B**，正是 payload 用的量级（kext 靠
   `CONFIG_XNU_EXTRA_LD_ARCHIVES` 强链）。
3. **内核源码改动只能走 `patches/xnu/` + `series`**：`out/feeds/xnu-b7545ced` 会被按 lock 里固定的
   commit `d8b8029` 重新克隆，**本地 commit 会被忽略**。

### 补丁为什么总有上下文冲突

`architectural-timer-entry.patch`（改 `start.s` 697 行一带）和 `apple-only-cpu-tunables.patch`
（783 行）已经在同一区域动过手。生成新补丁必须以"**前序补丁都已应用**的树"为基准：

```bash
git clone --shared src/unixnu-g0245d/unixnu-src/out/feeds/xnu-b7545ced /tmp/xb
git -C /tmp/xb checkout d8b8029
for p in architectural-timer-entry.patch apple-only-cpu-tunables.patch; do
  f=$(find src/unixnu-g0245d -name "$p" -not -path "*/out/*" | head -1); git -C /tmp/xb apply "$PWD/$f"
done
# 在该树上改 start.s，再 diff -u --label a/osfmk/arm64/start.s --label b/... 生成
git -C /tmp/xb apply --check <新补丁>   # 必须通过
```

---

## 6. 仓库与补丁分布

| 位置 | 内容 | 是否已推送 |
|---|---|---|
| `midopix/UniXNU-g0245d` | `board.toml`(payload 192→24 MiB)、`patches/xnu/zzz-g0245d-early-boot-marks.patch`、`series`、`docs/bringup/*` | 本次推送 |
| `midopix/uefi-g0245d` | `g0245d.dsc`/`g0245d.fdf`（补 `EnglishDxe`）、`KeypadDeviceLib.c`（v106 按键修复）、`Msm8996Regs.h` | 本次推送 |
| `UniXNU/DarwinBoot`（子模块） | 白带/诊断/窗口/视频全部改动 → 无 fork，**以补丁保存在** `docs/bringup/g0245d-darwinboot.patch` | 只能本地/补丁 |
| `UniXNU/UniXNU`（`unixnu-src`） | `UniXNULib`（Boot/Config/Inject/Internal/Main/Menu）、`scripts/unixnu/payload.py` → **以补丁保存** `docs/bringup/g0245d-unixnu-lib.patch` | 只能本地/补丁 |
| Mu_Basecore `FatPkg` 插桩 | 两处 `DEBUG` 打印（`FAT: start on …` / `FAT: bpb …`），纯诊断，可随时去掉 | 无仓，见下 |

`FatPkg/EnhancedFatDxe/Fat.c` 的两处插桩（供参考，非必需）：

```c
/* FatDriverBindingStart()，取到 BlockIo 之后 */
DEBUG ((DEBUG_INFO, "FAT: start on %p lastblock=0x%lx blocksize=%u present=%u\n",
        ControllerHandle, BlockIo->Media->LastBlock, BlockIo->Media->BlockSize, BlockIo->Media->MediaPresent));

/* Init.c，Volume->ClusterSize 计算之后 */
DEBUG ((DEBUG_INFO, "FAT: bpb secsize=%u spc=%u reserved=%u fats=%u sectors=0x%x spf=%u media=0x%x ext=0x%x maxcluster=%u\n", …));
```

---

## 7. 诊断设施（都在 UEFI 侧，已可用）

- 菜单**状态栏**：`drv x/y kit z | EL1 CPU1 HW1 IRQ1 TMR1 PCT…`（`EL%u` 是异常级）。
- 菜单**通知行**：`'<标题>' returned: <status> | <最后一条日志或 DarwinBoot 的诊断变量>`。
- `DarwinBoot` 失败时把一句话写进 UEFI 变量 `UniXNUBootDiag`（菜单优先显示它）。
- 各失败点用**不同 status** 区分：Not Found / Access Denied / Invalid Parameter / Load Error / Aborted / Unsupported。
- 交接前 12 秒**大字倒计时**（`DiagDraw` 走 `Gop->Blt`，24bpp 可用），交接后写**绿带**；内核写**白带**。

---

## 8. 产物清单（工作区）

| 文件 | 说明 |
|---|---|
| `workspace/tmp/g0245d-v128.img` | **待刷（取代 v121）**，md5 `5f77cf106868988973eae81e93768b2d`，56,742,220 B |
| `workspace/tmp/g0245d-v121.img` | 已废弃（被 v128 取代），md5 `5942bc1495d615e13f405ca7712953e4` |
| `workspace/tmp/g0245d-v118.img` | 已刷版本（绿带验证通过） |
| `workspace/G0245D-v119-KERNEL-MARKS.md` 等 | 各版本判读卡 |
| `workspace/incoming/7084*.mp4` | 11-09 实测录屏 |
| `workspace/build_xnu_v121.log` | 内核构建日志（含 `patch zzz-g0245d-early-boot-marks.patch`） |
| `workspace/tmp/v119-probe/band_zone.png` | 两条白带的放大证据 |
| `tools/auto_capture_bands.py` | 采集+判读脚本（probe/shot/calibrate/watch/read），11-10 新增 |
| `workspace/tmp/analyze_bands_v128.py` | 画带自适应判读引擎，11-10 新增 |
| `workspace/tmp/wait-flash-v128.sh` | v128 无限等待刷写守护，11-10 新增 |
| `patches/xnu/zzz-g0245d-v128-arm-init-substages.patch` | v128 细分带补丁（3 C 文件，零汇编），11-10 新增 |

---

## 9. 2026-11-10 / 11-11 进展：帧缓冲画带诊断与死点定位

> 完整账在 `workspace/G0245D_UNIXNU_STATUS.md` 第 17 章。本节为交接浓缩版。

### 9.1 为什么改用画带法
msm8996 上 XNU 内核早期（`arm_init` → `machine_startup`）没有串口/日志（UART 是 UEFI 阶段的事，XNU 自己的 console 还没起来）。framebuffer 是最可靠的可见信号：屏幕亮一条带 = 内核执行到了那一行。在关键路径插 `g0245d_paint_stage(index)` 涂亮带，拍照数「第三组」亮带条数 **K** 反推最后到达的代码点。

### 9.2 判读约定
- 主带 8 条（index 0..7，最靠上）= 标尺，证明画带机制在工作、屏幕没灭；
- 细分带 9 条（index 13..21，落在 `arm_init` 后段）= 逐条定位死点；
- 带不自清，K = 最后到达的细分点 − 12 = 内核走过的最后一行锚点。

| K | 含义 |
|---|---|
| 0 | 第三组全灭 → 内核连 `arm_init()` 都没走完（或画带更早失效） |
| 6 | `arm_vm_init()` 后已亮、其下全暗 → 映射在 VM 初始化处丢失 |
| 9 | 自检亮 → `arm_init()` 完成，死点推进到 `machine_startup()` 之后 |

### 9.3 演进与两处关键纠错（坑 13 / 14）
- v122 首版画带；v123–v126 在 `arm_init` 后段 + 折回 `machine_startup`/`kernel_bootstrap` 插带，逐步逼近；v126 拍到摩尔纹假象（对比度低但均值仍高，被误判）。
- v125 误判「死在 `thread_bootstrap()` 之后、`PE_init_printf()`(20) 之前、`arm_init` 已完成」——**实为误判**。
- v127 实拍 **K=0**：第三组全暗（亮度 45.2 / 白占比 0.031 / 对比度 6.3），主带与细分带仍亮 → 干净全暗，**推翻 v125「arm_init 完成」判断**：内核连 `arm_init()` 都没走完，折回的那些调用根本到不了。
- 纠错①：模板/跨版本对齐整组错配（坑 13）——改**本张照片主带当标尺**自适应定位。
- 纠错②：干净全暗 vs 摩尔纹（坑 14）——摩尔纹均值仍高（v126 亮度 147），全暗均值低；低对比度须配均值区分。

死点最终锚定 **`arm_init()` 内部 stage 19 附近**（`thread_bootstrap()` 与 `serial_init()`/`PE_init_printf()` 之间）。

### 9.4 v128：arm_init() 后段 9 槽细分（待刷）
`arm_init.c` 在 `thread_bootstrap()` → `PE_init_printf()` 窗口插 8 个细分带 index 13..20，覆盖
`machine_set_current_thread` / `cpu_bootstrap` / `kernel_startup_bootstrap` / `processor_bootstrap` /
`arm_vm_init`（页表边界） / `serial_init` / `PE_create_console`；stage 21 保留在 `arm_init` 末尾作自检。
删 v127 折回的 8 个不可达调用（内核到不了，留着只混淆「是谁画的」）。**零汇编改动**，纯 C 插桩。
补丁：`patches/xnu/zzz-g0245d-v128-arm-init-substages.patch`（3 个 C 文件）。

### 9.5 采集链路与判读自动化
本机只有 Intel IPU3（Surface 内置）复杂摄像头：`/dev/video0..3` 只出 10-bit Bayer RAW（ffmpeg 不支持）、
`video4..13` 是 M2M 节点需 media-controller 配 pipeline，且无 libcamera/media-ctl、无 UVC。
实际采用**剪贴板目录监控**（零成本）：用户上传照片自动落盘 `dir:/home/myth/.workbuddy/clipboard-images`。
- `tools/auto_capture_bands.py`：probe/shot/calibrate/watch/read；`watch` 只判新落盘照片。
- `workspace/tmp/analyze_bands_v128.py`：本张主带当标尺自适应判读，三张历史照片回测全过（v127→K=0 干净全暗；v125→K=7；v126→摩尔纹告警）。

### 9.6 v128 产物与后台守护
| 项 | 值 |
|---|---|
| `tmp/g0245d-v128.img` | 56,742,220 B |
| md5 | `5f77cf106868988973eae81e93768b2d` |
| ramdisk | 与源 `payload.img` 逐字节一致 |
| BL 命中 | 反汇编 `BL → _g0245d_paint_stage` 共 **16 处**（v127 同为 16，+8 细分/−8 折回，净持平） |

守护（持续运行，跨夜 14h 手机未连 → 无 v128 照片，正常等待）：
- `tmp/wait-flash-v128.sh`：无限等待，`flock -n` 单实例锁、5 分钟心跳；`TARGET=S002170002517`、`EXPECT_MD5=5f77cf10…`。
- `auto_capture_bands watch`（24h）监控剪贴板目录，新照片一落盘即自动判读。
**下一步只需用户按键进 fastboot**，守护自动刷 v128 并判读 K，把死点钉到 `arm_init()` 内某一行。

### 9.7 GitHub 上传（2026-11-10）
四个目标全部推送成功（`bash workspace/github/push-now.sh` → ALL PASS），SHA 用 `git ls-remote` 回验：

| 目标 | 分支 | 远端 SHA | 增量 |
|---|---|---|---|
| `midopix/UniXNU-g0245d` | `main` | `d7fef62` | v122..v128 画带诊断补丁，8 文件 +924 行 |
| `midopix/uefi-g0245d` | `main` | `5cc6839` | 无变化 |
| `midopix/UniXNU`（fork） | `device/g0245d-msm8996` | `32207c4` | prepare-xnu-source.py 离线头文件缓存 |
| `midopix/DarwinBoot`（fork） | `g0245d-bringup` | `a7b2e17` | 无变化 |

PAT 已换**长期 classic 令牌**（可不过期），存 `~/.workbuddy/github-token`（600 权限，工作树外）。

### 9.8 进度定位：对照官方 6 大步骤
| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 构建环境 / 工具链 | ✅ 完成 |
| 2 | 硅片包（UFS/显示/UART/SPMI/PMIC） | ✅ 完成 |
| 3 | 真机 UEFI 跳转 | ✅ 完成 |
| **4** | **XNU 加载 + 早期诊断（死点定位）** | **🔶 进行中** |
| 5 | 驱动适配（GPU/显示/存储/网络/音频） | ⬜ 未开始 |
| 6 | 用户态（launchd / 框架 / App） | ⬜ 未开始 |

**本阶段结论**：死点收窄到 `arm_init()` 内部 stage 19 附近；v128 已就绪待真机细分验证，是阶段 4 最后一个闭环。

---

## 10. 2026-11-11 下午—晚间：推进到 `arm_vm_init()` 调用点前，并修掉两个真 bug

§9 收在「死点 = `arm_init()` stage 19 附近、v128 待刷」。§10 记录 v128 之后实际跑完的九版：
**一次突破（v131）、两个真因修复、死点又向前推了两段**。

### 10.1 一句话现状

```
arm_init(): thread_bootstrap → cpu_bootstrap → rtclock → kernel_startup_bootstrap
            → qsort(4006) → initialize_upto(LOCKS) → processor_bootstrap   全部 ✅
            ── 窗口 A（maxmem 解析 / nano 转换 / bpret / NMI / PAN）──        ❓ v137 在这里插带
            arm_vm_init(xmaxmem, args)                                       ❌ 调用点从未亮
```

band 13–18 稳定；19/20/21 是 v137 新插的三颗探针，用来把「18 → `arm_vm_init()` 调用点」切成三段。

### 10.2 v129–v131：二分 `kernel_startup_bootstrap`，挖出时基 panic

| 版本 | 改动 | 实拍 | 结论 |
|---|---|---|---|
| v129 | 只改 `osfmk/kern/startup.c`：16=进入 bootstrap、17=n/size 过、18=qsort 返回、19=进入 `initialize_upto`、20=TIMEOUTS、21=LOCKS | **K=3** | 连函数**入口**都没亮 → 死在进入之前 |
| v130 | 16=返回自 `rtclock_early_init`、17=返回自 `kernel_debug_string_early` | **K=3** | **死在 `rtclock_early_init()` 内部** |
| **v131** | **删掉 `pe_identify_machine()` 开头的 `if (pe_arm_get_soc_base_phys() == 0) return;`** | **K=9 全亮** | **突破** |

**根因链**：本板 DT 没有 `name="arm-io"` 节点（Apple 结构）→ `pe_arm_get_soc_base_phys()` 返 0 →
提前 return → `gPEClockFrequencyInfo` 全 0（连 24 MHz 默认值都没落地）→
`rtclock_early_init()` → `PE_call_timebase_callback()` 给出 num=0/den=1 →
`timebase_callback()` 的 `num < den` 检查 `panic("invalid constant 0 / 1")`。
此时 `serial_init()` 还没跑（band 20 才到），**无控制台 → 静默挂死**。

> 附带隐患（未修，暂无影响）：`/cpus` 的 `timebase-frequency = 0x124f800` 实际没被用上——
> 代码逐 `cpu@N` 节点读 `state`，本板没有该属性，所以只会用默认 24 MHz。
> 若日后需要精确 19.2 MHz，得给 cpu 节点补 `state = "running"`。

### 10.3 v132–v136：探针索引撞车 → 重建单调阶梯 → 锁定 `arm_vm_init`

v128 在 `arm_init` 留了 17–21，v129 又在 `startup.c` 用了 18–21，**索引撞车**导致「9 条全亮」
无法区分是谁画的。v132 起重建单一阶梯并清空 `startup.c` 探针。

| 版本 | 探针 | 实拍 | 结论 |
|---|---|---|---|
| v132 | 13–21 单调阶梯，19=arm_vm_init 返回、20=serial_init、21=arm_init 末尾 | **K=6** | 13–18 亮、**19 灭** |
| v133 | 19/20/21 改用 physmap 画带（`gVirtBase+(0x83401000−gPhysBase)`），避开 TTBR0 切换 | **K=6** | 19 仍灭 |
| v134 | 探针塞进 `arm_vm_init()` 内部（19=`arm_set_user_tbi` 前、20=`set_mmu_ttb_alternate` 前），用老画带函数 | **K=6** | **19 灭 → 函数体内真崩，非画带失效** |
| v135 | 前段再加 21（`gPhysSize/mem_size` 之后） | **K=6** | 连函数第 ~6 句都没到 |
| v136 | 21 移到**调用点前一行**（`arm_init.c`） | **K=6** | **调用点都没到 → 死在调用之前** |

**排除的两个假设**：`BOOTSTRAP_TABLE_SIZE` 太小（`native-4k-bootstrap-capacity.patch` 已应用，
4K 下 16 页 > 4 GB 所需的 12 页）；内核体积截断（18,275,728 B / payload 24 MiB，富余充足）。

**方法论纠错**：判读器一度硬编码主带 pitch 18–27 px，近距拍摄实测 60.5 px → 报「找不到主带」
或锚到细分带链误报 K。必须用**原生分辨率行程检测**（`workspace/tmp/analyze_bands_native.py`），
不能缩放到固定宽度。

### 10.4 v137：`arm_vm_init()` 调用点前的两个真缺陷

窗口 A 不止 maxmem 三行，实际含 `PE_parse_boot_argn("maxmem")`、`PE_get_default("hw.memsize")`、
`nanoseconds_to_absolutetime(XCALL_ACK_TIMEOUT_NS,…)`、`set_bp_ret()`、`immediate_NMI`、`__builtin_arm_wsr("pan",1)`。

**缺陷 1 — `PE_get_default()` 掉进 IOKit 注册表**
`pexpert/gen/bootargs.c:507` 先查 `SecureDTLookupEntry(NULL,"/defaults")`，查不到就走
`IODTGetDefault()` → `IORegistryEntry::fromPath("/defaults", gIODTPlane)`
（`iokit/Kernel/IODeviceTreeSupport.cpp:379`）。本板 ADT（`hardware.dtb` / `make-adt.py`）
**既无 `/defaults` 也无 `/chosen`**，必然走这条 —— 在 `arm_init()` 阶段调 IOKit。

> 澄清：该函数结尾 `return IODTGetDefault(...) ? FALSE : TRUE;` **不是 bug**
> （`IODTGetDefault` 成功返 0、失败返 −1，三元条件语义正确）。

**缺陷 2 — `memsize` 未初始化，`xmaxmem` 会截断内核物理内存**

```c
uint32_t memsize;                      /* arm_init.c:379，未初始化 */
xmaxmem = (uint64_t) memsize;          /* 若上面返回 TRUE，就是栈垃圾 */

/* arm_vm_init()： */
if ((memory_size != 0) && (mem_size > memory_size)) {
        mem_size = memory_size;        /* ← 用垃圾值砍小 mem_size */
        max_mem_actual = memory_size;
}
```

偏小的垃圾值会把 `mem_size` 砍小 → `physmap_base`、`dynamic_memory_begin`、bootstrap 页表几何
全按错误尺寸建出来 → 随后必崩。

**v137 改动**（`patches/xnu/zzz-g0245d-v137-maxmem-path.patch`，65 行）：删掉 `PE_get_default` 分支
（`xmaxmem = 0`，让 `arm_vm_init()` 用 `args->memSize`）、`uint32_t memsize = 0;`；
探针重排为 **19=maxmem 后 / 20=nano 后 / 21=调用点**，并撤掉 `arm_vm_init.c` 里旧的 19/20。

### 10.5 判读表（v137，刷入后照此定分支）

| K | 亮到 | 结论 | 下一版 |
|---|---|---|---|
| 6 | 18 | 死在 `PE_parse_boot_argn("maxmem")` 内 | 连 maxmem 解析也去掉；仍 6 则把 19 提前到 `processor_bootstrap()` 后第一行再二分 |
| 7 | 19 | 死在 sched-hygiene / `nanoseconds_to_absolutetime` / bpret / NMI / PAN 这组 | 逐条 `#if 0`（先 `set_bp_ret`，再 PAN） |
| 8 | 20 | 只差最后几句 | 同上 |
| 9 | 21 | **窗口通了** → 原来灭的就是 `PE_get_default` | 探针移进 `arm_vm_init()` 内部继续推 |

> ⚠️ 若仍 K=6，**不要再往 `arm_vm_init()` 内部猜**——v134–v136 已三次证明函数内部也灭、调用点也灭。

**`arm_vm_init()` 内部的注意事项**：`set_mmu_ttb(invalid_ttep)` + `flush_mmu_tlb()` + `kva_active = TRUE`
之后 bootstrap V=P 映射失效，写 `VA 0xC3401000` 必 fault，只能改用 physmap 画带（v133 的
`g0245d_paint_stage_vm`）。源码注释原话：*"From here on out, we're off the bootstrap translation tables."*

### 10.6 策略转折点（下一步最重要的判断）

`serial_init()` 一通，就**把调试手段从「屏幕画带 + 拍照判读」切换到「串口 printk」**。
`console=ttyHSL0,115200,n8` 已在 `board.toml` 的 `kernel_args` 里，只需一根 USB-串口线。
这能省掉后续几十轮「编译→刷机→拍照→判读」。

### 10.7 新增文档

| 文件 | 用途 |
|---|---|
| `docs/bringup/PROGRESS-AND-ROADMAP.md` | 死点地图、决策树、阶段 5/6 任务清单、**工程债 6 项**（探针污染 / 补丁膨胀 / 未提交 / 上游 rebase / 文档口径 / 判读器鲁棒性） |
| `docs/bringup/PENDING-FLASH-v137.md` | v137 的刷机三种方式、判读表、几何自检、设备救援 |
| `docs/bringup/MIGRATION-TO-MACOS.md` | 换到 macOS 的恢复步骤（依赖、构建、刷机、macOS 专有坑） |
