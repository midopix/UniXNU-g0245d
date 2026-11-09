# 上游 porting 文档提炼（2026-11-09 巡查，筛选 MSM8996 可用部分）

> 来源：`UniXNU/UniXNU@d3de950a23a5` 的 `docs/porting/{input,ufs}.md`、
> `docs/drivers/sheng-ufs.md`、`docs/xnu/boot-arguments.md`。
> 巡查报告里大多数「🔸相关」标签是**误报**（三星 Exynos 平台关键字命中），已剔除。

## 0. 重要前提（先读）

- 本设备构建的是 **`xnu-10063.141.1`**（`ipados-17.7.11-21H461`，见
  `profiles/os/ipados-17.7.11-21H461/profile.toml` 的 `xnu_version`）。
- 上游 `patches/xnu-12377/*`（含 `native-at-par-sync.patch`、user-PAC-keys-off）
  **只针对 `xnu-12377.121.6`**（iPadOS 26.5.2 / 27.0.1 那套新设备）。
  → **这两个补丁对我们的 10063 构建不适用，不要回退进 `UniXNU-msm8996-common`
  的 patch series**，否则打不上或破坏构建。
- 本次未合 Mu-Silicium（其 `QcomPkg/PlatformBootManagerLib` 是真正 Qualcomm 相关，
  留待后续 merge-base diff 评估）。

---

## 1. UFS 上机要点（来自 `porting/ufs` + `drivers/sheng-ufs`，已筛通用部分）

### 1.1 硬件清单（实现前逐项记录来源）
| 输入 | 记录内容 |
|---|---|
| Controller | compatible、版本、MMIO base/len、能力寄存器、中断路由 |
| PHY | 寄存器区间、lane、参考时钟、tuning 源、初始化归属 |
| Clocks | 提供方、clock id、速率、父选择、分支门控、互联投票 |
| Reset/Power | reset 线、regulator、power domain、时序、固件归属 |
| SMMU | 实例、stream id / mask、context bank、地址宽度、已有映射 |
| DMA | buffer 分配、物理/IOVA 关系、对齐、一致性、cache 维护 |
| Handoff | HCE/HCS、链路状态、request-list base、在途命令 |
| Storage layout | LUN、块大小、容量、GPT、root window、Data/log 预留 |
| OS interface | storage ABI、prelink 输入、发布/匹配、完成行为 |

> 共享控制器资源放 SoC DTSI，板级接线/策略放设备仓。寄存器宽度、父地址
> cells、`ranges`、中断提供方、IOMMU 引用按 device-tree bindings 写。

### 1.2 已验证、可直接复用的「坑」（重点，对应我们 msm8996-ufs2 缺口）
- **请求列表 cache-line 一致性**：请求列表条目 32 B，两条共享一个 64 B
  cache line。**非一致 DMA 流**上 clean 一条会把邻居的控制器完成位冲掉 →
  把列表放在 **write-combined 页**（Linux 用 coherent DMA 内存），或每槽独占一行。
  MSM8996 的 SMMU 是非一致的，**必查**。
- **完成中断（UTRCS）只对置了 UTRD 中断位（dword0 bit 24）的描述符触发**：
  只开 `UTRCE`，靠 **doorbell 清零** 找完成的命令（同 Linux `ufshcd`）。
  → 直接对应我们的 UFS 中断处理写法。
- **空闲硬件门控 AHB 分支会报 `CLK_OFF`**：同时查「分支使能位」和「硬件门控位」
  （参考 `GccUfs.h`），别只看一个。
- **SMMU bypass 受地址宽度限制**：查清完整 DMA 范围与已有 stream/context-bank 归属，
  别越界。
- **混合轮询**：前 200 µs 轮询、之后睡眠，QD 8/32 下小块吞吐不降；全程睡眠在小块
  上反而更慢。
- **改链路状态前先 `DME_GET`** 读 `PA_TxGear`/`PA_RxGear`/`PA_HSSeries`/`PA_PWRMode`，
  别盲设。

### 1.3 里程碑顺序（逐个验收，别跳）
寄存器可读 → DMA 可达 → 命令完成/失败处理 → 已知块读（容量 + LBA 匹配）→
根挂载并启动用户态 → 持久化写存活 → 性能（对照同机主线 Linux `ufshcd-qcom`）。

### 1.4 配置（注意开关名需核对本仓）
- sheng 侧：`defconfig` 开 `CONFIG_XNU_NATIVE_UFS=y` + 内核参数 `native-ufs-root=1`。
- 我们是 `NativeUfs8996` 经 `CONFIG_XNU_EXTRA_LD_ARCHIVES` 的 `force_load` 链入，
  **开关名不一定同名**，需核对本仓 `g0245d_defconfig` 与组件 recipe；改完必须
  `./unixnu defconfig g0245d_defconfig -D ../UniXNU-g0245d` 重生成 `.config`。
- 构建/校验：`defconfig` → `./unixnu status --json -D ...` → `./unixnu build kernel -D ...`。

---

## 2. 输入 / 按键 / 按钮要点（来自 `porting/input`）

- **物理按钮**：把目标 GPIO / PMIC 输入映射成 HID 按钮事件——极性、归属、
  中断路由、应答都要处理；参考 `ButtonProbe.cpp`，报告 2 的 bit 上报
  Power / Vol+ / Vol-。
  → 对齐我们 PM8994 GPIO → ConIn → KeypadDxe 的链路（见 `pitfalls.md` 的
  D5→D8→D16 根因链）。**注意 sheng 用的是 PMK8550 寄存器，PM8994 不能照抄。**
- **键盘盖（I2C）**：一个 `IOHIDDevice`；`SmartCoverServiceFilter` 要求
  Keyboard(1/6) / TouchPad(0x0d/5) / Finger(0x0d/0x22) usage 对（仅
  Application/Physical collection 计数），X/Y 物理范围用**厘米**单位（0x11）。
  G0245D 无键盘盖，仅作 HID 知识备查。
- **触控（GeniSpi + Novatek 协议）是 SM8550 专属**，G0245D 暂不涉及。

---

## 3. 启动参数要点（来自 `xnu/boot-arguments`）

- **生效顺序**：`[payload] kernel_args`（board profile）← `[build] kernel_args`
  （`unixnu.local.toml`）← `--kernel-arg`；同名后者覆盖前者。
  payload builder 写进 `EFI/UniXNU/unixnu.toml` 的 XNU 条目 `args`，
  DarwinBoot 拷进 `boot_args.CommandLine`。行最长 1000 B（缓冲 1024 B）。
- **通用参数**：`-v`（详细）、`serial=3`（串口控制台）、`debug=0x14e`（调试掩码）、
  `kextlog=0xfff`（kext 详细日志）、`-no_slto_panic`、`boot-progress=<n>`、
  `cs_debug=<mask>`、`amfi_get_out_of_my_way=1`（仅诊断，改安全策略）。
- **平台参数（部分可能通用，需核对本仓 ArmCpu 是否实现，勿盲抄 `sheng-*`）**：
  - `armcpu-diagnostics=1`：打印 CPU 与中断状态 → **SMP 次核排查有用**。
  - `armcpu-spi-ipi=1`：IPI 走 SPI 路径 → **SMP 相关**。
  - `native-ufs-root=1`：走原生 UFS 根路径。
  - `boot-progress=2`：启动进度显示级别。
- **排障组合**：早期内核输出 `-v serial=3 debug=0x14e`；kext 加载 `kextlog=0xfff`；
  UFS 细节 `native-ufs-root=1 native-ufs-stats-delay=30`；启动进度 `boot-progress=2`。
- **大量 `sheng-*` 是 SM8550 专属，不要抄进本仓。**

---

## 4. 本次排除项（2026-11-09 巡查明确不做的）
- 上游 `patches/xnu-12377/*`：xnu-12377 专属，10063 构建不适用（见第 0 节）。
- Mu-Silicium 报告误标的 Samsung/Exynos 平台（a10/a7/gta3xllte/S5E7885/S5E9810）与
  MSM8996 无关；`Silicium-ACPI` 三星表同理。
- 仅 `Mu-Silicium/Silicon/Qualcomm/QcomPkg/PlatformBootManagerLib` 是真正 Qualcomm
  相关，本次未合，留待后续用 **merge-base diff**（绝不用 `git diff HEAD..origin/main`）
  评估。
