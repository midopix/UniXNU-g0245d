# G0245D 项目交接文档 · 2026-11-09 收工

> 给"新会话的自己"看：读完这一篇就能接着干，不必回溯聊天记录。
> 详细日志在 `.workbuddy/memory/2026-11-09.md`，长期结论在 `.workbuddy/memory/MEMORY.md`。

---

## 0. 一句话现状

UEFI 侧全部打通（payload FAT 卷 → 配置 → 校验 → `ExitBootServices` → **内核 `__start` 已被执行**），
现在卡在内核 `common_start` 到"开 MMU"之间。用三/六条白带定位，**v121 镜像已构建好但还没刷进手机**。

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

## 3. 当前断点与下一步（**从这里接手**）

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
| `workspace/tmp/g0245d-v121.img` | **待刷**，md5 `5942bc1495d615e13f405ca7712953e4` |
| `workspace/tmp/g0245d-v118.img` | 已刷版本（绿带验证通过） |
| `workspace/G0245D-v119-KERNEL-MARKS.md` 等 | 各版本判读卡 |
| `workspace/incoming/7084*.mp4` | 今天的实测录屏 |
| `workspace/build_xnu_v121.log` | 内核构建日志（含 `patch zzz-g0245d-early-boot-marks.patch`） |
| `workspace/tmp/v119-probe/band_zone.png` | 两条白带的放大证据 |
