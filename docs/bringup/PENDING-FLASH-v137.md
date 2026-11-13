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
