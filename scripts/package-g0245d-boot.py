#!/usr/bin/env python3
"""Package the g0245d UniXNU boot image: gzip(BootShim+FD)+DTB in a v0 container.

Follows the sheng recipe (package-sheng-boot.py) adapted for the MSM8996
stock bootloader (LK aboot in emmc_appsboot.mbn):

  * boot.img v0 header, page_size 4096, kernel_addr 0x80008000
  * kernel slot = gzip(BootShim + UEFI FV) + appended DTB (single entry;
    the stock image carries a 90-entry DTB table, aboot selects by
    qcom,msm-id / qcom,board-id / qcom,pmic-id, which g0245d.dts carries)
  * empty ramdisk (the shim consumes no initrd)

Requires a UniXNU UEFI checkout (uefi-g0245d) with BootShim/BootShim.S and a
built SILICIUM_UEFI.fd; pass it with --uefi (default ../uefi-g0245d).
"""
import argparse
import gzip
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import tomllib
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / 'build/g0245d/boot'
SOC_DTS = ROOT.parent / 'UniXNU-msm8996-common/dts'


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def parse_uint(value):
    return int(str(value), 0)


def find_fd(uefi, target):
    """Locate the freshly built firmware volume for the requested target.

    build_uefi.py writes to <uefi>/Mu-Silicium/Build/g0245dPkg/<TARGET>_CLANGPDB/.
    A bare <uefi>/Build/ tree may also exist; only accept it when it is not the
    checked-in placeholder, so a stale image is never packaged by accident.
    """
    pattern = f'Build/**/{target}_CLANGPDB/**/SILICIUM_UEFI.fd'
    candidates = []
    for search_root in (uefi / 'Mu-Silicium', uefi):
        candidates.extend(sorted(search_root.glob(pattern)))
    for path in candidates:
        if path.read_bytes()[:16] == b'G0245D-PLACEHOLD':
            print(f'== fd: skipping placeholder {path}')
            continue
        return path
    raise SystemExit(f'No built SILICIUM_UEFI.fd for {target} under {uefi} '
                     '(only the placeholder remains); build the firmware first')


def compile_abl_dtb():
    # Appended DTB must carry qcom,msm-id/board-id/pmic-id (aboot DTB table
    # selection) and the stock splash_region (or ABL powers the panel off).
    dtb = OUT / 'g0245d-abl.dtb'
    subprocess.run(['dtc', '-I', 'dts', '-O', 'dtb', '-i', str(SOC_DTS),
                    '-o', str(dtb), ROOT / 'dts/g0245d.dts'], check=True)
    data = dtb.read_bytes()
    if data[:4] != b'\xd0\x0d\xfe\xed' or struct.unpack_from('>I', data, 4)[0] != len(data):
        raise SystemExit('Invalid compiled g0245d DTB')
    for needle in (b'qcom,msm-id', b'qcom,board-id', b'qcom,pmic-id', b'cont_splash_region'):
        if needle not in data:
            raise SystemExit(f'Compiled DTB is missing {needle.decode()}')
    return data


def mkbootimg_v0(kernel, ramdisk, base, kernel_offset, ramdisk_offset,
                 second_offset, tags_offset, pagesize, cmdline, name):
    """Write an Android boot image v0 (ANDROID!) container."""
    header = bytearray(pagesize)
    header[0:8] = b'ANDROID!'
    struct.pack_into('<10I', header, 8, len(kernel), base + kernel_offset,
                     len(ramdisk), base + ramdisk_offset, 0,
                     base + second_offset, base + tags_offset, pagesize, 0, 0)
    header[48:64] = name.encode().ljust(16, b'\0')
    header[64:64 + len(cmdline) + 1] = cmdline.encode() + b'\0'
    image = bytes(header) + kernel
    # ramdisk and second slots are page aligned in v0 containers
    pad = (-len(image)) % pagesize
    image += b'\0' * pad + ramdisk
    pad = (-len(image)) % pagesize
    image += b'\0' * pad
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uefi', default=str(ROOT.parent / 'uefi-g0245d'),
                        help='UniXNU UEFI checkout with BootShim/BootShim.S and Build/*/FV/SILICIUM_UEFI.fd')
    parser.add_argument('--skip-qemu', action='store_true',
                        help='Package with byte round-trip checks only; record that shim execution was not tested')
    parser.add_argument('-b', '--target', default='DEBUG', choices=['DEBUG', 'RELEASE'],
                        help='firmware build target to package (default: DEBUG)')
    parser.add_argument('-o', '--out', default=str(DEFAULT_OUT),
                        help=f'output directory (default: {DEFAULT_OUT})')
    parser.add_argument('--dtb', default=None,
                        help='append this DTB blob instead of compiling dts/g0245d.dts. '
                             'Needed on this device: LK rejects the trimmed tree with '
                             '"dtb not found"; the stock table entry 0 (full 341 KB tree) '
                             'is accepted.')
    parser.add_argument('--kernel-addr', default=None,
                        help='override the kernel load address (hex). LK copies the appended '
                             'DTB to tags_addr (0x80000100); with a 341 KB stock DTB that '
                             'runs past 0x80008000 and would overwrite the shim, so boot '
                             'with the kernel placed above it (0x82000000).')
    args = parser.parse_args()
    uefi = Path(args.uefi)
    global OUT
    OUT = Path(args.out)
    OUT.mkdir(parents=True, exist_ok=True)
    config = tomllib.loads((ROOT / 'board.toml').read_text())
    image_cfg = config['boot_image']
    fd_cfg = config['uefi_fd']
    base, size = parse_uint(fd_cfg['base']), parse_uint(fd_cfg['size'])
    if not config['boot_shim']['requires_kernel_header'] or size % 16:
        raise SystemExit('This recipe requires the configured ARM64 header and 16-byte copy size')
    tools = {name: shutil.which(name) for name in ('clang', 'ld.lld', 'llvm-objcopy', 'llvm-nm', 'dtc')}
    missing = [name for name, path in tools.items() if not path]
    if missing:
        raise SystemExit(f'Missing tools on PATH: {", ".join(missing)} (LLVM, lld and dtc required)')

    fd_path = find_fd(uefi, args.target)
    fd = fd_path.read_bytes()
    print(f'== fd: {fd_path}')
    if len(fd) != size:
        raise SystemExit(f'FD size {len(fd)} differs from board.toml uefi_fd.size {size}')

    shim_src = uefi / 'BootShim/BootShim.S'
    if not shim_src.exists():
        raise SystemExit(f'Missing {shim_src}')
    common = [tools['clang'], '--target=aarch64-none-elf', '-c', f'-DFD_BASE={base}', f'-DFD_SIZE={size}']
    run(*common, '-DREQUIRES_KERNEL_HEADER=1', shim_src, '-o', OUT / 'shim.o')
    run(tools['llvm-objcopy'], '-O', 'binary', OUT / 'shim.o', OUT / 'shim.bin')
    shim = (OUT / 'shim.bin').read_bytes()
    symbols = run(tools['llvm-nm'], '-n', OUT / 'shim.o')
    payload_offset = next(int(line.split()[0], 16) for line in symbols.splitlines() if line.endswith(' _Payload'))
    if payload_offset != len(shim):
        raise SystemExit('Literal pool or padding separates the payload label from the appended FD')
    if shim[56:60] != b'ARM\x64' or struct.unpack_from('<QQ', shim, 8) != (base, len(shim) + size):
        raise SystemExit('ARM64 header does not describe the complete shim + FD')

    results = []
    fixture = uefi / 'BootShim/qemu-entry/bootshim-fixture.S'
    if not args.skip_qemu and fixture.exists():
        run(*common, '-DPAYLOAD=1', fixture, '-o', OUT / 'payload.o')
        run(tools['ld.lld'], f'-Ttext={base:#x}', '-e', '_start', OUT / 'payload.o', '-o', OUT / 'payload.elf')
        run(tools['llvm-objcopy'], '-O', 'binary', OUT / 'payload.elf', OUT / 'payload-code.bin')
        code = (OUT / 'payload-code.bin').read_bytes()
        synthetic = bytearray((bytes(range(256)) * ((size + 255) // 256))[:size])
        synthetic[:len(code)] = code
        (OUT / 'fixture.bin').write_bytes(shim + synthetic)
        import time
        qemu = shutil.which('qemu-system-aarch64')
        if not qemu:
            raise SystemExit('qemu-system-aarch64 not on PATH (or use --skip-qemu)')
        for name, address in [('copy', 0x50000000), ('already-in-place', base - len(shim))]:
            run(*common, f'-DSHIM_BASE={address}', f'-DSHIM_SIZE={len(shim)}', fixture, '-o', OUT / 'entry.o')
            run(tools['ld.lld'], '-Ttext=0x40080000', '-e', '_start', OUT / 'entry.o', '-o', OUT / 'entry.elf')
            run(tools['llvm-objcopy'], '-O', 'binary', OUT / 'entry.elf', OUT / 'entry.bin')
            log = OUT / f'{name}.uart.log'
            log.unlink(missing_ok=True)
            command = [qemu, '-M', 'virt,virtualization=off,secure=off',
                       '-accel', 'tcg', '-cpu', 'cortex-a710', '-m', '2G', '-smp', '1',
                       '-display', 'none', '-monitor', 'none', '-nic', 'none', '-no-reboot',
                       '-serial', f'file:{log}', '-kernel', str(OUT / 'entry.bin'),
                       '-device', f'loader,file={OUT / "fixture.bin"},addr={address:#x},force-raw=on']
            start = time.monotonic()
            with (OUT / f'{name}.stderr.log').open('w') as errors:
                process = subprocess.Popen(command, stdout=errors, stderr=errors)
                try:
                    while process.poll() is None and time.monotonic() - start < 3:
                        if log.exists() and ('PASS' in log.read_text() or 'FAIL' in log.read_text()):
                            break
                        time.sleep(0.02)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
            uart = log.read_text() if log.exists() else ''
            if 'BOOTSHIM: full copy, destination entry and x0 PASS' not in uart or 'FAIL' in uart:
                raise SystemExit(f'{name}: shim fixture failed; inspect {log}')
            results.append({'case': name, 'seconds': round(time.monotonic() - start, 3), 'passed': True})

    if args.dtb:
        dtb_path = Path(args.dtb)
        if not dtb_path.is_absolute():
            dtb_path = Path.cwd() / dtb_path
        dtb = dtb_path.read_bytes()
        if dtb[:4] != b'\xd0\x0d\xfe\xed':
            raise SystemExit(f'{dtb_path} is not a flattened device tree')
        print(f'== dtb: {dtb_path} ({len(dtb)} bytes, external)')
    else:
        dtb = compile_abl_dtb()
    combined = shim + fd
    kernel = gzip.compress(combined, mtime=0) + dtb
    (OUT / 'Image.gz-dtb').write_bytes(kernel)
    # No initrd is consumed by the shim. Avoid the upstream literal "dummy" file.
    (OUT / 'ramdisk').write_bytes(b'')
    cmdline = ('console=ttyHSL0,115200,n8 androidboot.console=ttyHSL0 '
               'androidboot.hardware=qcom user_debug=31 msm_rtb.filter=0x237 '
               'ehci-hcd.park=3 lpm_levels.sleep_disabled=1 cma=32M@0-0xffffffff')
    base_addr = parse_uint(image_cfg['base'])
    kernel_addr = (parse_uint(args.kernel_addr) if args.kernel_addr
                   else base_addr + parse_uint(image_cfg['kernel_offset']))
    if dtb and not args.kernel_addr:
        tags = base_addr + parse_uint(image_cfg['tags_offset'])
        if tags + len(dtb) > kernel_addr:
            raise SystemExit(
                f'appended DTB at {tags:#x}+{len(dtb):#x} would overwrite the kernel/shim at '
                f'{kernel_addr:#x}; pass --kernel-addr above {tags + len(dtb):#x}')
    boot = mkbootimg_v0(kernel, b'', base_addr,
                        kernel_addr - base_addr,
                        parse_uint(image_cfg['ramdisk_offset']),
                        parse_uint(image_cfg['second_offset']),
                        parse_uint(image_cfg['tags_offset']),
                        image_cfg['pagesize'], cmdline, 'g0245d')
    (OUT / 'g0245d-uefi.img').write_bytes(boot)

    # Round-trip: header fields, kernel bytes, gzip stream and appended DTB.
    if boot[:8] != b'ANDROID!':
        raise SystemExit('Container magic mismatch')
    words = struct.unpack_from('<10I', boot, 8)
    kernel_size, kernel_address, ramdisk_size, _, second_size, _, tags, page_size, version, _ = words
    if (kernel_size != len(kernel) or ramdisk_size or second_size
            or version != image_cfg['header_version'] or page_size != image_cfg['pagesize']
            or kernel_address != kernel_addr
            or tags != parse_uint(image_cfg['base']) + parse_uint(image_cfg['tags_offset'])
            or boot[page_size:page_size + kernel_size] != kernel):
        raise SystemExit('Android container round-trip failed')
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    unpacked = decompressor.decompress(boot[page_size:page_size + kernel_size])
    if not decompressor.eof or unpacked != combined or decompressor.unused_data != dtb:
        raise SystemExit('gzip/FD/appended-DTB round-trip failed')
    if len(boot) > 64 * 1024 * 1024:
        raise SystemExit('Container exceeds the 64 MiB boot partition')

    report = {'fd_sha256': digest(fd), 'shim_sha256': digest(shim), 'shim_bytes': len(shim),
              'image_size': len(combined), 'android_header_version': version,
              'kernel_address_field': hex(kernel_address), 'dtb_sha256': digest(dtb),
              'container_sha256': digest(boot), 'container_bytes': len(boot),
              'qemu': results, 'qemu_skipped': args.skip_qemu,
              'hardware_tested': False, 'bootloader_acceptance_proven': False,
              'caches_tested': 'not tested in this package run' if args.skip_qemu else 'MMU/cache-off QEMU fixture only',
              'limitations': [
                  'Stock firmware uses a 90-entry DTB table; this container appends a single DTB and relies on the aboot matcher accepting the sole entry (qcom,msm-id 0xf6/0x30000, board-id 3/0, pmic-id 0x20009/0x2000a).',
                  'aboot appended-DTB copy destination, jump register state and boot_verifier gating remain unverified until the Ghidra pass lands.',
              ]}
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
