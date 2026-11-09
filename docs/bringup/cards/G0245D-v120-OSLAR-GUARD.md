# G0245D v120 判读卡 —— 内核第一条指令就在 Kryo 上非法（OSLAR_EL1）

日期：2026-11-09 17:40
镜像：`workspace/tmp/g0245d-v120.img`，56,742,220 B，md5 `2a7aa28bec9c6a3594a62f93d9a5d318`
状态：**待刷入**（两次等待 fastboot 均超时，手机当时不在 fastboot）

---

## 一、v119 的判读结果：绿带有、白带一条都没有

录屏（20.2 s，手机横放 90°）里：

- 屏幕顶部**绿色 hand-off 带**出现了 → `ExitBootServices` 成功、`Entry.S` 已执行、`br x1` 已发出；
- 底部（raw 第 200 行起）**没有任何白色横带** → 内核连"入口第一条指令之后"都没走到。

阶段标记 ① 的位置是 `start_first_cpu` 的第 5 条指令，那么它前面只有 4 条。逐条看：

```
fffffff00741a05c: d510109f   msr OSLAR_EL1, xzr     ← 第一条
fffffff00741a060: d5034fdf   msr DAIFSet, #0xf
```

`OSLAR_EL1` 是 **Apple 硅专属**的 OS-lock 访问寄存器（`OSLAR_EL1`/ED 寄存器组），
ARMv8 规范里该编码是 **UNALLOCATED**。Kryo 280（骁龙 820）不实现它 →
执行到这里触发"未分配系统寄存器"异常。

而此时：MMU 已关、`VBAR_EL1` 还是固件留下的地址（内核要等到后面才写自己的低向量表），
所以这个异常直接进了无人区 —— 表现就是**屏幕静止、既不重启也不出字**。

这也解释了为什么 v118/v119 都是"绿带之后一片死寂"：根本不是内核业务代码的问题，
而是**入口第 1 条指令就炸了**。

## 二、v120 的两处修改（同一份补丁）

1. **阶段标记 ① 提到第一条指令**（用 x0 里的 boot_args，此时 x20 还没设置），
   这样即使后面还有别的 Apple 专属指令炸掉，也能看到"内核确实执行了 1 条指令"。
2. **OSLAR_EL1 加 Apple 实现者判断**：

```asm
	mrs		x9, MIDR_EL1
	lsr		x9, x9, #24
	cmp		x9, #0x61          // 'a' = Apple
	b.ne		1f
	msr		OSLAR_EL1, xzr
1:
```

`reset_vector` 里那条 OSLAR 也一并加了同样的守卫（次核启动走那条路，
`0001-msm8996-smp.patch` 之后会用到）。

反汇编确认（`kernel.macho`，`_start_first_cpu`）：

```
ldr x9, [x0, #0x28]      ← 先画白带
cbz x9, …
ldr x10, [x0, #0x38]
mov x11, #200 … 循环写 0xFFFFFFFF …
mrs x9, MIDR_EL1
lsr x9, x9, #24
cmp x9, #0x61
b.ne …                   ← 非 Apple 跳过 OSLAR
```

## 三、下次看什么

| 现象 | 含义 | 下一步 |
|---|---|---|
| 顶部绿带 + **1 条白带** | 入口执行了，死在 `start_first_cpu` 中段 | 已排除 OSLAR，下一个嫌疑是后续 msr（MAIR/TCR/TTBR/SCTLR）或 `LowExceptionVectorBase` |
| 顶部绿带 + **2 条白带** | 页表建好，死在开 MMU 前后 | 查 `SCTLR_EL1_DEFAULT` 与 4 KiB granule 相关配置 |
| 顶部绿带 + **3 条白带** | 已经开了 MMU，死在 `arm_init`/`arm_vm_init` | 必须上"内核 24bpp 控制台"才能继续看 |
| 绿带 + 0 条白带 | 连第一条指令都没执行 | 回到 `Entry.S` 的 `br x1` / 目标地址 |

白带位置：raw 第 200/232/264 行起，各 32 行高；因面板反扫，会出现在**屏幕下半部**、
由下往上排（避开顶部绿带）。

## 四、顺带确认的构建事实

- `./unixnu build kernel --skip-prelink` → `kernel.macho` **18,256,840 B**（payload 用这个）
- 不加 `--skip-prelink` → **51 MB**（整套 kext 链入），payload 24 MiB / boot 分区 ~64 MB 装不下
- 内核源码改动必须放 `UniXNU-g0245d/patches/xnu/*.patch` + `series`；
  feed 仓 `out/feeds/xnu-b7545ced` 会按 lock 的 `d8b8029` 重新克隆，本地 commit 无效
- 内核构建需 `https_proxy=http://127.0.0.1:7890`（DriverKit 头下载）
