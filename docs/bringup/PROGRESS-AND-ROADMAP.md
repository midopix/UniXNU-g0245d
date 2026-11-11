# G0245D × UniXNU —— 现在做到哪、后面怎么做

> 快照：2026-11-11 18:00。配套文档：`workspace/G0245D_UNIXNU_STATUS.md`（第 17/18 章为完整来龙去脉）、
> `PENDING-FLASH-v137.md`（唯一未验证版本的手册）、`MIGRATION-TO-MACOS.md`（换机恢复）。

---

## 一、一句话现状

**内核已经能跑到 `arm_vm_init()` 调用点之前**，并且期间修掉了两个真 bug。
当前唯一的未验证版本是 **v137**（镜像已构建，md5 `df5c40f3407e318647e5eb9d737b0816`，**尚未刷入设备**）。

对照官方 6 大步骤：

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 构建环境 / 工具链 | ✅ |
| 2 | 硅片包（UFS / 显示 / UART / SPMI / PMIC） | ✅ |
| 3 | 真机 UEFI 跳转 | ✅ |
| **4** | **XNU 加载 + 早期诊断** | **🔶 死点已收敛到 `arm_vm_init()` 调用前后的若干语句** |
| 5 | 驱动适配 | ⬜ |
| 6 | 用户态 | ⬜ |

---

## 二、死点地图（当前坐标）

段内的 ✅/❌ 全部由帧缓冲白带实拍判读确认（`analyze_bands_native.py`）。

```
start.s  start_first_cpu ......................... ✅  band 0 起（args 有效才画）
  ↓
arm_init() 入口 g0245d_paint_stage(7) ............ ✅
  ↓
  thread_bootstrap ............................... ✅  band 13
  cpu_bootstrap .................................. ✅  band 14
  rtclock_early_init ............................. ✅  band 15   ← v131 修掉时基 panic 后才通
  kernel_debug_string_early("kernel_startup_bootstrap")
  kernel_startup_bootstrap:
      n/size 检查（n≈4006，section 96KB） ......... ✅  band 16/17
      qsort(4006 条) ............................. ✅
      kernel_startup_initialize_upto(LOCKS):
          TUNABLES / TIMEOUTS / LOCKS ............ ✅  band 19–21（v131 时全亮）
  processor_bootstrap ............................ ✅  band 18
  ↓
  ── 窗口 A ────────────────────────────────────── ❓  v137 在这里插了 19/20/21
      PE_parse_boot_argn("maxmem") ................ ?
      PE_get_default("hw.memsize") ................ ?  ← 缺陷 1，v137 已删
      nanoseconds_to_absolutetime ................. ?
      set_bp_ret / immediate_NMI / PAN ............ ?
  ↓
  arm_vm_init(xmaxmem, args) ..................... ❌  band 21（调用点）从未亮
      函数前段（gPhysSize/mem_size/页表几何） ..... ❌  v135 的 21 灭
      arm_set_user_tbi 之前 ...................... ❌  v134 的 19 灭
      TTBR 切换（set_mmu_ttb_alternate） ......... 未到
  ↓
  serial_init .................................... 未到（到了就有串口，可以不做画带了）
  PE_create_console .............................. 未到
  arm_init() 末尾 → machine_startup() ............ 未到
```

**一句话读法**：band 13–18 稳；19–21 是 v137 新插的三颗探针，用来把「18 → `arm_vm_init()` 调用点」
这段窗口切成三段。**没亮之前，不要往 `arm_vm_init()` 内部猜。**

---

## 三、立刻要做的：刷 v137 → 判读 → 按结果分支

### 3.1 刷入

镜像和守护脚本都在包内：

```bash
cd workspace/tmp
# 方式 A：设备已在 fastboot，直接刷
fastboot flash boot g0245d-v137.img && fastboot reboot
# 方式 B：挂守护，设备一进 fastboot 就自动刷
bash wait-flash-v137.sh
```

判读前**务必**先看 `workspace/tmp/wait-flash-v137.log` 里出现 `flash 成功` + `全部完成`，
否则会把上一版画面当新结论（踩过一次）。

### 3.2 判读

```bash
python3 workspace/tmp/analyze_bands_native.py <照片>
```

### 3.3 决策树（按 K 值走，不要凭感觉）

| K | 亮到 | 说明 | 下一版怎么改 |
|---|---|---|---|
| **6** | 18 | `PE_parse_boot_argn("maxmem")` 内部就出事 | v138：连这个解析也去掉，`xmaxmem` 恒 0（等价于 maxmem 未设）；若仍 6，说明窗口里还有更早的东西，把 19 移到 `processor_bootstrap()` 之后第一行再二分 |
| **7** | 19 | maxmem 过了，死在中间那组 | v138：`set_bp_ret()` 先去掉（`HAS_BP_RET` 分支整段 `#if 0`）→ 再单独去掉 `__builtin_arm_wsr("pan",1)` → 再拆 `nanoseconds_to_absolutetime`。每次只动一条，一次就能定位 |
| **8** | 20 | 只差最后几句（bpret / immediate_NMI / PAN） | v138：同上，逐条禁用 |
| **9** | 21 | **窗口通了** | 说明原来灭的就是 `PE_get_default`。v138：把 19/20/21 移进 `arm_vm_init()` 内部（进入点 / 页表建好 / TTBR 切换前），继续往函数体推 |

> 经验：v134–v136 已经证明「探针塞进 `arm_vm_init()` 内部也灭」，所以 v137 若还是 6，
> **不要再往函数内部猜**，一定是窗口 A 里更早的语句，或者画带本身到不了（但那已被 v133 的
> physmap 版本排除）。

---

## 四、越过窗口 A 之后：`arm_vm_init()` 内部怎么推

进入函数后，按这几处插探针（都在 bootstrap 映射仍有效区间，用老画带函数即可）：

| 位置 | 意义 |
|---|---|
| 函数体第 1 行 | 确认真的进去了 |
| `gPhysSize = mem_size = ((gPhysBase + args->memSize) & ~PAGE_MASK) - gPhysBase;` 之后 | 内存尺寸计算是否 sane；建议同时把 `mem_size` 的值用带数编码出来（用几条带表示 MB 数） |
| `physmap_base = phystokv(args->topOfKernelData);` + `physmap_slide` 之后 | physmap 基址是否合法 |
| `arm_vm_physmap_init(args)` 之后 | physmap 建立 |
| `set_mmu_ttb_alternate(cpu_ttep & TTBR_BADDR_MASK)` 之后 | 备用表切换 |
| `set_mmu_ttb(invalid_ttep...)` + `flush_mmu_tlb()` + `kva_active = TRUE` **之后** | ⚠️ **从这里起 bootstrap V=P 映射消失**，必须改用 physmap 画带（v133 已实现 `g0245d_paint_stage_vm`），否则探针本身就是凶手 |

**注意 `BOOTSTRAP_TABLE_SIZE` 已排除**（`native-4k-bootstrap-capacity.patch` 已应用，16 页 > 12 页）。

`arm_vm_init()` 之后的路线（按顺序）：

```
serial_init()            ← 到这里串口就活了，之后可以彻底改用 printk，不必再拍照判读
PE_create_console()
arm_init() 末尾
machine_startup(args) / kernel_bootstrap()
    → pmap 就绪、kprintf 可用
    → bsd_init() → launchd（阶段 6 的入口）
```

**重要策略转折点**：`serial_init()` 一通，就把调试手段从「屏幕画带 + 拍照」切换到
**「串口 printk」**。届时需要一根 USB-串口线（`console=ttyHSL0,115200,n8` 已在
`board.toml` 的 `kernel_args` 里）。这一步能省掉几十轮刷机 + 拍照。

---

## 五、阶段 5 / 6 的任务清单（还没开始，先列着）

### 阶段 5：驱动适配（内核能进 bsd_init 之后才谈得上）

| 子系统 | 现状 | 要做的事 |
|---|---|---|
| 显示 | UEFI 侧已能给 framebuffer（`fb 1080x1920`、`cont_splash 0x83401000`）；内核侧只有裸写像素 | 写 DSI panel 驱动 + framebuffer 驱动，接管 `PE_create_console` 之后的 console |
| 串口 | `ttyHSL0` 已在 kernel_args，硬件未验证 | 最优先——它决定后面所有调试成本 |
| 存储 | UEFI 侧 UFS 已通（阶段 2）；内核侧无 | UFS/SCSI 驱动，才能挂 ramdisk / 根分区 |
| 中断 | GIC 未接 | AIC/GIC 初始化 + 时钟中断，否则只能单线程跑 |
| 触摸/按键 | UEFI 有 KeypadDeviceLib；内核无 | 后面再说 |
| 电源 | PMIC 在 UEFI 侧有 | 内核侧 regulator / charger |
| 网络/音频/BT | 无 | 最后做 |

### 阶段 6：用户态

1. ramdisk（`payload.img` 里已有）能被挂上
2. `launchd` 能起、`/sbin/launcher` 能跑
3. 必要 kext 加载（先只求能进单用户）
4. 框架 / App —— 最远的目标

---

## 六、工程债（这些不清理，后面会反复踩）

| 项 | 现状 | 建议 |
|---|---|---|
| **探针污染** | `arm_init.c` 里累积了 13–21 共 9 颗探针 + `g0245d_paint_stage_vm`；`startup.c` 已被 v132 清空但补丁仍在 series | 死点闭环后做一次 **v140「清理版」**：只留 `paint_stage(7)` 和 1–2 颗关键带，把其余全撤，作为干净基线 |
| **补丁序列膨胀** | `patches/xnu/` 已 19 个文件，v122–v137 多为一次性探针 | 保留 v131（时基修复）、v137（maxmem/IOKit 修复）作为**永久修复**；其余探针类归档到 `patches/xnu/archive/`，`series` 只留必要项 |
| **未提交改动** | `UniXNU-g0245d` 工作树有 README §9、`series`、v129–v137 共 9 个补丁未 commit | 尽快 commit + 推 4 目标（`workspace/github/push-now.sh`，PAT 在 `~/.workbuddy/github-token`） |
| **上游 rebase** | DarwinBoot +4 提交、UniXNU `sheng-` 参数重命名；本地 `g0245d-darwinboot.patch` / `g0245d-unixnu-lib.patch` 与上游撞文件 | 见 `upstream-watch/UPSTREAM-TRIAGE-2026-11-11.md`，**推迟到死点闭环后**再做 |
| **文档口径** | STATUS 已到第 18 章、README 到 §9，但 v129–v137 只在 STATUS | 每次刷机后同步两处，避免下个会话被旧结论误导 |
| **判读器** | `analyze_bands_native.py` 只对「近距构图」验证过；远景（v125/v126）会选错主带 | 死点闭环后要么修鲁棒性，要么固定拍摄距离/机位（更省事） |

---

## 七、命令速查

```bash
# 环境
cd ~/g0245d && source env.local.sh          # macOS（env.macos.sh 复制来的）
# 或 source env.sh                            # Linux 原版

# 编内核
cd src/unixnu-g0245d/unixnu-src
python3 unixnu build kernel --skip-prelink

# 打 payload + 打包镜像
python3 unixnu build payload --unique-chip-id 0089960000000001
cd ../../../workspace
python3 tools/pack_fd.py --base tmp/g0245d-v137.img \
  --fd ../src/unixnu-g0245d/uefi-g0245d/Mu-Silicium/Build/g0245dPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd-bootshim \
  --ramdisk ../src/unixnu-g0245d/unixnu-src/out/g0245d/ipados-17.7.11-21H461/g0245d/payload/payload.img \
  --out tmp/g0245d-v138.img

# 刷机
fastboot flash boot tmp/g0245d-v138.img && fastboot reboot
# 或挂守护：bash tmp/wait-flash-v138.sh

# 判读
python3 tmp/analyze_bands_native.py ~/Downloads/IMG_xxxx.jpg
```

---

## 八、风险与已知边界

1. **画带会自伤**：`arm_vm_init()` 的 TTBR0 切换之后写 `VA 0xC3401000` 必 fault。
   过了切换点只能用 physmap 版本（v133 已验证可编译、未验证可写）。
2. **panic 不可见**：`serial_init()` 之前所有 `panic()` 都是静默复位，只能靠画带反推。
   所以「K 值不变」有两种含义——真死在那里，或死得更早但带没画出来。区分办法：换/加探针位置。
3. **探针索引会撞车**：多版补丁叠加后 19/20/21 可能被两处同时使用（v128+v129 就撞过）。
   每次插带前先 `grep -c 'g0245d_paint_stage(' 全树`，确认唯一。
4. **改文件前先查补丁**：`arm_vm_init.c` 被 `xnu-12377/*` 改过，直接按原始源码写 hunk 打不上。
   正确做法：按 `series` 顺序把补丁抽 hunk 应用到临时树，重建真实内容后再生成 diff。
5. **设备救援**：卡死时「长按电源 15s → 按住音量下 + 短按电源」可进 fastboot；
   最坏情况走 EDL（`05c6:9008`）。原始 `boot.img` 在 `workspace/firmware/g0245d/boot.img`。
