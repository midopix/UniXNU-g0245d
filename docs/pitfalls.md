# Build and flash pitfalls

> 中文摘要：这一页是本板移植过程中真实踩到并已修掉的坑，按"症状 → 根因 → 做法"记。
> 主要集中四类：工具链标签在四个地方各写一遍、EDK2 的 `cp -p` 在受限环境假失败、
> FD 被 LZMA 包起来导致 `strings` 永远搜不到新代码、以及没有 root 时怎么把依赖装到用户目录。

Each entry is a failure that actually happened on this port, with the fix. Commands are
for a Linux host.

## Toolchain

**Four places pin the toolchain tag, and only one of them wins.**
`switch-toolchain-linux.sh` edits three files, but `Platforms/Gree/g0245dPkg/DeviceBuild.py:166`
sets `TOOL_CHAIN_TAG` itself and overrides `Conf/target.txt`. Editing only `target.txt`
produces a build under `RELEASE_CLANGDWARF` while the packaging step reads
`RELEASE_CLANGPDB`, which looks like a failed build with a fresh timestamp. This port
uses `CLANGPDB` everywhere, matching v90 through v97.

`CLANGPDB` is also the only tag that works here: switching to `CLANGDWARF` trips
`RamManagerDxe`'s `-Werror,-Wsometimes-uninitialized` under clang 21.

**`cp -p` fails the build with `error 7000`.** EDK2 calls `cp -p` and the sandbox
refuses `utimensat`, so the copy succeeds but the command reports failure. Put a
wrapper early on `PATH` that strips `-p`. In this tree that is `workspace/tmp/bin/cp`,
added by `env.sh`.

**`mu_nasm` needs Mono.** The NuGet package is fetched by `DeviceBuild.py --update`;
without `mono-devel` the extraction dies. `apt-get install mono-devel` and rerun the
update.

## Verifying the firmware volume

**`strings` on `SILICIUM_UEFI.fd` can never find new C code.** `FVMAIN` is wrapped in
`FVMAIN_COMPACT` as an `EFI_SECTION_GUID_DEFINED` with GUID
`EE4E5898-3914-4259-9D6E-DC7BD79403CF` (LZMA), so the `.fd` holds compressed bytes
only. The working chain:

1. the top-level FV has exactly one `FV_IMAGE` FFS (`9E21FD93-9C72-4C15-8C4B-E77F1DB2D792`);
2. its section is GUIDed, `DataOffset` comes from the `u16` at `+20`;
3. `lzma.decompress(payload, format=lzma.FORMAT_ALONE)` yields the inner FV, whose first
   8 bytes are a leftover tail — locate the header by searching for `_FVH` instead of
   assuming offset 0;
4. the inner FV has an extension header: `HeaderLength=0x48` but `ExtHeaderOffset=0x60`,
   so the FFS area starts at `align(0x60 + u16@0x60, 8) = 0x4ce8`, not `0x48`.

Three parsing traps, all hit:

- **The FFS size lives at offset 20**: `Name[16] + IntegrityCheck[2] + Type@18 +
  Attributes@19 + Size@20..22 + State@23`. Reading offset 19 yields a nonsense size and
  the walk derails immediately.
- The inner FV contains free and erased blocks, so **a sequential walk goes wrong after
  the first bad entry**. Scan for the target GUID on 8-byte alignment and validate
  `Type` and the size instead.
- **`GenFds` does not always update the `.fd` mtime.** v99 finished building at 16:02 and
  the `.fd` mtime stayed at 15:59. Never judge freshness by mtime: decompress and compare
  content.

`scripts/linux/verify-fd-unixnu.py <FD> [--efi <UniXNU.efi>] [--dump out.efi]` implements
this chain; it exits non-zero unless the PE32 inside the FV matches the build output byte
for byte.

## Packaging and flashing

**`finish-build.sh` parsed only `$2`.** `finish-build.sh v99 --allow-same-fd --no-flash`
fell through to "run everything" and then called a non-existent
`tools/flash/auto-flash-watch.sh`, failing with 127 after a successful pack. The script now
walks `"$@"`.

**`pack-boot-linux.sh` defaulted the mode to a literal `--`.** `MODE="${2:---}"` produced
the string `--` instead of an empty default. Fixed.

**Two builds of identical sources produce different image md5s,** because
`SOURCE_DATE_EPOCH` is unset and the build stamps the current time. Compare the FD content,
not the md5, and let the flash script pin the md5 it expects rather than comparing two
builds against each other.

**`avb footer` warning on `fastboot boot` is normal.** This aboot prints it and proceeds.

## Vendor inputs

**`Binaries/g0245d` is a submodule, so a source-only checkout cannot build.** The build
stops at `SPMI.inf is not found`. Restore the vendor DXE images from the QFIL package into
`Binaries/g0245d` before building; `proprietary-files.txt` lists them by hash and they are
kept out of Git.

## Host dependencies without root

`sudo` fails in a restricted sandbox with `The "no new privileges" flag is set`, so apt
cannot be used directly. `apt-get download` does not need root:

```sh
cd /tmp && apt-get download flex bison tcsh libclang-21-dev libbsd-dev libssl-dev
```

**`dpkg -x` exits early on `utime` errors and silently loses the tail of the package.**
It died on `tar: ./usr/bin/bison: cannot utime` and left `bsd/unistd.h` missing. Extract
by hand instead:

```sh
ar x pkg.deb && unzstd -c data.tar.zst | tar -xmf - -C "$PREFIX"
```

`tar -m` (touch) skips mtime restoration, which is what avoids `utimensat`. Ubuntu 26.04
packages are `data.tar.zst`; older ones are `.xz`.

**The `libclang` probe needs three merged include trees.** `setup-toolchain.py --check`
compiles `clang-c/Index.h`, `bsd/unistd.h`, `uuid/uuid.h`, `openssl/ssl.h` and `zlib.h` and
links `-lclang -lbsd -luuid -lssl -lz`, with `-I/-L` pointing only at
`llvm-config --includedir/--libdir`. The system `llvm-config` ships `llvm/ llvm-c/`, the
`libclang-21-dev` package ships `clang/ clang-c/`, `bsd/` and `openssl/opensslconf.h` live
in the multiarch subdirectory, and `-lbsd` pulls `-lmd`. A `llvm-config` wrapper that
overrides only `--libdir/--includedir` plus symlinks for every library resolves it.

**`lzfse` is not packaged for a no-root install.** Build the pinned commit instead;
cmake 4 rejects the 2.x `cmake_minimum_required`, so pass
`-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.

## Downloads

**`unixnu fetch` fails with `git failed (128)` while every submodule actually succeeded.**
The log shows all 19 checkouts and then `error: waitpid for git-submodule failed`. The
parallel spawn does not work in this sandbox. Inject serial fetching for the single command
rather than editing any config:

```sh
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=submodule.fetchJobs GIT_CONFIG_VALUE_0=1
```

**`unixnu ipsw fetch` stalls on remote range reads.** It reached 3.08 GB with no progress
for eight minutes and has no timeout. Download the whole IPSW with `curl -C -` and pass
`--ipsw <local file>`; the extraction step then runs locally. The kernel materials alone
only need ~16 MB of range reads, so the whole file is only worth it for the two system
volumes.

**The documented `./unixnu payload` route does not produce a payload here.** Chasing
`[payload] tools = true` (https://unixnu.com/zh/porting/log-capture) stops twice:

```
$ ./unixnu payload --device ../UniXNU-g0245d --uefi ../uefi-g0245d
unixnu: kernel not found: .../kernel/kernel.macho; run "unixnu build kernel" or pass --kernel FILE
$ ... --kernel out/ipsw/21H461/kernelcache.decompressed --unique-chip-id 0123456789ABCDEF
unixnu: arm-io needs a non-zero base: an exported register lies below 16 MiB
```

The second is structural, not a porting bug: `scripts/unixnu/devicetree.py:192`
(`arm_io_window`) rounds the lowest exported register down to a 16 MiB boundary and
rejects `base == 0`, and MSM8996 keeps a large part of its peripheral space below
16 MiB (UFS at `0x624000`, BLSP1 at `0x75xxxx`, MDSS at `0x900000`). Every SoC the
upstream guide targets keeps peripherals above `0x1000000`.

It is also unnecessary. `UniXNULib/Config.c`'s `mBuiltinConfig` already lists the
Tools entry (`timeout = 10 / Return to firmware / Restart / Power off / Tools`), so
the menu shows Tools with no payload volume at all; the volume only replaces that
built-in menu. What was missing is the plugin behind Tools, and that is
`UniXNUPkg/Driver/AdvancedLogDxe` — it needs the Advanced Logger buffer, not a
payload. v101 wires the buffer (see uefi-g0245d `docs/advanced-logger.md`).

**`arm_io_window()`'s non-zero base assertion is wrong for MSM8996.** The packer
refused to build a payload because UFS sits at `0x624000`. XNU reads the SoC base
from arm-io's `ranges` parent address (`pexpert/arm/pe_identify_machine.c`,
`pe_arm_get_soc_base_phys`), and `0` is a legal value there: `gPicBase = soc_phys
+ offset` then yields the absolute physical address, which is exactly right for a
SoC whose address space starts at 0. The assertion conflated "window starts at 0"
with "no window found". Patch `patches/unixnu/0003-linux-host-without-root.patch`
drops it; `unixnu payload` then produces a 192 MiB `payload.img`.

**BootShim's ARM64 `image_size` must cover the shim itself.** `BootShim.S` wrote
`FD_SIZE`, so `unixnu bootimg` rejected the image ("the ARM64 image header does
not describe the shim plus the firmware volume"). aboot ignores the field, which
is why the local packer never noticed. The value must be `shim length + FD_SIZE`;
use a label difference `(_Payload - _Head)`, because an absolute `_Payload`
reference needs a relocation that `llvm-objcopy -O binary` cannot apply.
Patch: `uefi-g0245d/patches/mu/0002-bootshim-image-size.patch`.
