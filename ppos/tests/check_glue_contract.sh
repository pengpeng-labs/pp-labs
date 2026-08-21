#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d -t ppos-glue-contract.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

cc=x86_64-elf-gcc
cflags=(-ffreestanding -Os -Wall -Wextra -Werror -I"$root/boot/include" -I"$root/boot")

"$cc" "${cflags[@]}" -I"$root/boot/uip" \
    -c "$root/boot/uip_glue.c" -o "$tmp/uip_glue.o"
"$cc" "${cflags[@]}" -I"$root/boot/bearssl" \
    -c "$root/boot/tls_glue.c" -o "$tmp/tls_glue.o"

require_line() {
    local file="$1"
    local line="$2"
    rg -Fqx "$line" "$file" || {
        echo "ppos glue contract: missing ABI declaration: $line" >&2
        exit 1
    }
}

tls="$root/tls.pp"
net="$root/net.pp"
require_line "$tls" 'extern fn uip_glue_connect(ip: u64, port: int) -> int;'
require_line "$tls" 'extern fn uip_glue_send(buf: u64, len: int) -> int;'
require_line "$tls" 'extern fn uip_glue_recv(buf: u64, cap: int) -> int;'
require_line "$tls" 'extern fn br_ssl_engine_sendrec_buf(eng: u64, lenp: u64) -> u64;'
require_line "$tls" 'extern fn br_ssl_engine_recvrec_buf(eng: u64, lenp: u64) -> u64;'
require_line "$net" 'fn pp_e1000_recv(dst: u64, capacity: int) -> int {'
require_line "$net" 'fn pp_e1000_send(buf: u64, len: int) -> int {'
require_line "$net" 'fn pp_dbg(s: u64, size: int) {'

for symbol in uip_glue_contract_selftest uip_glue_last_error; do
    x86_64-elf-nm -g "$tmp/uip_glue.o" | rg -q " T ${symbol}$" || {
        echo "ppos glue contract: missing uIP symbol: $symbol" >&2
        exit 1
    }
done
for symbol in pp_tls_contract_check pp_tls_session_begin pp_tls_session_end; do
    x86_64-elf-nm -g "$tmp/tls_glue.o" | rg -q " T ${symbol}$" || {
        echo "ppos glue contract: missing TLS symbol: $symbol" >&2
        exit 1
    }
done

echo "ppos glue contract: PASS"
