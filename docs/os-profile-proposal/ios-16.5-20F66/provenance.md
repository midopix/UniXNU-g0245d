# iOS 16.5 profile provenance

This profile selects the iPhone OS release **iOS 16.5 (20F66)**, reported as
Darwin **22.5.0**. The selected source baseline is XNU **8796.101.5** at
aca3beaa3dfbd42498b42c5e5ce20a938e6554e5, following the pinned
UniXNU-NX769J reference profile. This is a UniXNU porting baseline; it is not
a claim that this commit is the exact source revision used in Apple's retail
20F66 kernel.

The reference restore product iPhone10,3 is only the iPhone OS software donor
identity. This profile does not adopt NX769J's hardware identity. The target
remains GREE G0245D with its real MSM8996 SoC, device tree, firmware, storage
layout, and board drivers.

## Deliberately unresolved inputs

The exact iOS 16.5 restore URL, restore device_class, chip_id, board_id, and
IPSW member hashes are not recorded here. Resolve them from the selected
20F66 restore manifest before running a build that consumes an IPSW. No hash,
UUID, or restore identity values are guessed.

The profile contains no ADT identity, DeviceTree, nonce, kernelcache hash,
prelink slide, root list, early-security initializer, or other NX769J prelink
values. Derive and qualify prelink inputs against the exact 20F66 kernelcache
and G0245D port. Keep G0245D/MSM8996 board values in the device and SoC layers.

The iOS config fragment enables only the existing mock-filesystem and native
code-signing hash-cache options. It does not enable runtime trust-cache
enforcement: the G0245D native-only bring-up has not qualified the Apple
Image4/AMFI provider closure. The OS-specific XNU patch series is intentionally
empty pending rebasing and applicability checks on the selected source.

## Integration requirements

1. Set the G0245D board's os_profile to ios-16.5-20F66 and use
   os:configs/ios.config; preserve name = g0245d, soc = msm8996, the G0245D
   DTS, and all board-level firmware, storage, and driver inputs.
2. Resolve the iPhone 20F66 restore metadata from its manifest, then set the
   required IPSW fields and verify the profile against that local restore.
3. Derive G0245D-compatible prelink inputs from that restore's kernelcache;
   do not import donor-board addresses or ADT properties.
4. Rebase and strictly apply each selected ARM64, SoC, and G0245D patch series
   against the pinned XNU baseline before invoking kernel build or device boot.
5. Record the resolved source SHA, IPSW member hashes, prelink report, build
   inputs, and hardware checkpoints before treating the profile as integrated.

## Sources

- The local profile schema and layer merge rules: UniXNU scripts/unixnu/profiles.py
  and scripts/unixnu/feeds.py.
- The build's IPSW identity checks and optional hash pin behavior:
  UniXNU scripts/unixnu/ipsw.py.
- OS/version/source baseline: pinned UniXNU-NX769J reference profile at
  https://github.com/Asultop/UniXNU-NX769J/blob/841a86ace1caa36c0528fbf6133df36acc41b516/os-profiles/ios-16.5-20F66/profile.toml.
- iOS 16.5 release/build identifier: Apple iOS 16.5 security release notes
  and the same pinned reference profile.

## Local provenance

Mirrored from upstream `Yuanchu000I/UniXUN-g0345d` branch
`device/g0345d-ios16.5` (commit a230c018, 2026-11-19), adapted from G0345D to
G0245D. This is a PROPOSAL only — UnixNu resolves profiles from the central
UniXNU/profiles/os tree, which currently has no `ios-16.5-20F66` profile.
