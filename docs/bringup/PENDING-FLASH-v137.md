# 待刷版本：v137（截至 2026-11-11 18:00 尚未刷入设备）

这是当前**唯一未验证**的版本。镜像、补丁、守护脚本、判读器都在包内，刷完拍一张就能定案。

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
