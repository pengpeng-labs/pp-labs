#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$root/tests/run_qemu_test.sh" allocator "$root/allocator-test.elf"
