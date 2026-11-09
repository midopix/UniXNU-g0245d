# G0245D v119 判读卡 —— 内核早期进度白带（数白带定位死在哪一步）

日期：2026-11-09 17:08
镜像：`workspace/tmp/g0245d-v119.img`，56,742,220 B，md5 `1731eb6580734056f4512eaa72c11809`
内核：`kernel.macho` 18,256,840 B，sha256 `cd1f1af5…`（含白带补丁）
状态：**已刷入**（FLASH_RC=0 / REBOOT_RC=0）

---

## 一、上一版（v118）已确认的事实

绿带出现在屏幕顶部 → `ExitBootServices` 成功 → 已跳进内核 `__start`，之后静默。
屏幕上的数值与本地 Mach-O 解析逐项吻合（`ENTRY PA 0x95418488` = base `0x95004000` + `0x414488`）。

所以现在唯一缺的是：**内核跑到哪一步了**。

## 二、v119 加了什么

`osfmk/arm64/start.s` 新增 `BOOT_MARK` 宏：**在 MMU 打开之前**直接往固件帧缓冲写一条
32 行高的纯白横带（boot_args->Video 是物理地址，此刻可以裸写）。三个阶段各一条：

| 白带 | 触发点 | 含义 |
|---|---|---|
| ① | `start_first_cpu` 第一条指令后 | 内核入口真的执行了 |
| ② | `common_start`（引导页表建好） | 页表/CPU 寄存器准备通过 |
| ③ | `MSR SCTLR_EL1`（开 MMU）之前 | 即将打开 MMU |

白带画在 raw 第 200/232/264 行起（避开顶部绿色 hand-off 带；面板是 bottom-up 扫描，
所以它们会出现在屏幕**下半部**、由下往上排列）。

补丁位置：`UniXNU-g0245d/patches/xnu/zzz-g0245d-early-boot-marks.patch`（已加入 `series`），
这是持久位置，`./unixnu fetch` 重新拉源码也不会丢。

## 三、下次判读：数白带

| 白带数 | 结论 | 下一步 |
|---|---|---|
| **3 条** | 走到"开 MMU"，死在 MMU 之后（`arm_init` / `arm_vm_init`） | 必须给内核接真正的输出通道（`video_console` 24bpp + arm64 填 `PE_state.video`）|
| **2 条** | 死在 `common_start` → 开 MMU 之间 | 查 TCR/TTBR/MAIR 与 `SCTLR_EL1_DEFAULT` |
| **1 条** | 死在 `start_first_cpu` 最早段 | 查 boot_args 读取（`BA_VIRT_BASE`/`BA_PHYS_BASE`）或 `LowExceptionVectorBase` |
| **0 条** | 入口都没执行到 | 回查 `DarwinEnter` 与 SCTLR 关闭顺序 |

配合看：顶部绿带（loader 画的）依旧会先出现；白带在它下面。

## 四、这一轮顺带解决的两个构建坑（重要，别再踩）

1. **内核构建必须走代理**：`prepare-xnu-source.py` 要从 GitHub 抓 DriverKit 头文件，
   不设代理会 `TimeoutError: read operation timed out`：
   ```bash
   export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
   ```
2. **内核必须用 `--skip-prelink`**：
   - `./unixnu build kernel` 默认走 prelink，产出 **51 MB**（把整套 kext 都链进去了）；
   - `--skip-prelink` 产出 **18,256,840 B**，与之前 payload 里的一致；
   - payload 只有 24 MiB、boot 分区约 64 MB，51 MB 内核根本装不下（镜像会到 ~90 MB）。
   所以本项目的 payload 路线一直用的是**原生内核**（kext 由 `CONFIG_XNU_EXTRA_LD_ARCHIVES` 强链）。
3. **内核源码改动不能提交到 feed 仓**：`out/feeds/xnu-b7545ced` 会被按 lock 里固定的
   commit（`d8b8029`）重新克隆，本地 commit 会被忽略；必须走 `patches/xnu/<name>.patch`
   + 加进 `series`。

## 五、关于"内核输出通道"的预研结论

本树 arm64 **没有 framebuffer 控制台**：
- `pexpert/arm64` 里对 `PE_state.video` 零引用（只有 i386 与 32 位 arm 会写它）；
- `osfmk/console/video_console.c` 的 `vc_paint_char` 只支持 8/16/30/32，**没有 24**；
- 我们的面板是 24bpp RGB888。

因此若白带显示"3 条"，下一步就是：给 `vc_paint_char` / `vc_render_font` 加 24bpp 分支，
在 arm64 上把 `boot_args->Video` 接进 `PE_state.video`，并让 `vc_initialize` 拿到正确几何。
这是本阶段最后一块基础设施，也是之后能看见 panic 的唯一途径。
