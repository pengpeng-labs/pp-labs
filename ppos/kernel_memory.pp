/* Multiboot memory discovery and the bounded kernel heap. */

extern fn kernel_image_start() -> u64;
extern fn kernel_image_end() -> u64;
extern fn bootstrap_stack_start() -> u64;
extern fn bootstrap_stack_end() -> u64;

static heap_ptr: u64;
static heap_limit: u64;
static heap_free: u64;
static allocator_test_error: int = 0;

static memory_region_start: [48]u64;
static memory_region_end: [48]u64;
static memory_region_kind: [48]int;
static memory_region_count: int = 0;
static usable_memory_end: u64;
static memory_map_error: int = 0;

fn memory_region_add(start: u64, end: u64, kind: int) -> bool {
    if (end <= start || memory_region_count >= 48) {
        return false;
    }
    memory_region_start[memory_region_count] = start;
    memory_region_end[memory_region_count] = end;
    memory_region_kind[memory_region_count] = kind;
    memory_region_count = memory_region_count + 1;
    return true;
}

fn memory_range_is_usable(start: u64, end: u64) -> bool {
    let i: int = 0;
    while (i < memory_region_count) {
        if (memory_region_kind[i] == 1
            && start >= memory_region_start[i]
            && end <= memory_region_end[i]) {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn memory_usable_limit(address: u64) -> u64 {
    let i: int = 0;
    while (i < memory_region_count) {
        if (memory_region_kind[i] == 1
            && address >= memory_region_start[i]
            && address < memory_region_end[i]) {
            return memory_region_end[i];
        }
        i = i + 1;
    }
    return 0 as u64;
}

fn memory_map_init(magic: u64, info: u64) -> bool {
    memory_map_error = 0;
    memory_region_count = 0;
    usable_memory_end = 0 as u64;
    if (magic != (0x2BADB002 as u64) || info == (0 as u64)) {
        memory_map_error = 1;
        return false;
    }
    let flags: int = volatile_load32(info);
    if ((flags & 0x40) == 0) {
        memory_map_error = 2;
        return false;
    }
    let mmap_len: u64 = (volatile_load32(info + 44) as u32) as u64;
    let mmap_addr: u64 = (volatile_load32(info + 48) as u32) as u64;
    let cursor: u64 = mmap_addr;
    let map_end: u64 = mmap_addr + mmap_len;
    while (cursor + 24 <= map_end) {
        let entry_size: u64 = (volatile_load32(cursor) as u32) as u64;
        let next: u64 = cursor + entry_size + 4;
        if (entry_size < 20 || next > map_end || next <= cursor) {
            memory_map_error = 3;
            return false;
        }
        let start: u64 = volatile_load64(cursor + 4);
        let length: u64 = volatile_load64(cursor + 12);
        let kind: int = volatile_load32(cursor + 20);
        let end: u64 = start + length;
        if (end < start || !memory_region_add(start, end, kind)) {
            memory_map_error = 4;
            return false;
        }
        if (kind == 1 && end > usable_memory_end) {
            usable_memory_end = end;
        }
        cursor = next;
    }
    if (cursor != map_end) {
        memory_map_error = 5;
        return false;
    }

    let kernel_start: u64 = kernel_image_start();
    let kernel_end: u64 = kernel_image_end();
    let fixed_start: u64 = 0x400000 as u64;
    let fixed_end: u64 = 0x677000 as u64;
    let heap_start: u64 = 0x1000000 as u64;
    if (kernel_start != (0x200000 as u64)
        || kernel_end >= fixed_start
        || fixed_end >= heap_start
        || !memory_range_is_usable(kernel_start, kernel_end)
        || !memory_range_is_usable(fixed_start, fixed_end)) {
        memory_map_error = 6;
        return false;
    }
    if (!memory_range_is_usable(heap_start, heap_start + 4096)) {
        memory_map_error = 7;
        return false;
    }
    heap_limit = memory_usable_limit(heap_start);
    let identity_map_end: u64 = (0xFFFFFFFF as u64) + 1;
    if (heap_limit > identity_map_end) {
        heap_limit = identity_map_end;
    }
    if (heap_limit <= heap_start) {
        memory_map_error = 8;
        return false;
    }
    heap_ptr = heap_start;
    heap_free = 0 as u64;

    /* kind >= 0x100 is ppos-owned and never treated as firmware-usable RAM. */
    if (!memory_region_add(0x1000 as u64, 0x9000 as u64, 0x100)) { memory_map_error = 9; return false; }
    if (!memory_region_add(0x100000 as u64, kernel_end, 0x101)) { memory_map_error = 10; return false; }
    if (!memory_region_add(info, info + 116, 0x102)) { memory_map_error = 11; return false; }
    if (!memory_region_add(mmap_addr, map_end, 0x102)) { memory_map_error = 12; return false; }
    if (!memory_region_add(fixed_start, fixed_end, 0x103)) { memory_map_error = 13; return false; }

    let stack_start: u64 = bootstrap_stack_start();
    let stack_end: u64 = bootstrap_stack_end();
    if (stack_start < kernel_start || stack_end > kernel_end || stack_end <= stack_start) {
        memory_map_error = 14;
        return false;
    }
    return true;
}

/* 32-byte block header: next:u64, size:u64, magic:u32, state:u32, canary:u64. */
fn heap_write_header(block: u64, next: u64, size: u64, state: int) {
    volatile_store64(block, next);
    volatile_store64(block + 8, size);
    volatile_store32(block + 16, 0x504F5348);
    volatile_store32(block + 20, state);
    volatile_store64(block + 24, block ^ size ^ (0x50504F5348454150 as u64));
}

fn heap_header_valid(block: u64) -> bool {
    if (block < (0x1000000 as u64) || block + 32 > heap_ptr) {
        return false;
    }
    let size: u64 = volatile_load64(block + 8);
    if (volatile_load32(block + 16) != 0x504F5348
        || size < 48
        || (size & (15 as u64)) != (0 as u64)
        || block + size < block
        || block + size > heap_ptr
        || volatile_load64(block + 24) != (block ^ size ^ (0x50504F5348454150 as u64))) {
        return false;
    }
    return true;
}

fn heap_poison(start: u64, size: u64, value: int) {
    let i: u64 = 0 as u64;
    while (i < size) {
        volatile_store8(start + i, value);
        i = i + 1;
    }
}

fn kmalloc(size: int) -> u64 {
    if (size <= 0) {
        return 0 as u64;
    }
    let payload: u64 = size as u64;
    let req: u64 = (payload + 32 + 15) & (~(15 as u64));
    if (req < payload || req < 48) {
        return 0 as u64;
    }
    let prev: u64 = 0 as u64;
    let cur: u64 = heap_free;
    while (cur != 0) {
        if (!heap_header_valid(cur) || volatile_load32(cur + 20) != 2) {
            kernel_panic("allocator free-list corruption");
        }
        let bsize: u64 = volatile_load64(cur + 8);
        if (bsize >= req) {
            let remain: u64 = bsize - req;
            let nxt: u64 = volatile_load64(cur);
            if (remain >= 48) {
                let rem: u64 = cur + req;
                heap_write_header(rem, nxt, remain, 2);
                if (prev != 0) {
                    volatile_store64(prev, rem);
                } else {
                    heap_free = rem;
                }
            } else {
                req = bsize;
                if (prev != 0) {
                    volatile_store64(prev, nxt);
                } else {
                    heap_free = nxt;
                }
            }
            heap_write_header(cur, 0 as u64, req, 1);
            return cur + 32;
        }
        prev = cur;
        cur = volatile_load64(cur);
    }
    let block: u64 = (heap_ptr + 15) & (~(15 as u64));
    let end: u64 = block + req;
    if (end < block || end > heap_limit) {
        return 0 as u64;
    }
    heap_ptr = end;
    heap_write_header(block, 0 as u64, req, 1);
    return block + 32;
}

fn kfree(pointer: u64) -> bool {
    if (pointer == (0 as u64)
        || (pointer & (15 as u64)) != (0 as u64)
        || pointer < (0x1000000 + 32) as u64
        || pointer > heap_ptr) {
        return false;
    }
    let block: u64 = pointer - 32;
    if (!heap_header_valid(block) || volatile_load32(block + 20) != 1) {
        return false;
    }
    let size: u64 = volatile_load64(block + 8);
    heap_poison(pointer, size - 32, 0xDD);

    let prev: u64 = 0 as u64;
    let cur: u64 = heap_free;
    while (cur != 0 && cur < block) {
        if (!heap_header_valid(cur) || volatile_load32(cur + 20) != 2) {
            kernel_panic("allocator free-list corruption");
        }
        prev = cur;
        cur = volatile_load64(cur);
    }
    if ((prev != 0 && prev + volatile_load64(prev + 8) > block)
        || (cur != 0 && block + size > cur)) {
        return false;
    }
    heap_write_header(block, cur, size, 2);
    if (prev == 0) {
        heap_free = block;
    } else {
        volatile_store64(prev, block);
    }

    if (cur != 0 && block + volatile_load64(block + 8) == cur) {
        let merged_size: u64 = volatile_load64(block + 8) + volatile_load64(cur + 8);
        heap_write_header(block, volatile_load64(cur), merged_size, 2);
    }
    if (prev != 0 && prev + volatile_load64(prev + 8) == block) {
        let merged_size: u64 = volatile_load64(prev + 8) + volatile_load64(block + 8);
        heap_write_header(prev, volatile_load64(block), merged_size, 2);
    }
    return true;
}

fn allocator_selftest() -> bool {
    allocator_test_error = 0;
    let initial: u64 = heap_ptr;
    let a: u64 = kmalloc(64);
    let b: u64 = kmalloc(96);
    let c: u64 = kmalloc(64);
    if (a == (0 as u64) || b == (0 as u64) || c == (0 as u64)
        || (a & (15 as u64)) != (0 as u64)
        || (b & (15 as u64)) != (0 as u64)
        || (c & (15 as u64)) != (0 as u64)) {
        allocator_test_error = 1;
        return false;
    }
    if (!kfree(b) || volatile_load8(b) != 0xDD || kfree(b) || kfree(a + 1)) {
        allocator_test_error = 2;
        return false;
    }
    if (!kfree(a) || !kfree(c)) {
        allocator_test_error = 3;
        return false;
    }
    if (heap_free != initial || volatile_load64(heap_free + 8) != heap_ptr - initial) {
        allocator_test_error = 4;
        return false;
    }
    let d: u64 = kmalloc(200);
    if (d != initial + 32 || !kfree(d)) {
        allocator_test_error = 5;
        return false;
    }
    let saved_limit: u64 = heap_limit;
    let saved_free: u64 = heap_free;
    heap_limit = heap_ptr + 64;
    heap_free = 0 as u64;
    let oom: u64 = kmalloc(64);
    heap_limit = saved_limit;
    heap_free = saved_free;
    if (oom != (0 as u64) || kmalloc(0) != (0 as u64)) {
        allocator_test_error = 6;
        return false;
    }
    return true;
}
