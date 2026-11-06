# REA 逆向工作流 — 格力 G0245D × UniXNU 移植

本文件记录用 **REA（Reverse Engineer Anything）** 分析格力 G0245D 原厂 QFIL 刷机包、
为 UniXNU 移植提取硬件与固件事实的标准流程。所有结论必须落到 `porting.toml`
对应 area 的 `evidence` / `findings` 字段，或本文档的「结果记录」表。

---

## 1. 环境

| 组件 | 版本/路径 | 状态 |
| --- | --- | --- |
| Node | 24.22.1（nvm，`~/.nvm/versions/node/v24.22.1/bin`） | 已装（rea 要求 ≥ 22.19） |
| rea-agents CLI | `rea@6.7.0` | 已装（`npm i -g rea-agents`） |
| JDK | **OpenJDK 21.0.12**（`/usr/lib/jvm/java-21-openjdk-amd64`，apt 装；系统默认 Java 20 不够，Ghidra 12.1 要求 ≥ 21） | 已装，须 `export JAVA_HOME` |
| Ghidra | 12.1.2 `GHIDRA_INSTALL_DIR=/root/tools/ghidra_12.1.2_PUBLIC` | 已装（32 路并行下载 + `unzip -t` 校验通过） |
| Hopper / IDA / JEB | 可选补充引擎 | 未配置（REA 不主动安装） |

```sh
export PATH="/root/.nvm/versions/node/v24.22.1/bin:$PATH"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export GHIDRA_INSTALL_DIR=/root/tools/ghidra_12.1.2_PUBLIC
rea doctor          # 目标：ghidra 各检查 ok=true；provider ghidra available=true
rea providers       # 列出可用分析引擎
rea capabilities    # 列出引擎能力与副作用
```

REA 只读本地文件、不执行目标；CLI 支持 `--format json` 与 `--filter-output`
控制输出体量，适合把结果直接归档为 Evidence JSON。

**raw binary 分析的两条路径**（2026-10-25 实测）：
1. `rea analyze <file> --target-format raw-binary --architecture arm64 --entry-point 0x91600000 --provider ghidra`
   —— 适合快速总览（字符串清单、段布局）；raw 模式默认只识别入口一个过程，
   需要函数级结论时走路径 2。
2. Ghidra headless 持久项目（适合全量反汇编 + 交叉引用）：
   ```sh
   analyzeHeadless <projdir> <name> -import <img> \
     -loader BinaryLoader -loader-blockName ram -loader-baseAddr 0x91600000 \
     -processor AARCH64:LE:64:v8A -scriptPath <dir> -postScript <script>.py \
     -analysisTimeoutPerFile 300 -overwrite
   ```
   post-script（PyGhidra）里打开 `Aggressive Instruction Finder` 后
   `AutoAnalysisManager.reAnalyzeAll()`，再取 `getReferencesTo(stringAddr)`。

## 2. 输入固件清单（QFIL 包已解压）

路径根：`firmware/extracted/G0245D_Gree_user_QFIL_images/`

| 文件 | 大小 | 用途 | 分析目标 |
| --- | --- | --- | --- |
| `vmlinux` | 193 MB | 带符号库存内核（Linux 3.18.20-perf, GCC 4.9） | 驱动行为参考：直接读符号，不必反编译 |
| `boot.img` | 47 MB | Android boot image v0 | 已解析：kernel 0x80008000 / ramdisk 0x81000000 / tags 0x80000100；内核槽 = gzip(Image 26.4 MB) + **90 条目 FDT 表**（330-349 KB/条目，共 30 MB；FDT#0 == board.dtb；aboot 按 qcom,msm-id/board-id/pmic-id 匹配） |
| `xbl.elf` | 1.8 MB | XBL 加载器（xbl 分区） | 入口、appsboot 加载地址、framebuffer handoff、内存映射 |
| `emmc_appsboot.mbn` | 740 KB | **LK + aboot（aboot 分区，真正的 Android Bootloader）** | boot.img 解析/校验、DTB 修补、跳转内核、boot_verifier |
| `M8996AAAAAAAAQ1234.elf` | 7.2 MB | XBL+QURT(SLPI) 联合镜像（QFIL flat-build 产物，不进分区） | SLPI 引导参考 |
| `prog_ufs_firehose_8996_ddr.elf` | 436 KB | Firehose 编程器 | UFS 初始化序列（寄存器/时钟） |
| `NON-HLOS.bin` | 83 MB | **modem 分区**内容（95 MiB 窗口） | modem/PRL blob 清单与入口 |
| `adspso.bin` | 16 MB | dsp 分区 | Q6/ADSP 固件 |
| `slpi.mbn` | 3.3 MB | — | SLPI PAS 固件 |
| `qca_cld_wlan.ko` | 6.0 MB | QCA6174 WLAN 驱动模块 | CNSS 探测、PCIe 上电时序、固件名 |
| `splash.img` | 17.8 MB | 开机画面 | **已完成**：`SPLASH!!` 头 + 3×RGB888 帧（1080×1920） |
| `board.dtb` | 341 KB | 设备树 | **已完成**：见 `dts/panel-ft8716.txt`、`porting.toml` |

分区映射（rawprogram_unsparse*.xml，4096 B 扇区）：rpm@s6、xbl@s6、tz@s262、
hyp@s1286、fsg@s1542、sec@s2054、pmic@s2058、modem@s2314(+24320s)、dsp@s26634、
mdtp@s30986、**aboot@s39178(+256s)**、boot@s39690(+16384s)、misc@s73736、
devcfg@s74120、system@s56074、userdata@s74312、splash@s859852(+8356s)、
lksecapp@s859147、keymaster@s859211、cmnlib@s859467、cmnlib64@s859595、
bluetooth@s858891、devinfo@s858890、weakchg@s868720、weakbat@s871792。

## 3. 标准分析流程（每个 blob）

```sh
# 3.1 证据保全（任何分析之前）
sha256sum <blob> | tee -a firmware/manifest.sha256

# 3.2 布局与签名（不加载代码）
rea inspect-binary-layout <blob> --format json > out/<blob>.layout.json
rea inspect-firmware-regions <blob> --format json > out/<blob>.regions.json

# 3.3 总览
rea analyze <blob> --format json > out/<blob>.analyze.json

# 3.4 按需深挖
rea search <blob> "cnss"                 # 字符串/过程名检索
rea search-bytes <blob> "41 f9 .. .. 1f" # 掩码字节模式
rea function <blob> <name>               # 单函数证据级分析
rea decompile <blob> <name>              # 反编译片段
rea instructions <blob> <name>           # 原始指令
rea read-bytes <blob> <addr> <len>       # 读分析地址字节
rea address-to-file-offset <blob> <addr> # 地址→文件偏移
```

规则：
- 每条结论记录 **命令 + 输出文件 + 关键行**，写入 `porting.toml` 的 `evidence`。
- 与 board.dts 冲突时，以 DTS + 实测为准，并在 `findings` 记录差异原因。
- 引擎不可用时降级：`inspect-with-objdump` / `readelf` / `strings`，并标注证据等级。

## 4. 各 blob 分析任务卡

### 4.1 vmlinux（带符号，193 MB）— 参考源，不逆向
```sh
readelf -sW vmlinux | grep -iE "fts_ts|synaptics_dsx|cnss|qca6174|ufshcd|mdss_mdp|adreno"
strings -t x vmlinux | grep -iE "ft8716|ft5x26|synaptics|qca6174|adreno-530"
```
已完成（2026-10-25）：触摸 `fts_ts` 与 `synaptics_dsx_i2c`/`synaptics_rmi4_i2c` 驱动共存，
DTS 以 `synaptics@20` 为准；WLAN `cnss_pci.c`（PCIe）；DSI 面板候选驱动 `nt35596`/
`tm23_g..tm30_g` 均已编译，DTS 选 `ft8716`；UFS `ufs_qcom_*`；MDP `mdss_mdp.c`；
GPU `kgsl`。

### 4.2 xbl.elf + emmc_appsboot.mbn — 启动与 framebuffer
设备真实启动链：PBL → **xbl.elf** → **emmc_appsboot.mbn（LK aboot）** → boot.img。
xbl.elf 布局已由 readelf 建立：XBL core LOAD @0x6208000（entry 0x6213de0）、
DDR 训练 RWE @0x80200000/0xf0000、IMEM LOAD @0x21e000/0x207000/0x217800/0x219800。

**emmc_appsboot.mbn 是标准 Qualcomm MBN 格式**（不是被混淆的 ELF64）：
ELF32 头（e_machine=ARM）描述 64 位段——readelf 按 ELF64 解析会得到垃圾值。
正确解析（python struct，2026-10-25 验证）：
- e_entry = **0x91600000**，e_phoff = 0x34，4 个 32 字节 phdr
- ph[3] PT_LOAD：**file 0x8000..0xb907c → 0x91600000..0x916b107c**（filesz 0xb107c，
  memsz 0xc4478，RWX，align 0x8000）；文件大小恰为 0x8000+0xb107c，无签名尾部
- ph[1]：file 0x1000 → 0x9168a000（0x19a8 B）；ph[2]：type 0x70000001（MBN hash 段）
  file 0x91f88 → 0x91689f88（0x20 B）
- 地址映射 **vaddr = 0x91600000 + (file_offset - 0x8000)**，已用 946 个字符串指针
  （u32 字面量，如 `/G0245D_shared/mdp5.c`）统计验证（2120:822 胜出）
- boot.img 头读取地址 **EMMC_BOOT_IMG_HEADER_ADDR = 0x8F6FF000**（MSM8996 LK 公开常量，
  CSDN 高通8996启动流程系列），"ANDROID!" 常量在 file 0x7e168（vaddr 0x91676168）

Ghidra 加载方式：raw binary，base address 0x91600000，取 file[0x8000:] 为镜像。

**aboot 分析问题清单（BootShim 策略的依据，2026-10-25 整理）**：
1. `boot_linux_from_mmc` 主流程：gzip 魔数检测后的解压目标寄存器/常量
   ——预期为 header 的 kernel_addr 字段（0x80008000），确认 FD 解压窗口安全
2. 追加 DTB 处理：gzip 流结束后的 FDT 魔数扫描、FDT 拷贝目标地址
   （预期 memmove 到内核镜像尾部，即 0x80008000 + image_size 附近）
3. 跳内核时的寄存器状态：x0（预期=DTB 地址）、x1/x2/x3、MMU/cache 状态
   ——BootShim.S 的入口契约（对应 sheng 的 REQUIRES_KERNEL_HEADER=1）
4. ARM64 头校验：是否校验 "ARMd" 魔数（offset 56）或 code0 分支指令
   ——决定 shim 镜像头部构造
5. boot_verifier / VERIFIED_BOOT_SIG 门控：未解锁设备是否拒绝非签名 boot.img
6. boot.img 大小上限（num_partition_sectors=16384 × 4096 = 64 MiB，boot 分区）

### 4.2.1 emmc_appsboot.mbn Ghidra 分析结论（BootShim 五问，2026-10-25 定稿）

> 加载方式：raw binary，base 0x91600000，镜像 = file[0x8000:]；pyghidra 打开既有项目
> `/tmp/test-proj-arm32`（program `aboot_0x91600000.bin`，`analyze=False`），反编译 +
> 102515 条指令 / 725116 B 段的字符串与 xref 扫描。

| # | 问题 | 确证答案 | 关键函数 / 地址 |
| --- | --- | --- | --- |
| 1 | gzip 解压目标 | memcpy 到 **kernel_addr 0x80008000**（FUN_916484e0=memcpy）；gunzip 由 FUN_91669f68 解到动态 buffer 尾部，local_70=源消耗长度（FDT 表偏移）、local_74=解压大小 | FUN_91635204 → FUN_91669f68 → FUN_916484e0(_DAT_916b9b8c=kernel_addr, img) |
| 2 | 追加 DTB 拷贝目标 | 90 个 FDT 按 qcom,msm-id/board-id/pmic-id 匹配后 memcpy 到 **tags_addr 0x80000100**（dtb_size==0 追加路径与 QCDT 路径同目标，_DAT_916b9ba0=tags_addr）；"Tags addresses overlap with aboot" 仅防 aboot 区，不防内核 | FUN_9161981c(img, kernel_size, 表偏移, tags_addr) → FUN_916484e0(param_4=tags_addr, src, size) |
| 3 | 跳转寄存器状态 | update_device_tree 打补丁 chosen/bootargs/initrd → 校验 kernel+0x38=='ARMd' → 构造 _DAT_916b7000（+0x00=DTB/tags_addr、+0x48=kernel_entry）→ SCM 调用 FUN_9161b2bc(scm cmd=(1<<10)|0xf) 或 FUN_9161b508(scm_call id=0x200010f) → **TZ 置 x0=DTB 并跳 kernel_entry=0x80008000**；aboot 不返回（返回才打印 "Failed to jump to kernel"） | FUN_91634f74；入口=kernel_addr（code0 分支进内核）；32 位回落 `(*entry)(0, dtb, x2)` |
| 4 | ARM64 头校验 | 双重校验：FUN_91635204 的 FUN_91633e50(0x916b9b80, *(img+0x38)==0x644d5241) 与 FUN_91634f74 的 `if(*(int*)(kernel+0x38)==0x644d5241)`。**BootShim 必须保留 'ARMd' 头** | +0x38 magic = 0x644d5241 |
| 5 | boot_verifier 门控 | 解锁（DAT_9168da00==1）时 FUN_9160f7cc 直接返回成功；FUN_91635160 打印 "Device is unlocked! Skipping verification..." + mdelay(5000)。门控 PATH A（跳过签名验证）iff `unlocked && _DAT_916b8af4==0`，否则 PATH B（FUN_91633d24）。PATH B 失败非致命（仅打印、_DAT_916b8b00 置位、FUN_9163436c 向 cmdline 追加 `androidboot.authorized_kernel=false`），正常启动 fastboot_flag==0 → 不阻断。**锁定零售机 + 无签名 boot.img 仍能启动；解锁设备完全跳过验证** | FUN_9160f7cc / FUN_91635160 / FUN_91633d24 / FUN_9163436c / FUN_9160f324(QSEEcom ROOT_OF_TRUST，失败/ASSERT 均非致命) |

**头地址恒等映射补充**：FUN_91633e50 把 kernel/ramdisk/tags 地址经 DDR 内存映射变换（FUN_91603c1c 读 64 位基址 0x916b2528 = 0x80000000，4 GB 机型 DDR 地址恒等），故有效加载地址仍为 0x80008000 / 0x81000000 / 0x80000100，与 v0 头一致，FD_BASE=0x92000000 在 aboot 镜像之上、hdmi splash 之下且 aboot 仅解压到 0x80008000，FD 窗口安全。

**text_offset 纠正**：stock 内核 Image 的 text_offset = **0x80000**（非先前错误记录的 0x0），真实内核 text 在 0x80008000+0x80000=0x80088000，高于追加 DTB 区 0x80000100-0x800536F7，无重叠；BootShim 置于 kernel_addr 0x80008000 安全。

### 4.2.2 xbl.elf XBL/UEFI 内存映射表与 framebuffer（2026-10-25）

> `strings -t x xbl.elf | grep -E '0x[0-9a-f]+, *0x[0-9a-f]+, *"'` 提取到 **32 条内存映射表项**；
> 嵌入的 `__FILE__` 路径 `QcomPkg/XBLCore/UefiPlatCfg.c` 证实这是高通 XBL 权威内存图
> （XBL 将其作为 UEFI 内存映射交接给下一阶段）。Ghidra(raw ELF64 直接导入, AArch64:LE:64:v8A) 交叉验证进行中。

**DDR（≥0x80000000）保留区（解答 memory area 的 GPU/venus/mba carveout 缺口）**：

| 名称 | 地址范围 | 大小 | 说明 |
| --- | --- | --- | --- |
| HLOS 0 | 0x80100000-0x80200000 | 1 MB | XBL 阶段系统内存 |
| UEFI FD | 0x80200000-0x80300000 | 1 MB | XBL 自带 UEFI FV（非 UniXNU FD） |
| Display Reserved | 0x80400000-0x80C00000 | 8 MB | XBL 早期 framebuffer（WRITE_THROUGH），非 UniXNU 使用 |
| HLOS 2 | 0x84000000-0x85800000 | 24 MB | XBL 阶段系统内存 |
| HYP | 0x85800000-0x85E00000 | 6 MB | Hypervisor |
| SMEM | 0x86000000-0x86200000 | 2 MB | 共享内存 |
| TZ_STAT | 0x86200000-0x86300000 | 1 MB | TZ 状态 |
| TAGS | 0x86300000-0x86400000 | 1 MB | 设备树标签 |
| TZ | 0x86400000-0x86600000 | 2 MB | TrustZone |
| Stargate | 0x87400000-0x88800000 | 20 MB | CPU DFD/调试 |
| PIL_REGION | 0x88800000-0x90F00000 | 135 MB | modem/ADSP/venus/MBA/wlan 镜像加载区 |

**关键结论**：
- XBL 内存图中**无独立的固定 GPU（Adreno）carveout**——GPU 内存在运行时经 KGSL/PIL 从 PIL_REGION 内分配；故 memory area 的「GPU/venus/mba carveout 待读」缺口关闭（venus/MBA 位于 PIL_REGION；GPU 为动态）。
- **空闲窗确认**：PIL_REGION 终于 0x90F00000，aboot 自 0x91600000 起，故 0x90F00000-0x91600000（~7 MB）+ 0x916c4478-0xb1c00000 在 BootShim 入口为空闲；**FD_BASE=0x92000000 落在该上空闲窗内**（aboot 之上、hdmi splash 0xb1c00000 之下），与 XBL 内存图一致。
- **framebuffer 交接**：ABL→OS 连续 splash 为 cont_splash_mem@0x83401000（36 MB，1080×1920 RGB888，见 splash.img 解码）；这是 UniXNU GOP 交接帧缓冲基址。XBL 的 Display Reserved 0x80400000 为早期缓冲，UniXNU 不沿用、可回收。

### 4.3 prog_ufs_firehose_8996_ddr.elf — UFS 2.0 初始化
要回答的问题：UFS HC 寄存器基址（0x624000）初始化序列、PHY 0x627000 设置、
LUN 枚举方式、SMMU 绑定。产出：`NativeUfs8996` 组件的 init 事实表。
```sh
rea analyze prog_ufs_firehose_8996_ddr.elf --format json
rea search prog_ufs_firehose_8996_ddr.elf "ufshc" "UFS" "LUN" "scsi"
rea decompile prog_ufs_firehose_8996_ddr.elf <ufs_init_fn>
```

### 4.4 qca_cld_wlan.ko — QCA6174 CNSS/PCIe 上电时序
要回答的问题：CNSS WLAN_EN GPIO（0xf9 0x08）操作序列、PCIe root complex
选择（pcie0/1/2 哪个挂 WLAN）、固件加载文件名（用于配对 QFIL 中的 wlan mbn）。
```sh
rea inspect-binary-layout qca_cld_wlan.ko --format json   # 可重定位对象
rea search qca_cld_wlan.ko "cnss" "wlan" "fw" "bd" "hw"
strings -t x qca_cld_wlan.ko | grep -iE "\.bin|\.mbn|board|fw"
```

### 4.5 NON-HLOS.bin — modem 分区固件（95 MiB 窗口）
NON-HLOS.bin 编入 **modem 分区**（LBA 2314..26633，24320×4096 B）。预期内容：
modem image + PRL + 可能的 NV 备份；用 extract-firmware 拆出子 blob 后逐个重复 §3 流程。
音频（ADSP/slpi）固件另在 `adspso.bin`（dsp 分区）与 `slpi.mbn`。
```sh
rea extract-firmware NON-HLOS.bin out/non-hlos --max-depth 4 --format json
rea inspect-firmware-regions NON-HLOS.bin --format json
```

### 4.6 触摸固件（Synaptics DSX PR / config）
DTS 已给出 I2C 0x20 @ i2c@75ba000、irq GPIO 125、reset GPIO 89；缺 **产品 ID 与
config image**（决定 1600x2704 → 1080x1920 坐标缩放）。候选位置：persist 分区、
NON-HLOS 中的 touch 段、`splash.img` 之后的分区镜像。
```sh
rea search-bytes <candidate> "53 59 4e 40"   # "SYN@" magic（示例，按实测调整）
rea search <candidate> "synaptics" "syna" "PR" "config"
```

## 5. MCP / Agent Prompt 模板

通过 REA 的 MCP 服务器驱动时，用以下模板（中文任务描述 + 明确证据要求）：

```text
目标：分析 <文件>，回答 <问题清单>。
约束：只读本地文件，不执行；每条结论必须附命令与输出摘录；
不确定时输出 "unknown" 并列出下一步可执行的验证命令。
步骤：
1. inspect-binary-layout 与 analyze 建立布局；
2. search / search-bytes 定位相关符号与常量（给出我提供的关键词表）；
3. 对命中函数做 function/decompile，提取寄存器基址、时序、GPIO 编号；
4. 汇总为「事实表」：事实 / 证据（命令+输出行）/ 置信度 / 与 board.dts 的差异。
```

## 6. 结果记录模板（追加到 porting.toml）

```toml
evidence = [
  "<文件>: <命令> -> <输出文件>; 关键行: <摘录>",
]
findings = [
  "<结论>（置信度: high/medium/low；与 DTS 一致/差异: <说明>）",
]
```

## 7. 当前进度

| Blob | inspect | analyze | search | decompile | 结论落地 |
| --- | --- | --- | --- | --- | --- |
| board.dtb | ✅ | ✅ | ✅ | — | dts/panel-ft8716.txt, porting.toml |
| boot.img | ✅ | ✅ Ghidra 契约校验 | ✅ | ✅ | packaging area（已打包为 g0245d-uefi.img，结构有效、aboot 可接收、可刷） |
| vmlinux | ✅ readelf | — | ✅ 符号/字符串 | — | input/network/firmware areas |
| splash.img | ✅ 格式破解 | — | — | — | display/firmware areas |
| rawprogram XML | ✅ 分区全表 | — | — | — | firmware/storage areas |
| xbl.elf | ✅ readelf/strings 布局 | ✅ 内存映射表(strings) | ✅ | ⏳ | firmware/memory/display areas |
| emmc_appsboot.mbn | ✅ 头部/字符串 | ✅ Ghidra raw(pyghidra) | ✅ | ✅ | packaging area（五问全确证） |
| firehose | ⏳ | | | | storage area |
| qca_cld_wlan.ko | ⏳ | | | | network area |
| NON-HLOS.bin | ⏳ | | | | firmware/audio area |
| 触摸固件 | ⏳ 待定位 | | | | input area |

## 8. 自动化进度与实体机墙

本会话在沙箱内已完成、可自动复跑的全部 REA + 打包工作，**进度止于「刷实体机」这一硬墙**：

- ✅ aboot（emmc_appsboot.mbn）Ghidra 原始二进制分析：BootShim 五问全确证（解压目标 0x80008000 / DTB 拷贝 0x80000100 / 跳转 x0=DTB / ARM64 头校验 / boot_verifier 门控）。
- ✅ xbl.elf 内存映射表 + framebuffer 交接（cont_splash_mem@0x83401000）。
- ✅ **真实 BootShim.S 已写**（`uefi-g0245d/BootShim/BootShim.S`，clang 编译为 120 字节 shim，通过 package-g0245d-boot.py 全部断言）。
- ✅ **可刷 boot.img 已产出**（`build/g0245d/boot/g0245d-uefi.img`，结构有效、aboot 必然接收；QEMU fixture 因 qemu 缺失用 `--skip-qemu`）。

**沙箱内无法继续的环节（需实体机 / 完整主机）：**

1. **真 SILICIUM_UEFI.fd 构建**：需要 Mu-Silicium EDK2 框架（沙箱内 raw.githubusercontent.com 不可达、API 限流，无法可靠 fetch）、`nasm`（PATH 缺失，EDK2 BaseTools 需要）、以及 msm8996 专属组件 NativeUfs8996 / Adreno530 / Mdp5 / BlspI2c（上游 README/AGENTS 明确尚未编写）。当前 `g0245d-uefi.img` 内的 FD 为明确标注的占位（0x300000 字节）。
2. **刷机与首启（实体机墙）**：在 G0245D 真机上用 QFIL / fastboot 刷入 `g0245d-uefi.img`，串口（BLSP2 UART2 @ 0x75b0000）观察首启日志——这是沙箱外才能执行的步骤。锁定零售机验证失败不阻断启动，解锁机完全跳过验证；boot 分区写保护时走 QFIL/E DL。
