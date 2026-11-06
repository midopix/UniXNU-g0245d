# Kernel and system build materials

> 中文摘要：这一页记"编内核和系统到底需要哪些外部材料、各自从哪来、怎么校验、现在还缺什么"。
> 结论：能按官方路径自动取的全部已取到并通过 pin 校验；真正缺的只有 `patches/xnu/series`
> 里那 5 个板级补丁，它们是驱动代码，任何仓库都没有，不能伪造。

Everything below is fetched from its official source and verified against the pin
recorded in `board.toml` and the OS profile. Nothing is fabricated or substituted.

## What is needed, where it comes from, how it is checked

| Material | Source | Lands in | Check |
| --- | --- | --- | --- |
| 19 module submodules | `unixnu fetch` | `unixnu-src/{drivers,kits}/` | `git submodule status` has no `-` prefix |
| 8 Apple open-source feeds | `unixnu fetch` | `out/feeds/` (460 MB) | `unixnu.lock` written |
| KernelCache | IPSW range read | `out/ipsw/21H461/kernelcache.decompressed` | sha256 `f18b4df8…9de7` equals the board pin |
| DeviceTree | IPSW range read | `out/ipsw/21H461/DeviceTree.j120ap.im4p` (35,260 B) | sha256 in the `.json` matches the profile |
| Two trustcaches | IPSW range read | `044-76040-038.dmg.trustcache`, `044-76034-038.dmg.trustcache` | same |
| OS volume | IPSW | `044-76040-038.dmg` (5,157,406,069 B) | sha256 `3f99b859…` equals the profile `[ipsw.sha256]` |
| SystemOS volume | IPSW | `044-76034-038.dmg` (3,303,014,400 B) | sha256 `b4908cde…` |
| Host dependencies | `apt-get download` | `workspace/tmp/toolchain-root/` | `setup-toolchain.py --check` prints `host dependencies ready` |

The feeds are `xnu`, `libplatform`, `libdispatch`, `AvailabilityVersions`,
`mu_basecore`, `libpthread`, `corecrypto-2023` and `IOStorageFamily`, fetched
shallow, blobless and sparse.

**The whole IPSW is not required for the kernel.** `scripts/unixnu/ipsw.py` reads the zip
central directory over HTTP range and fetches only the members listed in
`board.toml [ipsw] fetch`, so the kernel material costs about 16 MB of traffic. The two
system volumes do need a real download; see `docs/pitfalls.md` for why a local file plus
`--ipsw` is the reliable route.

## What is still missing

`patches/xnu/series` lists five board patches that do not exist yet:

| Patch | Covers |
| --- | --- |
| `0001-gic-v3-3cell.patch` | 3-cell GICv3 interrupt specifiers in ArmCpu, next to the SM8550 4-cell path |
| `0002-blsp-qup-v2.patch` | QUP v2 register layout and BLSP1/BLSP2 clock gating |
| `0003-smmu-v2.patch` | smmu-v2 context bank layout for `adreno_smmu@b40000` and the UFS SMMU |
| `0004-ufs-2.0.patch` | UFS 2.0 register set and UniPro 1.8 attributes |
| `0005-mdp5-dsi-video.patch` | DSI0 video-mode timing and the ft8716 command sequence |

These are board driver code. They were searched for in three places: the upstream
`UniXNU/UniXNU` repository, the only other public device repository (`UniXNU-sheng`,
SM8550), and a GitHub-wide `gic-v3-3cell in:path` code search. There is no public source
for them, and generating them by hand would mean writing five drivers, not restoring a
file.

Until they exist, `unixnu build kernel` stops at the patch stage. The command below
reports the current state and is the entry point for this work:

```sh
bash scripts/linux/build-xnu-kernel.sh --check
```

Its checks resolve paths the way the CLI actually writes them (`out/feeds/`,
`out/ipsw/<build>/kernelcache*`), because an earlier version looked under
`UniXNU-g0245d/refer/` and reported materials as missing after they had been fetched.
