# 早启动死点追查：v137 → v139（更新至 2026-11-13 21:00，v139 待刷入）

> 这份文档从 v137 一路追加到 v139：一、二节是 v137 的原始说明，六节起是实机判读与后续改版。
> 当前状态：PAN 根因已确认（v138 实机坐实），v139 换成整屏颜色探针，等一次刷机 + 一张照片定新死点。

---

## 一、这是什么

v137 = 在 v136 基础上做两件事：

1. **删掉 `PE_get_default("hw.memsize", ...)` 分支**（`arm_init.c`）
   本板 ADT 没有 `/defaults`，这个调用必然掉进 `IODTGetDefault()` →
   `IORegistryEntry::fromPath("/defaults", gIODTPlane)`，即在 `arm_init()` 阶段调 IOKit 注册表。
   改为 `xmaxmem = 0`，让 `arm_vm_init()` 用 `args->memSize`。
2. **`uint32_t memsize;` → `= 0`**
   原代码未初始化，若上面那个调用返回 TRUE 就会 `xmaxmem = 栈垃圾`，
   而 `arm_vm_init()` 用它**截断** `mem_size`（`if (memory_size != 0 && mem_size > memory_size) mem_size = memory_size;`），
   内存几何会被按错误尺寸建出来。

探针重排（band 13–18 与 v136 相同）：

| band | 位置 |
|---|---|
| 19 | `maxmem` 解析块之后 |
| 20 | `nanoseconds_to_absolutetime(XCALL_ACK_TIMEOUT_NS, ...)` 之后 |
| 21 | `arm_vm_init(xmaxmem, args)` **调用点前一行** |

同时撤掉了 `arm_vm_init.c` 里 v134 留的旧 19/20，避免索引撞车。

---

## 二、产物与校验

| 项 | 值 |
|---|---|
| 镜像 | `workspace/tmp/g0245d-v137.img` |
| 大小 | 56,742,220 字节 |
| **md5** | **`df5c40f3407e318647e5eb9d737b0816`** |
| kernel.macho sha256 | `74571685f7d7e66a80d82a2c55eb6f7cc034d9ab4d7c07df7e372cc9a2ca4422` |
| 补丁 | `src/unixnu-g0245d/UniXNU-g0245d/patches/xnu/zzz-g0245d-v137-maxmem-path.patch`（65 行） |
| 构建日志 | `workspace/tmp/build_v137_kernel.log` / `build_v137_payload.log` |
| 打包校验 | `pack_fd.py` 输出 `校验 : OK` |

刷前自检：

```bash
md5sum workspace/tmp/g0245d-v137.img
# 应为 df5c40f3407e318647e5eb9d737b0816
```

---

## 三、刷入（三种方式，任选）

### 方式 A：设备已在 fastboot（最快）

```bash
cd workspace/tmp
fastboot devices                       # 应看到 S002170002517
fastboot flash boot g0245d-v137.img
fastboot reboot
```

### 方式 B：挂守护，等设备进 fastboot 自动刷

```bash
cd workspace/tmp
bash wait-flash-v137.sh                # 无限等待，5 分钟一次心跳
```

脚本行为：`flock` 单实例锁 → 只认 serial `S002170002517` → 刷前校验 md5 →
`fastboot flash boot` → 校验返回值 → `fastboot reboot` → 退出码 0。

看进度：

```bash
tail -f workspace/tmp/wait-flash-v137.log
```

**判读前必须确认日志里有这两行**：

```
[wait-flash-v137] flash 成功，重启设备
[wait-flash-v137] 全部完成 2026-11-11 HH:MM:SS
```

否则说明还没刷，照片是上一版的画面（这个坑踩过一次）。

### 方式 C：macOS 上

先 `brew install android-platform-tools`，其余命令相同。
守护脚本是 GNU bash 风格，macOS 自带 bash 3.2 通常能跑；若报错就直接走方式 A。

### 设备卡住进不去 fastboot 时

1. 长按电源 **15 秒**（不行就 30 秒）直到黑屏/振动
2. 立刻**按住音量下不放** → 短按电源 → 保持音量下 10–15 秒 → 进 fastboot
3. 插 USB
4. 最坏情况走 EDL（`lsusb` 见 `05c6:9008`）

救砖用原始固件：`workspace/firmware/g0245d/boot.img`（md5 `b5fada69c802a9300b23a2bac71df3b7`）。

---

## 四、刷完怎么拍、怎么判

设备重启后会自动：DarwinBoot 12 秒倒数（屏幕显示 `HANDOFF IN 1 s - PHOTO NOW`，
**这段没有按键处理，别按键**）→ 绿带 → 跳内核 → 画带 → 冻住。

**拍冻住后的屏幕**（画面会是「菜单最后一帧 + 白带叠加」，这是正常的，因为 paint 不清屏），然后：

```bash
python3 workspace/tmp/analyze_bands_native.py <照片路径>
```

### 判读表

| K | 亮到 band 21? | 结论 | 下一版 |
|---|---|---|---|
| **6** | ❌ 19 也灭 | 死在 `PE_parse_boot_argn("maxmem")` 内部 | v138：连 maxmem 解析也去掉；若仍 6，把 19 提前到 `processor_bootstrap()` 后第一行再二分 |
| **7** | ❌ 20 灭 | maxmem 过了；死在 sched-hygiene / `nanoseconds_to_absolutetime` / `set_bp_ret` / `immediate_NMI` / PAN 这组 | v138：先 `#if 0` 掉 `set_bp_ret()` 整段，再单独去 PAN |
| **8** | ❌ 21 灭 | 只差最后几句（bpret / NMI / PAN） | v138：同上逐条禁 |
| **9** | ✅ 全亮 | **窗口通了** → 原来的灭就是 `PE_get_default` 本身 | v138：探针移进 `arm_vm_init()` 内部（进入点 / 页表建好 / TTBR 切换前） |

> 若结果还是 K=6，**不要再往 `arm_vm_init()` 内部猜**——v134–v136 已经三次证明
> 「函数内部也灭、连调用点都灭」，那就一定是窗口 A 里更早的语句，或者画带机制本身失效
> （后者已被 v133 的 physmap 版本基本排除）。

### 判读几何自检（防止误判）

- 主带 8 条，pitch ≈ 64 fb 行（近距照片实测约 59–69 px）
- 第三组细带 pitch ≈ 32 fb 行（正好是主带一半，实测约 30 px）
- 亮带应是 **peak 白占比 ≈ 1.00** 的纯白条；若 peak 只有 0.5 左右且条纹紊乱，那是拍屏摩尔纹，重拍

---

## 五、刷完之后要顺手做的

1. 记忆/文档同步：`workspace/G0245D_UNIXNU_STATUS.md` 第 18.5 节表格补上实拍结果
2. 若通过窗口 A：把 `g0245d_paint_stage_vm()` 的使用范围确认清楚（TTBR 切换后只能用它）
3. 每次只动一条嫌疑，别一次改多处——否则判读又变成猜

---

## 六、v137 判读结果（2026-11-13，已定案）

**K=8**：主带 0..7 全亮、子带 8..12 全亮、细带 13..20 全亮、**band 21 暗**。
死点 = `arm_init.c` stage 20 与 stage 21 之间。

### 判读几何更正（读 start.s 汇编确认，推翻此前 C 注释版理解）

| 带组 | 索引 | fb 行 | 高度 | 屏幕位置（**本面板 fb 行与 y 颠倒**） |
|---|---|---|---|---|
| 主带 | 0..7 | 200+64i | 32 | 中部（8 条，pitch≈2×细带） |
| 子带 | 8..12 | 8+40(i-8) | 24 | **底部**（v137 照片 y1819..1997，9 号被彩条遮） |
| 细带 | 13..21 | 700+32(i-13) | 16 | 细带组上方 |

### 根因（石锤）

arch 层 `common.config` 开 `CONFIG_XNU_NATIVE_PAN=y` → `native-arm-pan.patch`
往 `BCM2837.h` 注入 `__ARM_PAN_AVAILABLE__=1` → `arm_init.c` 在 stage20/21 之间
执行 `__builtin_arm_wsr("pan", 1)`（MSR PAN）→ **Kryo 是 ARMv8.0，无 PAN**
→ 未定义指令异常 → 冻屏。窗口里其余语句全部安全（PE_parse_boot_argn 在
stage 19 已跑过；HAS_BP_RET 未定义被编出）。

### v138

`configs/g0245d_defconfig` 关闭 `CONFIG_XNU_NATIVE_PAN`（唯一嫌疑，一次改一处）。
构建：`bash linux/build-v138-all.sh`（clang 续编 → 内核 → payload → 复用 v137 FD 打包）。

---

## 七、v137 判读结果与 v138 的构建记录（2026-11-13）

- v137 判读 **K=8**、PAN 根因见第六节（两次独立拍照一致，判读器 analyze_bands_native.py 稳定复现）。
  下半屏横纹是 handoff 后 XNU 早死、UEFI 菜单帧残留在 framebuffer 的表现。
- **v138（已刷入，已判读，见第八节）**：唯一改动 = `g0245d_defconfig` 加
  `# CONFIG_XNU_NATIVE_PAN is not set`（.config 已验证 XNU_NATIVE_PAN=False）。
  内核 native-only 形态与 v137 相同（kernel.macho 18,274,672B vs v137 18,275,728B）。
  - v138.img：`workspace/tmp/g0245d-v138.img`，md5 `25b664e3a4267a238b1a48368a2c2054`，
    2026-11-13 16:54 全 OKAY 刷入（只刷 boot）+ reboot。
  - 全流程已固化在 `linux/build-v138-all.sh`（含 UNIFDEF/PLUTIL 直传、make setup、
    skip-prelink payload、zlib 单成员解 FD）。
- **判读预期**：若 K 前进（>8）→ PAN 根因证实；仍 K=8 → PAN 排除，回决策树（见第六节）。

---

## 八、v138 实机结果与 v139（2026-11-13 17:30）

### v138 现象（与 v137 不同，是关键进展）
- 照片：handoff 画面正常（UniXNU 0.1.0 / WINDOW 0x3800000 ENTRY PA 0x95419488 /
  ARGS 0x96244000 DT 0x96245000 + 0x32B8 / "HANDOFF IN 1 s - PHOTO NOW"，
  DebugInfOD 显示 DTB found SAMSUNG 5117q2025、video base=0x63a01000 display=1
  row=3260 width=1080 height=1920、4 inputs validated、exiting boot services），
  倒计时结束后交付 XNU，随后**整屏变黑**（v137 是冻在 K=8 白带画面）。
- 判读：**不是同一个死点**。stage21 就在 `arm_vm_init()` 调用点之前（见 v136 patch），
  v137 死在 stage20/21 之间（PAN）；v138 关掉 PAN 后**越过了该点，进入 arm_vm_init 及以后**。
- 黑屏的两种解释（累计白带无法区分）：
  a) 死得更早（什么都没画）；b) 跑得更远，`PE_create_console()` / vc 把 framebuffer 清空。
  注意 arm_init.c 里 `serial_init()` → `PE_create_console()` 就紧邻在 arm_vm_init 之后，
  vc 初次初始化会整屏清除，因此 (b) 的可能性很高。

### v139 方案：整屏颜色编码探针（抗清屏）
每到一个阶段就把**整块 framebuffer**刷成一种纯色（再叠一条白带保留旧判读能力），
屏幕最后停留的颜色 = 最后执行到的阶段：

| 颜色 | 阶段 | 含义 |
|---|---|---|
| 黄 | 21 | 进 `arm_vm_init()` 之前（仍在 bootstrap VA 0xC3401000 上写） |
| 红 | 22 | `arm_vm_init()` 已返回（改用 physmap 写） |
| 绿 | 23 | `serial_init()` 已返回 |
| 蓝 | 24 | `PE_create_console()` 已返回 |
| 白 | 25 | 即将进 `machine_startup()` |
| 全黑 | — | 已越过白点（进 machine_startup 之后），或被更晚代码清屏 |

实现：`osfmk/arm/arm_init.c` 新增 `g0245d_fill_fb()` / `g0245d_stage_color()` /
`g0245d_mark_va()` / `g0245d_mark_vm()`；补丁备份
`patches/xnu/zzz-g0245d-v139-color-stages.patch`。
构建：`linux/build-v139-all.sh`（去掉 v138 脚本里重复的 payload 步骤）。
判读：`analyze_color_stage.py <照片>`（本机在 `workspace/tmp/`，仓库内是 `scripts/linux/`；深灰判黑、低饱和高亮判白、否则按主通道定色）。

### 尚未排除的干扰项
- 若 v139 仍全黑，需检查 `PE_create_console()` 是否有无条件清屏/初始化显示的动作，
  以及 `machine_startup` 里 vc 的初始化路径；届时把探针挪到清屏之后。

---

## 九、v139 产出（2026-11-13 17:42，待刷入）

- **镜像**：`workspace/tmp/g0245d-v139.img`，md5 **`35b177a954bf5692854e05cecf2332d1`**，56,742,220 B。
  内核 kernel.macho sha256 `56ded44a77139e93…`（native-only，18,274,672 B，与 v137/v138 同形态）。
- **构建中修掉一个会让判读彻底失效的 bug**：面板是 **RGB888 / 24bpp（每像素 3 字节）**，
  而初版 `g0245d_fill_fb()` 按 32 位字填充。全白不受影响（字节全 0xFF），但彩色会被
  24bpp 解释成「黄/品红/青」周期性条纹 → 屏幕花屏、判读器只能读到灰白。
  已改为按 3 字节 (B,G,R) 三元组逐像素填充；内核 sha256 随之变化，确认重编生效。
- **判读器已用合成纯色图回归**：黄/红/绿/蓝/白/黑 六色全部分类正确
  （`workspace/tmp/analyze_color_stage.py`）。
- **填充范围安全性**：start.s 在 bootstrap 装了 L1 idx3 的 1GB block（VA 0xC0000000→PA 0x80000000），
  0xC3401000+6.2MB 仍在该块内；整块填充 = 1920 行 × 3240 B = 6,220,800 B，正好一屏，
  不越界、且纯色填充与 stride 无关（UEFI 报 row=3260 也能全覆盖）。
- **待办**：刷入后看屏幕颜色 → 按第八节表格定位新死点。

---

## 十、工具链全量体检（2026-11-13 20:15–21:05）

新增 `check-toolchain.sh`（68 项，分组体检，真执行而非只看 PATH；
本机在 `linux/`，仓库内是 `scripts/linux/`），
`bash check-toolchain.sh [--verbose]`，沙箱内也会打印 /dev 与 Seccomp 判定。

### 结论：构建链 68/68 全绿，缺的只有 Python 包
- LLVM：系统/UEFI 侧 clang **21.1.8**（toolchain-root/usr/lib/llvm-21，含 lld-link）；
  XNU 侧定制 clang **24.0.0git**（unixnu-toolchain/llvm/bin，带 `__builtin_xnu_type_*`），
  arm64-apple-ios 实测编译通过。
- Apple cctools：ld / otool / nm / strip / ar / ranlib / lipo / install_name_tool / segedit /
  vtool / codesign_allocate / bitcode_strip / libtool / mig / migcom / **iig** / xnu-host-cc 全在。
- shim：xcrun（`-find unifdef` 实测解析正常）/ plutil / codesign / lzfse。
- 主机工具：nasm / iasl / dtc / flex / bison / m4 / cmake / ninja / tcsh / unifdef / mtools 全在。
- 参考资料：IPSW 6.8G（21H461）已解包，kernelcache.decompressed 45M sha256 `f18b4df8…`。
- UEFI 侧 BaseTools 在 `Mu_Basecore/BaseTools`（33 个 BinWrappers），gcc 13.3 + make 在位。

### 补上的缺口（全部为 Python 包）
`pyserial`（串口控制台）、`pycryptodome`（蓝奏云工具）、`lz4`、`unicorn`（分析脚本）、
`build`、`zxing-cpp` + `opencv-python-headless`（截图/日志解码）、
`coloredlogs` + `edk2-pytool-library` + `edk2-pytool-extensions` + `antlr4-python3-runtime`
（**Mu-Silicium/build_uefi.py 必需**，装前 `--help` 直接 ModuleNotFoundError）、`pyyaml`。

### 关键坑：这个 venv 没被 Python 认成虚拟环境
`envs/default/bin/python3` 指向 WorkBuddy 自带 runtime，`pyvenv.cfg` 因此不被采用
（`sys.prefix == base_prefix == /opt/WorkBuddy/resources/runtime/python`），
于是 `pip install` 一律落到 `~/.local/lib/python3.13/site-packages`，
而解释器默认**不加载**用户目录 → 装完仍报 ModuleNotFoundError。
`env.sh` 现在显式把用户 site 挂进 PYTHONPATH（**必须用 `${PYTHONPATH:-}`，
构建脚本都是 `set -u`，写 `$PYTHONPATH` 会 unbound variable 直接失败**）。

### 回归
- `build_uefi.py --help` 正常输出。
- `linux/build-v139-all.sh` 全流程 3m17s 通过；内核 sha256 仍 `56ded44a…`（未变），
  但打包出的 img md5 变成 **`95b06fac9207c5581f06cd2567fc0d5c`**（FAT 卷时间戳不同，
  与内核无关）。刷机请用这个新 md5。

## 十一、v139 判读与 v140（2026-11-14）

- **v139 实拍**（整屏品红+网格纹理+屏幕 45% 高一条白线+上下边缘彩噪带）：
  - **白线 = stage 24 的白带**（`g0245d_paint_stage_vm(24)`，fb row 1052，上下颠倒后
    屏幕顶部 45.2%，实测 45.9% 吻合）→ **PE_create_console() 已返回，死点在 24 与 25 之间**。
    比 v138 的黑屏又前进一站。
  - **品红花屏**：整屏蓝色 fill 被 vc console 用不匹配的像素格式重写（网格纹理=stride 错位、
    上下噪点带=行错位累积）。结论：**颜色 fill 在 console 之后不可信；全 0xFF 白带任何
    像素格式下都是白**——这是 v137 几何一直可读的原因。测白线 RGB=(205,220,225) 基本纯白、
    主体 (189,57,237) 真品红，排除了相机偏色。
- **v140**：删 `g0245d_fill_fb`/`stage_color`（颜色编码退役），恢复 v137 白带几何
  （rowbytes 0xCA8），第三组带梯扩到 **26..34**：
  `26 PE_init_printf / 27 cpu_machine_idle_init / 28 PE_init_platform /
   29 ml_map_cpu_pio / 30 cpu_timebase_init / 31 kptimer_curcpu_up /
   32 PE_init_cpu / 33 fiq_context_init / 34 DT dram-base/size`。
  `g0245d_mark_vm()` 每次**重画 13..index 全带**（vc 清屏会抹掉走 bootstrap VA 的带 21，
  重画保证链条完整）。判读 `analyze_bands_native.py`：**K = 最高带号 − 12**（K=9 → 带 21，
  K=22 → 带 34；链条已放宽到 0.48H 跨度）。
- 构建脚本 `linux/build-v140-all.sh`；patch `zzz-g0245d-v140-band-stages.patch`。

## 十二、v140 → v150 的一整轮排查（2026-11-14 下午）

这一节记录一次**方向性纠错**：连续十版看到的"白条闪一下就黑屏"，前期被误读成"死在 console 附近"，
实际是**内核早就跑过 `arm_init` 了**，只是屏幕输出被主动关掉。

### 12.1 逐版事实

| 版 | 关键改动 | 实机结果 |
|---|---|---|
| v140 | 退役颜色编码，恢复 v137 白带几何，第三组带梯扩到 26..34，`g0245d_mark_vm()` 每次重画 13..index | 只有 13..21 亮，**22..34 一条不亮**，且**没有品红**；白带 + 引导器菜单**一直留在屏上** |
| v141 | 停用 v140 的 physmap 描带；`pe_init.c` 把 `v_width` 归一化为 `v_rowBytes/(v_depth>>3)` | 白条闪一下 → 黑屏，无字 |
| v142 | `video_console.c` 加 `g0245d_vc_paint()`，用 `vinfo.v_baseaddr` 在 console 之后补画白带 | 仍黑 |
| v143 | `PE_create_console()` 之后强制 `switch_to_video_console()` | 仍黑 |
| v144 | `initialize_screen` 里对低地址（<2^48）强制 `makeMapping = TRUE`，走 `ml_io_map_unmappable` | 仍黑 |
| v145 | `arm_vm_init()` 之前把整个 fb 填纯白 | **"没白"** |
| v146 | 填白之后 `wfe` 死循环（仍在 `arm_vm_init` 之前） | **纯白定格** |
| v147 | `vc_render_char` 加 `case 24`、新增 `vc_paint_char_24`、`pe_init` 强制 `v_depth=24` | 仍黑，无字 |
| v148 | `startup.c` 在 `initialize_screen(NULL, kPEAcquireScreen)` 之后强制 `kPETextScreen`；`kernel_bootstrap_log` 无条件打印 | 仍黑，无字 |
| v149 | `g0245d_fb_mark(n)`：完全绕过 console，直接写 `vinfo.v_baseaddr`、按整行 stride 填 0xFF | 照片上未见横杠（但**屏幕底边被裁**，见 12.3） |
| v150 | 标记挪到 fb 行 1000/1080/1160/1240/1320（高 40 行），共 5 个 | 待判读 |

### 12.2 由此确定的结论

1. **v146 是分水岭**：`arm_vm_init()` **之前**填的整屏白能稳定显示 ⇒ **写 fb 能到达面板、
   MDP5 一直在扫描、面板没被关**。所以 v139–v145 的所有"黑屏"都不是硬件问题。
2. **v140 反证 `g0245d_paint_stage_vm`（physmap 描带）会 fault**：它以
   `gVirtBase + (fb_pa - gPhysBase)` 取地址（等价 `phystokv`），而 `phystokv` 要求
   `gPhysBase <= pa < gPhysBase + real_phys_size`，fb 在实际跑起来的位置**不满足**这个窗口
   （或 physmap 尚未覆盖），于是写入即 fault → 停在带 21/22，白带**冻在屏上**。
   **别再直接用 phystokv 访问 fb；要么走 `ml_io_map_unmappable`，要么用 console 的 `vinfo.v_baseaddr`。**
3. **`machine_startup` 会主动关掉屏幕文字**（`startup.c` 里 `initialize_screen(NULL, kPEAcquireScreen)`）：
   - `vc_progress_set(graphics_now=TRUE, delay)` → 画进度画面、把 fb 擦成黑；
   - `gc_enable(!graphics_now)` = `gc_enable(FALSE)` → 因为 `console_is_serial()==FALSE`，
     置 **`disableConsoleOutput = TRUE`**、`gc_enabled = FALSE`；
   - `gc_acquired = TRUE`。
   ⇒ 从这一刻起 **任何 `kprintf` 都不会画到屏上**（`serial_console.c` 的 `_cnputs()` 一进门就 return）。
   这就是"白条只闪一帧然后全黑"的直接原因。
4. **`arm_init` 期间的 kprintf 同样不可见**：`vc_putc` 的守卫是
   `gc_enabled || !gc_acquired || !gc_graphics_boot`，而 `gc_acquired` 只在 `kPEAcquireScreen`
   里才置 TRUE，所以图形模式下 `PE_create_console()` 之后到 `machine_startup` 之前，画不出任何字。
5. 已排除的清屏嫌疑点（都不成立，别再查）：
   - `PE_create_console()` **不清屏**；`vc_initialize()` 只算 rows/columns/rowscanbytes；
   - `check_for_panic_log()` 需要 DT `pram` 节点，本机没有 → 直接 return，**不会 bzero**；
   - `PE_init_printf(TRUE)` → `vcattach()` 只在 `gc_graphics_boot == FALSE` 时才 replay，图形模式无动作；
   - `switch_to_video_console()` 是**无条件** `cons_ops_index = VC_CONS_OPS`，v143 的路由确实生效；
   - `PE_create_console()` 传的是 `&PE_state.video`，所以 `pe_init.c` 里改的 `v_depth` / 强制映射
     都真的进了 `initialize_screen`。

### 12.3 显示几何（实机标定，务必按这个来）

引导器日志（放大照片读准）：

```
DARWINBOOT: video base=0x83401000 display=1 row=3240 width=1000 height=1920 depth=24
DARWINBOOT: command line: -v serial=3 console=ttyHSL0,115200,n8
```

- **`depth` 本来就是 24**（曾误读为 32）；`v147` 强制 24 是冗余动作，无害但无效。
- **`width=1000` 是引导器报错的**：`3240 / 3 = 1080` 才是真实列数。`v141` 的归一化方向正确。
- **显示是垂直翻转的**：用已知带位置标定出 `y ≈ 2052 − 0.935 × fb_row`（照片像素坐标），
  即 **fb 第 0 行在屏幕最底部**。因此：
  - 主带 0..7（fb 行 200..648）出现在屏幕中下部；
  - 细带 13..21（fb 行 700..956）出现在它们**上方**。
- **拍照务必把整块屏幕（含上下边缘）拍全**，否则贴在 fb 低行号的标记会被裁掉——v149 就是这么白丢一轮的。

### 12.4 下一步

- 判读 v150 的横杠条数（`1..5`，见 `zzz-g0245d-v150-marks-visible.patch` 里的注释），据此确定
  内核是停在 `PE_create_console`、`kPEAcquireScreen`、还是 `vm_commpage_init`。
- 若条数 ≥ 4 说明已经越过清屏点，那"没字"就纯粹是 console 渲染/格式问题，需要在
  `gc_enable(TRUE)` 之后确认 `gc_enabled`、字模与 `v_baseaddr` 三者都成立。
- 若条数为 0 或 1，则应把注意力放回 `arm_init` 的后半段（`serial_init` / `PE_create_console`）。
