# UniXNU g0245d

Device support for Gree G0245D（格力手机·色界，2017）, codename `g0245d`:
Qualcomm MSM8996 (Snapdragon 820), 4 GB LPDDR4, 64 GB UFS 2.0, Adreno 530,
1080x1920 MDP5 panel with a FocalTech ft8716 controller.

This repository follows the [device repository format][device-repo] and selects
[UniXNU-msm8996-common][soc-repo] plus the `ipados-17.7.11-21H461` OS profile.
The UEFI platform lives in [uefi-g0245d][uefi-repo] because Mu-Silicium carries
no msm8996 silicon package.

## Status

Stage 1 is closed and stage 2 is in progress on hardware.

| Item | State |
| --- | --- |
| Firmware build | Green on Linux, `AARCH64` `RELEASE_CLANGPDB`, FD exactly `0x300000` bytes |
| Boot chain | `fastboot boot` reaches the UniXNU menu; aboot accepts the BootShim container |
| Display | Known frame on the real panel through the GOP handoff, 1080x1920, 24 bpp |
| Timer | Root-caused to a PPI/INTID mix-up and fixed; the fix is built and awaits a flash |
| Input | Silent on the last flashed image, attributed to the same timer defect |
| Payload | Not discovered yet: the FD still lacks the RamDisk/DiskIo/Fat chain |
| Kernel | Materials downloaded and pin-verified; five board XNU patches missing |

The timer defect is the interesting one and it is written up in
[docs/timer-ppi-finding.md](docs/timer-ppi-finding.md): `Msm8996Pkg.dsc.inc`
carried the device-tree PPI numbers 13/14/11/10 where EDK2 wants GIC INTIDs
29/30/27/26, so `TimerDxe` registered its handler on SGIs, no timer event ever
ran, and both the BDS countdown and the keypad debounce went silent.

## Structure

| Path | Contents |
| --- | --- |
| `porting.toml` | Subsystem inputs, configuration, findings, evidence and completion criteria |
| `board.toml` | Device configuration, component selection, payload and boot image parameters |
| `feeds.toml` | Pinned SoC source |
| `configs/g0245d_defconfig` | Device kernel settings |
| `dts/g0245d.dts` | Memory, CPU selection, reserved regions and peripheral enablement |
| `dts/panel-ft8716.txt` | ft8716 DSI panel mode and decoded DCS init sequence |
| `patches/xnu/series` | Ordered board patch series (five patches, not yet authored) |
| `proprietary-files.txt` | Firmware input paths and hashes consumed by the port |
| `REA-WORKFLOW.md` | Reverse-engineering procedure and per-blob task cards |
| `docs/` | Engineering records: timer finding, build pitfalls, kernel material status |
| `scripts/` | QFIL extraction, firmware packaging, flashing and image verification |
| `scripts/linux/` | Linux host drivers for build, pack, flash and inspection |

## Build

Host is Linux. The UniXNU CLI drives kernel and payload; the firmware comes from
the overlay repository through `[firmware]` in `board.toml`.

```sh
# firmware (Mu-Silicium checkout with the g0245d overlay applied)
MU=<mu-silicium> bash scripts/linux/build-firmware.sh

# boot image
UEFI=<uefi-g0245d> bash scripts/linux/pack-boot.sh

# verify that new C code really reached the FD before flashing
python3 scripts/linux/verify-fd-unixnu.py \
  <mu-silicium>/Build/g0245dPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd \
  --efi <mu-silicium>/Build/g0245dPkg/RELEASE_CLANGPDB/AARCH64/UniXNU.efi

# flash (fastboot boot: RAM only, a bad build costs a power cycle)
bash scripts/linux/flash.sh --wait 300
```

Before a build, restore the vendor DXE images that are not in Git (see
`proprietary-files.txt`); a source-only checkout stops at `SPMI.inf is not found`.
`docs/pitfalls.md` lists the failure modes that are easy to hit here: the
`cp -p` denial, the four places that pin the toolchain tag, the LZMA-wrapped
FVMAIN that makes `strings` on the FD useless, and the `finish-build.sh`
argument parsing bug.

## Kernel and system materials

`scripts/linux/build-xnu-kernel-linux.sh --check` reports what is missing before a
kernel build. Downloaded and pin-verified: 19 module submodules, 8 Apple
open-source feeds, the 21H461 kernelcache (`f18b4df8…`), the device tree, two
trustcaches and both system volumes (`3f99b859…`, `b4908cde…`). The five board
patches in `patches/xnu/series` are the only real gap; they are board driver code,
not downloadable material. See [docs/xnu-materials.md](docs/xnu-materials.md).

## Firmware inputs

`proprietary-files.txt` lists the QFIL images the port consumes. The stock serial
console is BLSP2 UART2 at `0x75b0000`, 115200 8n1
(`console=ttyHSL0,115200,n8`); the pads are not broken out on the retail unit, so
the screen and storage are the working observation channels.

## Development record

Maintain [porting.toml](porting.toml) with every subsystem change. It records
hardware, configuration, procedures, findings, evidence and completion criteria.
The [device page](https://unixnu.com/devices/g0245d) renders this record, and
maintainers and agents follow the [same guide][records]. Update an area's findings
or evidence in the same change as the code it describes.

## License

BSD-2-Clause-Patent, matching UniXNU.

[device-repo]: https://unixnu.com/porting/device-repository
[soc-repo]: https://github.com/midopix/UniXNU-msm8996-common
[uefi-repo]: https://github.com/midopix/uefi-g0245d
[records]: https://unixnu.com/porting/records
