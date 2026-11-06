#!/usr/bin/env python3
"""从已构建的 SILICIUM_UEFI.fd 里把 UniXNU.efi 抓出来做一致性校验。

FVMAIN 被塞进 FVMAIN_COMPACT 的 GUIDed(LZMA) 段，明文搜字符串必然搜不到，
所以必须先解压再比对：解压 GUIDed 段 -> 内层 FV -> 找 UniXNU FFS -> 抽 PE32，
与 Build/.../AARCH64/UniXNU.efi 逐字节比对，并检查诊断串在不在。

只做静态解析，不执行固件代码。

用法：
  python3 linux/verify-fd-unixnu.py <FD> [--efi <UniXNU.efi>] [--dump out.efi]
"""
import argparse
import hashlib
import lzma
import struct
import sys
from pathlib import Path

LZMA_GUIDS = {
    "ee4e5898-3914-4259-9d6e-dc7bd79403cf": "LZMA",
    "d42ae6bd-1352-4bfb-909a-ca72a6eae889": "LZMAF86",
}

SECT = {0x01: "COMPRESSION", 0x02: "GUID_DEFINED", 0x10: "PE32", 0x11: "PIC",
        0x12: "TE", 0x13: "DXE_DEPEX", 0x14: "VERSION", 0x15: "UI",
        0x17: "FV_IMAGE", 0x18: "FREEFORM_SUBTYPE_GUID", 0x19: "RAW"}


def align(n, a):
    return (n + a - 1) & ~(a - 1)


def guid_str(b):
    d1, d2, d3 = struct.unpack_from("<IHH", b, 0)
    t = b[8:16]
    return (f"{d1:08x}-{d2:04x}-{d3:04x}-{t[0]:02x}{t[1]:02x}-"
            + "".join(f"{x:02x}" for x in t[2:8]))


def fv_file_start(fv):
    hdr_len = struct.unpack_from("<H", fv, 0x30)[0]
    ext = struct.unpack_from("<H", fv, 0x34)[0]
    if ext:
        ext_size = struct.unpack_from("<H", fv, ext)[0]
        return align(ext + ext_size, 8)
    return align(hdr_len, 8)


def decompress_guided(buf, s_off):
    """解压 GUIDed 段（LZMA / LZMA-raw）。返回 (数据或 None, 说明)。"""
    sz = buf[s_off] | (buf[s_off + 1] << 8) | (buf[s_off + 2] << 16)
    if sz == 0xFFFFFF:
        sz = len(buf) - s_off
    guid = guid_str(buf[s_off + 4:s_off + 20])
    name = LZMA_GUIDS.get(guid)
    data_off = struct.unpack_from("<H", buf, s_off + 20)[0]
    payload = buf[s_off + data_off:s_off + sz]
    if name is None:
        return None, f"GUID {guid} 非已知压缩类型（payload {len(payload)} 字节）"
    tries = []
    try:
        out = lzma.decompress(payload, format=lzma.FORMAT_ALONE)
        tries.append((len(out), "ALONE", out))
    except Exception as exc:  # noqa: BLE001
        tries.append((0, "ALONE", type(exc).__name__))
    try:
        out = lzma.decompress(payload, format=lzma.FORMAT_RAW, filters=[
            {"id": lzma.FILTER_LZMA1, "lc": 3, "lp": 0, "pb": 2,
             "dict_size": 1 << 24}])
        tries.append((len(out), "RAW", out))
    except Exception as exc:  # noqa: BLE001
        tries.append((0, "RAW", type(exc).__name__))
    ok = [t for t in tries if isinstance(t[2], bytes)]
    if not ok:
        return None, f"{name} 解压失败 {[(t[0], t[1], t[2]) for t in tries]}"
    ok.sort(key=lambda x: -x[0])
    return ok[0][2], f"{name}({ok[0][1]}) -> {ok[0][0]} 字节"


def walk_files(fv):
    """遍历单个 FV 内的 FFS，产出 (偏移, size, guid, type)。"""
    off = fv_file_start(fv)
    while off + 24 <= len(fv):
        hdr = fv[off:off + 24]
        if hdr == b"\xff" * 24:
            off = align(off + 8, 8)
            continue
        size = hdr[20] | (hdr[21] << 8) | (hdr[22] << 16)
        if size < 24 or off + size > len(fv):
            off = align(off + 8, 8)
            continue
        yield off, size, guid_str(hdr[:16]), hdr[18]
        off = align(off + size, 8)


def walk_sections(fv, file_off, file_size):
    s = file_off + 24
    end = file_off + file_size
    while s + 4 <= end:
        ssz = fv[s] | (fv[s + 1] << 8) | (fv[s + 2] << 16)
        stype = fv[s + 3]
        if ssz == 0xFFFFFF:
            ssz = end - s
        if ssz < 4:
            break
        yield s, ssz, stype
        s = align(s + ssz, 4)


def as_fv(raw):
    """把一段字节裁成以 FV 头开始的镜像（解压结果前面可能带几字节尾巴）。"""
    if len(raw) > 0x2C and raw[0x28:0x2C] == b"_FVH":
        return raw
    idx = raw.find(b"_FVH")
    if idx < 0x28:
        return None
    return raw[idx - 0x28:]


def inner_fv_of_section(buf, s_off, s_size):
    return as_fv(buf[s_off + 4:s_off + s_size])


def guid_to_bytes(s):
    p = s.split("-")
    d1, d2, d3 = (int(x, 16) for x in p[:3])
    return struct.pack("<IHH", d1, d2, d3) + bytes.fromhex(p[3] + p[4])


def find_pe(buf, fv, want_guid):
    """在已解压的 FV 里找目标 FFS 并抽 PE32，找不到返回 None。

    用 GUID 字节对齐扫描而不是顺序遍历：FV 里混着空闲块/擦除态，
    顺序走容易在第一个坏条目后跑偏。
    """
    pat = guid_to_bytes(want_guid)
    hits = []
    i = fv.find(pat)
    while i >= 0:
        if i % 8 == 0:
            size = fv[i + 20] | (fv[i + 21] << 8) | (fv[i + 22] << 16)
            if fv[i + 18] in (0x07, 0x09, 0x06, 0x0B) and 24 < size < len(fv):
                hits.append((i, size, guid_str(fv[i:i + 16]), fv[i + 18]))
        i = fv.find(pat, i + 1)
    for off, size, guid, ftype in hits:
        print(f"    [!] 命中 FFS @0x{off:x} size={size} type=0x{ftype:02x}")
        for so, ssz, st in walk_sections(fv, off, size):
            print(f"        section {SECT.get(st, hex(st))} size={ssz}")
            if st == 0x10:
                return fv[so + 4:so + ssz]
            if st == 0x02:
                out, msg = decompress_guided(fv, so)
                print(f"        -> {msg}")
                if out:
                    return out
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fd")
    ap.add_argument("--efi", help="对照用 UniXNU.efi")
    ap.add_argument("--guid", default="9b665204-a133-47a2-9396-9e2b370a4e25",
                    help="默认 UniXNU 应用 FILE_GUID")
    ap.add_argument("--dump")
    args = ap.parse_args()

    blob = Path(args.fd).read_bytes()
    print(f"[i] FD  {args.fd}")
    print(f"[i]     {len(blob)} 字节  md5={hashlib.md5(blob).hexdigest()}")

    idx = blob.find(b"_FVH")
    if idx < 0:
        print("[!] 找不到 _FVH")
        return 2
    fv0 = idx - 0x28
    fv_len = struct.unpack_from("<Q", blob, fv0 + 0x20)[0]
    print(f"[i] 顶层 FV @0x{fv0:x} len=0x{fv_len:x} "
          f"files_start=0x{fv_file_start(blob[fv0:]):x}")

    pe = None
    for off, size, guid, ftype in walk_files(blob[fv0:]):
        print(f"[i] FFS @0x{off:x} size=0x{size:x} type=0x{ftype:02x} {guid}")
        for so, ssz, st in walk_sections(blob, off, size):
            if st not in (0x17, 0x02, 0x01):
                continue
            print(f"    section {SECT.get(st, hex(st))} @0x{so:x} size=0x{ssz:x}")
            if st == 0x02:
                out, msg = decompress_guided(blob, so)
                print(f"    -> {msg}")
                fv = as_fv(out) if out else None
                if fv:
                    pe = find_pe(blob, fv, args.guid)
                continue
            if st in (0x17, 0x01):
                inner = inner_fv_of_section(blob, so, ssz)
                if inner:
                    pe = find_pe(blob, inner, args.guid)
            if pe:
                break
        if pe:
            break

    if not pe:
        print("[!] 没抽到 UniXNU.efi")
        return 3
    print(f"[i] 抽到 PE32 {len(pe)} 字节")
    if args.dump:
        Path(args.dump).write_bytes(pe)
        print(f"[i] 写出 {args.dump}")

    for label, pat in (("diag-utf16", "drv %u/%u".encode("utf-16-le")),
                       ("diag-ascii", b"drv %u/%u"),
                       ("TMR-utf16", "TMR%u".encode("utf-16-le"))):
        print(f"[i] {label}: {pe.count(pat)} 处")

    if args.efi:
        ref = Path(args.efi).read_bytes()
        same = ref == pe
        print(f"[{'OK' if same else '!!'}] FD 内 UniXNU.efi "
              f"{'与构建产物一致' if same else '与构建产物不一致'}"
              f"（{len(pe)} vs {len(ref)}）")
        return 0 if same else 6
    return 0


if __name__ == "__main__":
    sys.exit(main())
