#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
image="${2:-}"
case "$mode" in
    smoke|exception|allocator) ;;
    *) echo "usage: $0 smoke|exception|allocator IMAGE" >&2; exit 2 ;;
esac
if [[ ! -f "$image" ]]; then
    echo "ppos $mode test: image not found: $image" >&2
    exit 2
fi

log="$(mktemp -t "ppos-$mode.XXXXXX")"
monitor="/tmp/ppos-monitor-$mode-$$.sock"
monitor_spec="none"
if [[ "$mode" == "smoke" ]]; then
    monitor_spec="unix:$monitor,server=on,wait=off"
fi
pid=""

cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$log" "$monitor"
}
trap cleanup EXIT

fail() {
    echo "ppos $mode test: FAIL: $1" >&2
    sed -n '1,160p' "$log" >&2
    exit 1
}

qemu-system-x86_64 \
    -kernel "$image" \
    -display none \
    -serial "file:$log" \
    -monitor "$monitor_spec" \
    -nic none \
    -no-reboot \
    -no-shutdown &
pid=$!

wait_for() {
    local pattern="$1"
    local allow_panic="${2:-false}"
    local steps="${PPOS_TEST_STEPS:-100}"
    local boot_count="0"
    for _ in $(seq 1 "$steps"); do
        if rg -Fq "$pattern" "$log"; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            fail "QEMU exited before marker: $pattern"
        fi
        boot_count="$(awk '
            /KLOG SNAPSHOT BEGIN/ { in_snapshot = 1; next }
            /KLOG SNAPSHOT END/ { in_snapshot = 0; next }
            !in_snapshot && /^PP-OS\r?$/ { count++ }
            END { print count + 0 }
        ' "$log")"
        if [[ "${boot_count:-0}" -gt 1 ]]; then
            fail "reboot loop/triple fault detected"
        fi
        if [[ "$allow_panic" != "true" ]] && rg -q "PPOS PANIC" "$log"; then
            fail "unexpected kernel panic"
        fi
        sleep 0.1
    done
    fail "timeout waiting for marker: $pattern"
}

monitor_send() {
    local commands="$1"
    local sender=""
    [[ -S "$monitor" ]] || fail "QEMU monitor socket not ready"
    printf '%b' "$commands" | nc -U "$monitor" >/dev/null 2>&1 &
    sender=$!
    sleep 0.2
    if kill -0 "$sender" 2>/dev/null; then
        kill "$sender" 2>/dev/null || true
    fi
    wait "$sender" 2>/dev/null || true
}

case "$mode" in
    smoke)
        wait_for "PPOS READY"
        rg -Fq "GLUE CONTRACT PASS" "$log" || fail "target C glue selftest did not pass"
        rg -Fq "APP DESCRIPTOR PASS" "$log" || fail "AppDescriptor selftest did not pass"
        rg -Fq "APP CONTEXT PASS" "$log" || fail "AppContext ownership selftest did not pass"
        rg -Fq "APP LIFECYCLE PASS" "$log" || fail "Native App task lifecycle selftest did not pass"
        rg -Fq "TASK RUNTIME PASS" "$log" || fail "task runtime selftest did not pass"
        monitor_send 'sendkey h 20\nsendkey e 20\nsendkey l 20\nsendkey p 20\nsendkey ret 20\n'
        wait_for "commands: help, panic"
        monitor_send 'sendkey l 20\nsendkey o 20\nsendkey g 20\nsendkey ret 20\n'
        wait_for "KLOG SNAPSHOT END"
        awk '
            /KLOG SNAPSHOT BEGIN/ { in_snapshot = 1; next }
            /KLOG SNAPSHOT END/ { in_snapshot = 0 }
            in_snapshot && /PPOS READY/ { found = 1 }
            END { exit found ? 0 : 1 }
        ' "$log" || fail "kernel log snapshot did not replay PPOS READY"
        monitor_send 'sendkey a 20\nsendkey p 20\nsendkey p 20\nsendkey spc 20\nsendkey l 20\nsendkey i 20\nsendkey s 20\nsendkey t 20\nsendkey ret 20\n'
        wait_for "browse CLI web browser"
        wait_for "stack=16384"
        monitor_send 'sendkey a 20\nsendkey p 20\nsendkey p 20\nsendkey spc 20\nsendkey r 20\nsendkey u 20\nsendkey n 20\nsendkey spc 20\nsendkey s 20\nsendkey q 20\nsendkey l 20\nsendkey ret 20\n'
        wait_for "sql app: use app run sql <statement>"
        wait_for "app exit=0"
        monitor_send 'sendkey a 20\nsendkey p 20\nsendkey p 20\nsendkey spc 20\nsendkey l 20\nsendkey i 20\nsendkey s 20\nsendkey t 20\nsendkey ret 20\n'
        wait_for "state=exited:0"
        monitor_send 'sendkey d 20\nsendkey b 20\nsendkey spc 20\nsendkey p 20\nsendkey u 20\nsendkey t 20\nsendkey spc 20\nsendkey l 20\nsendkey i 20\nsendkey f 20\nsendkey e 20\nsendkey c 20\nsendkey y 20\nsendkey c 20\nsendkey l 20\nsendkey e 20\nsendkey spc 20\nsendkey o 20\nsendkey k 20\nsendkey ret 20\n'
        wait_for "kv put ok"
        monitor_send 'sendkey d 20\nsendkey b 20\nsendkey spc 20\nsendkey g 20\nsendkey e 20\nsendkey t 20\nsendkey spc 20\nsendkey l 20\nsendkey i 20\nsendkey f 20\nsendkey e 20\nsendkey c 20\nsendkey y 20\nsendkey c 20\nsendkey l 20\nsendkey e 20\nsendkey ret 20\n'
        wait_for "kv: ok"
        monitor_send 'sendkey m 20\nsendkey c 20\nsendkey p 20\nsendkey spc 20\nsendkey l 20\nsendkey i 20\nsendkey s 20\nsendkey t 20\nsendkey ret 20\n'
        wait_for '"result":{"tools"'
        ;;
    exception)
        wait_for "HALTED" true
        rg -q "PPOS PANIC: CPU exception" "$log" || fail "missing exception panic"
        rg -q "vector=0x0000000000000006 error=0x0000000000000000" "$log" || fail "wrong #UD frame"
        ;;
    allocator)
        wait_for "ALLOCATOR TEST PASS"
        rg -q "memory: usable_end=" "$log" || fail "memory map did not initialize"
        ;;
esac

echo "ppos $mode test: PASS"
