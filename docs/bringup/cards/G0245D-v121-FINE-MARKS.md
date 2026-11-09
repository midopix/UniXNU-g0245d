# G0245D v121 判读卡 —— 修正上一条结论：是 2 条白带，死在 common_start 中段

日期：2026-11-09 18:08
镜像：`workspace/tmp/g0245d-v121.img`，56,742,220 B，md5 `5942bc1495d615e13f405ca7712953e4`
内核：`kernel.macho` 18,256,840 B，sha256 `70b748248c2e…`
状态：**待刷入**（三次等待 fastboot 均超时，手机不在 fastboot）

---

## 一、先纠正我上一条错误结论

你指出的对：底部是**两条**白带，不是零条。我把缩小图看漏了。

放大 + 像素测量后确认：白色区域分成两段（不是一段被压缩），对应 **stage 0 与 stage 1**。
所以：

- **`msr OSLAR_EL1, xzr` 在 Kryo 上并没有触发异常**（它后面才是 stage 0，stage 0 已经画出来了）；
- v120 里我加的 OSLAR 守卫属于"无害但无关"的改动，已经从这个补丁里撤掉（它也正好和
  `0001-msm8996-smp.patch` 的 hunk 打架，撤掉后补丁能干净应用）。

## 二、现在的定位

```
stage 0 ✓  内核入口执行
stage 1 ✓  common_start（引导页表建好）
stage 2 ✗  开 MMU 之前
```

死亡区间 = `common_start:` → `MSR SCTLR_EL1` 之前的**全部寄存器设置**。

顺带排除掉一条：`#if defined(BCM2837)` 那段树莓派定时器路由（写 `0x40000040`）**并没有被编译**——
`XNU_NATIVE_ARCH_TIMER` 会从 `XNU_ARMCPU=1` 回退成 1，`architectural-timer-entry.patch` 因此把该块关掉了。
（我已在成品内核里搜索 `mov w1, #0xf0` / `movz x0, #0x4000`，确认不存在。）

## 三、v121 的做法：把这段拆成 4 个更细的阶段

白带改成 **32 行高、64 行间隔**（互不相连，能数清），新增三条：

| 白带 | raw 行 | 触发点 |
|---|---|---|
| stage 0 | 200 | 内核入口 |
| stage 1 | 264 | `common_start:`（页表建好）|
| **stage 3** | 392 | `MSR TCR_EL1` 之后 |
| **stage 4** | 456 | `MSR TTBR1_EL1`（TTBR0/TTBR1 都设好）之后 |
| **stage 5** | 520 | `MSR MAIR_EL1` + `tlbi` 之后 |
| stage 2 | 328 | `MOV64 x0, SCTLR_EL1_DEFAULT` 之前 |

屏幕上（面板反扫，raw 行越大越靠上）从下往上依次是：**0, 1, 2, 3, 4, 5**。

## 四、下次判读：数白带 + 看最上面那一条到哪

| 最上方的白带 | 结论 |
|---|---|
| stage 1 | 死在 `common_start` 之后第一条（读 `sysreg_restore` 里的 TCR 值 / `MSR TCR_EL1`）|
| stage 3 | 死在 TTBR0(`set_mmu_ttb`)/TTBR1 |
| stage 4 | 死在 MAIR 组装或 `tlbi vmalle1` |
| stage 5 | 死在 TLB/icache 失效、`VBAR_EL1` 设置，或 `SCTLR_EL1` 写入本身 |
| stage 2 | 说明全部设置都过了，死在**开 MMU 那一刻**（页表内容不对 → 一开就 fault）→ 那就去查 `bootstrap_pagetables` / `create_bootstrap_mapping` |

## 五、构建侧这次踩的坑（已记）

1. 补丁的上下文必须按"前序补丁已应用"的树来生成，否则 `git apply` 会在 694 行冲突
   （`architectural-timer-entry.patch` 改的正是那一带）。现在补丁用 `diff -u` 从"含两个相关补丁的树"
   前后对比生成，并已 `git apply --check` 验证可干净应用。
2. `./unixnu build kernel` 首次抓 DriverKit 头可能 `SSL UNEXPECTED_EOF`，重试即可（脚本已循环 3 次）。
