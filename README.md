# UniXNU g0245d

Device support for Gree G0245D（格力手机·色界，2017）, codename `g0245d`, with
Qualcomm MSM8996 (Snapdragon 820). The device profile selects
[UniXNU-msm8996-common](https://github.com/UniXNU/UniXNU-msm8996-common) and the
`ios-16.5-20F66` OS profile in UniXNU.

## Target switch (2026-11-19): iOS 16.5 — declaration only

The board target has been switched from `ipados-17.7.11-21H461` (XNU 10063) to
**iOS 16.5 build 20F66 / Darwin 22.5.0 / XNU 8796.101.5**, mirroring the upstream
`Yuanchu000I/UniXUN-g0345d` branch `device/g0345d-ios16.5`. This is a **declaration
of intent only**: as on the upstream branch, no iOS 16.5 kernel has been built or
booted. The exact restore manifest and the XNU 8796.101.5 source are not present;
`patch_series` is intentionally empty because all inherited patches target XNU
10063.141.1. The OS profile lives as a proposal under
[docs/os-profile-proposal/ios-16.5-20F66/](docs/os-profile-proposal/ios-16.5-20F66/)
— UnixNu resolves profiles from the central `UniXNU/profiles/os` tree, which has
no `ios-16.5-20F66` profile yet. An empty patch list is not a CLI build guard.

**Do not build or boot until** the central profile is landed, restore inputs are
verified, and the patch layers are rebased onto XNU 8796.101.5. To restore the
previous iPadOS target, see `workspace/backup-pre-ios-20261119-1310/`.

## Structure

| Path | Contents |
| --- | --- |
| `porting.toml` | Subsystem inputs, findings, evidence and completion criteria |
| `board.toml` | Device configuration and component selection |
| `feeds.toml` | Pinned SoC source |
| `configs/g0245d_defconfig` | Device kernel settings |
| `dts/g0245d.dts` | Memory, CPU selection, and peripheral configuration |
| `dts/panel-ft8716.txt` | ft8716 DSI panel mode and decoded DCS init sequence |
| `patches/xnu/series` | Board patches |
| `proprietary-files.txt` | Firmware input paths |
| `REA-WORKFLOW.md` | REA reverse-engineering procedure and per-blob task cards |
| `scripts/` | QFIL extraction and device inspection tools |

Stage 1 selects `ArmDTPlatform`, `ArmCpu`, `SoftwareAES`, `XnuPrelink` and
`DarwinBoot` only. No SM8550-specific component (ShengUfs, Adreno740,
AdrenoMetal, DPU, GENI) covers MSM8996: the port needs `NativeUfs8996`,
`Adreno530`, `Mdp5` and `BlspI2c` before the matching peripherals can be
enabled. See [PORTING-PLAN.md](../PORTING-PLAN.md) for the stage schedule.

Hardware facts come from the stock QFIL package (`G0245D_Gree_user_QFIL_images`):
the board device tree (`board.dtb`), the boot image header, the UFS rawprogram
XML and the firmware blobs. `dts/g0245d.dts` carries the real
`cont_splash_mem` range (0x83401000, 0x23ff000) that the stock ABL uses for
the ft8716 panel framebuffer; stage 1 adopts it through `GopFramebuffer`.

## Development record

Maintain [porting.toml](porting.toml) with every subsystem change. It records
hardware, configuration, procedures, findings, evidence and completion criteria.
The [device page](https://unixnu.com/devices/g0245d) renders this record.
Maintainers and agents follow the [same guide](https://unixnu.com/porting/records).
The required `Porting record` CI check validates structure, component coverage
and updates to findings or evidence for changed code.

## Build

Run from the UniXNU checkout:

```sh
./unixnu defconfig g0245d_defconfig --device ../UniXNU-g0245d
./unixnu status --device ../UniXNU-g0245d --json
./unixnu build kernel --device ../UniXNU-g0245d
```

`feeds.toml` pins `REQUIRED_SOC_COMMIT` until the SoC repository reaches a
reviewed commit; the resolver falls back to the local checkout through
`local.toml` / `--local-module` until then.

## Firmware inputs

`proprietary-files.txt` lists the QFIL images consumed by the port. The stock
serial console runs on BLSP2 UART2 (0x75b0000) at 115200 8n1
(`console=ttyHSL0,115200,n8`).
