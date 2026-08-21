#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
    echo "usage: $0 ELF..." >&2
    exit 2
fi

readelf_bin="${READELF:-x86_64-elf-readelf}"

for image in "$@"; do
    if [[ ! -f "$image" ]]; then
        echo "ppos permissions test: image not found: $image" >&2
        exit 2
    fi

    headers="$($readelf_bin -lW "$image")"
    if awk '
        $1 == "LOAD" {
            flags = ""
            for (i = 7; i < NF; i++) flags = flags $i
            if (flags ~ /W/ && flags ~ /E/) exit 1
        }
    ' <<<"$headers"; then
        :
    else
        echo "ppos permissions test: writable executable LOAD segment: $image" >&2
        exit 1
    fi

    if awk '
        $1 == "GNU_STACK" {
            flags = ""
            for (i = 7; i < NF; i++) flags = flags $i
            if (flags ~ /E/) exit 1
        }
    ' <<<"$headers"; then
        :
    else
        echo "ppos permissions test: executable GNU stack: $image" >&2
        exit 1
    fi
done

echo "ppos permissions test: PASS"
