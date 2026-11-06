#!/usr/bin/env bash
# extract-qfil.sh — unpack the stock G0245D QFIL package and inventory it.
#
# Usage: scripts/extract-qfil.sh <zip-or-dir> [outdir]
#
# Defaults:
#   input   ../../firmware/G0245D_Gree_user_QFIL_images.zip
#   outdir  ../../firmware/extracted
#
# The script is read-only with respect to the input archive: it unpacks into
# the output directory and writes manifest.sha256 plus inventory.txt next to
# the unpacked tree. It never flashes anything.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="${1:-$HERE/../../firmware/G0245D_Gree_user_QFIL_images.zip}"
OUTDIR="${2:-$HERE/../../firmware/extracted}"

if [[ ! -e "$INPUT" ]]; then
    echo "error: input not found: $INPUT" >&2
    echo "usage: $0 <zip-or-dir> [outdir]" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

if [[ -d "$INPUT" ]]; then
    echo "[*] input is a directory; nothing to unpack"
    SRC="$INPUT"
    DEST="$INPUT"
else
    echo "[*] unpacking $INPUT -> $OUTDIR"
    unzip -q -o "$INPUT" -d "$OUTDIR"
    SRC="$INPUT"
    DEST="$OUTDIR/$(basename "$INPUT" .zip)"
fi

echo "[*] writing SHA-256 manifest"
( cd "$DEST" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$DEST/manifest.sha256"

echo "[*] writing inventory"
{
    echo "# G0245D QFIL package inventory"
    echo "# source: $SRC"
    echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    printf '%-12s %-10s %s\n' "SIZE" "KIND" "PATH"
    find "$DEST" -type f | sort | while read -r f; do
        rel="${f#"$DEST"/}"
        size=$(stat -c %s "$f")
        kind=$(file -b --mime-type "$f")
        printf '%-12s %-10s %s\n' "$size" "$kind" "$rel"
    done
} > "$DEST/inventory.txt"

echo
echo "[*] key artifacts:"
grep -iE "vmlinux|boot\.img|xbl|M8996|firehose|NON-HLOS|splash|rawprogram|gpt_|\.ko$|\.elf$" "$DEST/inventory.txt" || true
echo
echo "[+] done: $DEST"
echo "    next: python3 scripts/extract-files.py $DEST"
