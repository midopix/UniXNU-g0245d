# The timer registers on SGIs: a 16-off PPI/INTID mix-up

> 中文摘要：菜单计数停在 10 秒不走、按键全无反应，根因是本板把设备树的 PPI 序号（13/14/11/10）
> 当成 GIC INTID 写进了 `PcdArmArchTimer*IntrNum`，而 EDK2 要求 29/30/27/26。于是 `TimerDxe`
> 把中断处理函数注册在 SGI 上，EL1 物理定时器的 INTID 30 永远没人接，`SetTimer` 事件全部失效
> —— 倒计时和按键去抖同属 `EVT_TIMER` 消费者，一个原因解释两个症状。

**Date:** 2026-11-06
**Scope:** Mu-Silicium (Mu_Basecore ArmPkg and every Qualcomm/Samsung platform package),
the UniXNU tree, and the board's own QFIL `xbl.elf`.
**Result:** no upstream feature was missing. The msm8996 platform package used the
device-tree PPI index where EDK2 expects the GIC INTID, off by 16.

## Symptom

Two symptoms appeared together on the first images that reached the menu (v97, v98):

- the BDS countdown sat at `Booting … in 10 s` and never decremented;
- no hardware key produced any effect, on the menu or in the key probe strip.

`PcdTimerFreqOverwrite` had already been set to 19200000 (the 8996 timebase) and
`AutoGen.c` confirmed the value reached the binary, yet neither symptom changed.
The frequency was never the cause.

## Root cause

`Silicon/Qualcomm/Msm8996Pkg/Msm8996Pkg.dsc.inc` carried:

```
gArmTokenSpaceGuid.PcdArmArchTimerSecIntrNum|13
gArmTokenSpaceGuid.PcdArmArchTimerIntrNum|14
gArmTokenSpaceGuid.PcdArmArchTimerVirtIntrNum|11
gArmTokenSpaceGuid.PcdArmArchTimerHypIntrNum|10
```

Those are the device-tree PPI numbers from `msm8996.dtsi`
(`interrupts = <1 13 8>, <1 14 8>, <1 11 8>, <1 10 8>`). `TimerDxe` takes
`PcdArmArchTimerIntrNum` and passes it straight to `RegisterInterruptSource()`
with no `+16`, so what it needs is the **GIC INTID**, which is PPI + 16:
**29 / 30 / 27 / 26**.

With 13/14 the handler was attached to SGIs, which nothing raises. The EL1
physical timer raises INTID 30, so `TimerInterruptHandler` never ran,
`mTimer.Ticks` never advanced, and every `EVT_TIMER` consumer stalled:
the BDS countdown, and `KeypadDeviceLib`'s 20 ms debounce and repeat. One defect,
two symptoms.

## Four independent lines of evidence

| # | Source | What it shows |
| --- | --- | --- |
| 1 | `Mu_Basecore/ArmPkg/ArmPkg.dec:270-275` | Defaults are Sec 29 / Intr 30 / Hyp 26 / Virt 27, documented as GIC PPI numbers. The stored values are INTIDs. |
| 2 | `ArmPkg/Drivers/TimerDxe/TimerDxe.c:394-425` | `PcdGet32 (PcdArmArchTimerIntrNum)` is handed to `RegisterInterruptSource` unchanged; no `+16` anywhere on the path. |
| 3 | `llvm-objdump -d` on the built `ArmTimerDxe.dll` | v99: `mov w20,#0xe / w21,#0xd / w1,#0xb / w22,#0xa` (14/13/11/10, SGI range). v100: `#0x1e / #0x1d / #0x1b / #0x1a` (30/29/27/26). |
| 4 | `msm8996.dtsi:54` and the stock kernel | The DT declares PPIs 13/14/11/10 and Linux drives the same timer on INTID 29/30/27/26. |

Line 3 is the cheapest acceptance test: disassemble
`Build/g0245dPkg/RELEASE_CLANGPDB/AARCH64/ArmPkg/Drivers/TimerDxe/TimerDxe/DEBUG/ArmTimerDxe.dll`
and look at four immediates. No flash required.

## What the upstream and sibling repositories say

**Mu-Silicium platform packages.** Seven Qualcomm packages (Hana, Rennell, Nazgul,
Starlord, Strait, Napali, Kamorta) set these PCDs explicitly, but with
`SecIntrNum 17` and `IntrNum 18` — PPI 1/2, which matches neither this SoC nor
the ARM standard. Strait also sets `VirtIntrNum 30`. Those are further instances
of the same mistake and must not be copied. The Samsung S5E\* packages only set
`PcdTimerFreqOverwrite|26000000`, which confirms that frequency and INTID are
independent settings — v97 fixed only the former.

**Mu_Basecore.** `ArmGicDxe` selects GICv3 at runtime through `GicV3Supported()`
(ICC_SRE), so GICv3 is not the problem; in `GicV3EnableInterruptSource` only
`Source >= 16` takes the GICR path and `Source` is the raw INTID. The only recent
upstream change in this area is GICv5 PPI support, which does not apply.

**UniXNU.** `docs/porting`, `docs/new-devices-and-drivers` and the
`feat/hardware-buttons` branch cover the XNU kernel and button mapping, not the
UEFI timer. `UniXNU-msm8996-common` records the GIC bases (D `0x9bc0000`,
R `0x9c00000`) and the 19.2 MHz timebase but no INTIDs, so the fix had to be made
on the EDK2 side.

**The board's own firmware, which settles it.** The QFIL `xbl.elf` contains
`ArmGicDxe` (`DE371F7C-DEC4-4D21-ADF1-593ABCC15882`) and `TimerDxe`
(`F099D67F-71AE-4C36-B2A3-DCEB0EB2B7D8`) — the upstream ArmPkg drivers — and
their debug strings still carry `MSM8996_1031/boot_images/ArmPkg/Library/ArmArchTimerLib/ArmArchTimerLib.c`.
Qualcomm wrote no private timer driver for this SoC, so the standard INTID
mapping applies and no Qualcomm special case is needed.

No Mu-Silicium issue or pull request about the 8996 timer was found.

## Change

`Silicon/Qualcomm/Msm8996Pkg/Msm8996Pkg.dsc.inc` now carries 29/30/27/26 with the
derivation inline. The build is `AARCH64` `RELEASE_CLANGPDB`, `PROGRESS - Success`,
and the disassembly check above passes.

v100 is the diagnostic menu from v99 plus this fix, so a single flash answers both
"is it fixed" and "which layer is still broken".

## Reading the menu after the flash

The second menu line reports:

```
drv N/M kit 1 | CPU1 HW1 IRQ1 TMR1 PCT<non-zero>
```

| Field | Meaning | If zero |
| --- | --- | --- |
| `PCT` | `ArmReadCntPctReg()` delta across a fixed busy loop | Physical counter is not running: CNTFRQ/CNTVOFF, or the timebase is still wrong |
| `HW` | `gHardwareInterruptProtocolGuid` present | `ArmGicDxe` did not install it: GIC version detection or `GICR_WAKER` stuck |
| `IRQ` | `Cpu->GetInterruptState()` | Interrupts masked: GIC group enable or DAIF |
| `TMR` | `gEfiTimerArchProtocolGuid` present | TimerDxe did not produce the protocol |
| `CPU` | `gEfiCpuArchProtocolGuid` present | CpuDxe did not start |

If the countdown advances and the keys work, this finding is closed. If the
countdown still stalls while `PCT` moves, `IRQ=1` and `TMR=1`, the handler is
running but events are not dispatched, and the next place to look is
`PcdTimerPeriod` and the `gBS->SetTimer` path in BDS.

## Not yet ruled out

1. GICD/GICR locked by TrustZone so `GICD_CTLR.EnableGrp1NS` never sticks — the
   `IRQ` field would show it.
2. GICR stride on 8996 (`0x20000`) against `PcdGicRedistributorsBase` extrapolated
   per CPU. Four cores need `0x9C00000 + 4 * 0x20000 = 0x9C80000`, still inside the
   `0x100000` window, so this is not suspected yet.
3. The BDS countdown may not be a timer event at all; if it uses `Stall`, it still
   depends on `NanoSecondDelay` and therefore on the same timer library.
