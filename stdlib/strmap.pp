/* 拥有键和值副本的开放寻址 str -> str 哈希表。 */

import "alloc.pp";

struct MapSlot {
    key: str,
    value: str,
    state: u8, /* 0=empty, 1=used, 2=tombstone */
}

struct StrMap {
    slots: *MapSlot,
    len: int,
    cap: int,
}

fn map_hash(key: str) -> u64 {
    let hash: u64 = 2166136261 as u64;
    let i: int = 0;
    let n: int = len(key) as int;
    while (i < n) {
        hash = hash ^ (key[i] as u64);
        hash = hash * (16777619 as u64);
        i = i + 1;
    }
    return hash;
}

fn map_key_eq(left: str, right: str) -> bool {
    if (len(left) != len(right)) {
        return false;
    }
    let i: int = 0;
    let n: int = len(left) as int;
    while (i < n) {
        if (left[i] != right[i]) {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn map_copy(value: str) -> str {
    let n: int = len(value) as int;
    let size: int = n;
    if (size == 0) {
        size = 1;
    }
    let data: *u8 = alloc(size);
    let i: int = 0;
    while (i < n) {
        data[i] = value[i];
        i = i + 1;
    }
    return str_from_ptr(data, n);
}

fn map_init_slots(slots: *MapSlot, cap: int) {
    let i: int = 0;
    while (i < cap) {
        slots[i].state = 0;
        i = i + 1;
    }
}

fn map_new(initial_cap: int) -> StrMap {
    if (initial_cap < 8) {
        initial_cap = 8;
    }
    /* MapSlot 当前最大布局小于 48B；保守留对齐余量。 */
    let raw: *u8 = alloc(initial_cap * 48);
    if (raw == 0) {
        return StrMap { slots: raw as *MapSlot, len: 0, cap: 0 };
    }
    let slots: *MapSlot = raw as *MapSlot;
    map_init_slots(slots, initial_cap);
    return StrMap { slots: slots, len: 0, cap: initial_cap };
}

/* 返回 (found, slot)。未找到时 slot 是首个可插入位置。 */
fn map_find(map: *StrMap, key: str) -> (bool, int) {
    if (map.slots == 0 || map.cap == 0) {
        return (false, -1);
    }
    let index: int = (map_hash(key) % (map.cap as u64)) as int;
    let tombstone: int = -1;
    let probes: int = 0;
    while (probes < map.cap) {
        let state: u8 = map.slots[index].state;
        if (state == 0) {
            if (tombstone >= 0) {
                return (false, tombstone);
            }
            return (false, index);
        }
        if (state == 2 && tombstone < 0) {
            tombstone = index;
        } else if (state == 1 && map_key_eq(map.slots[index].key, key)) {
            return (true, index);
        }
        index = (index + 1) % map.cap;
        probes = probes + 1;
    }
    return (false, tombstone);
}

fn map_place_owned(map: *StrMap, key: str, value: str) -> bool {
    let (found, index) = map_find(map, key);
    if (index < 0) {
        return false;
    }
    if (found) {
        dealloc(str_ptr(map.slots[index].value));
    } else {
        map.slots[index].key = key;
        map.slots[index].state = 1;
        map.len = map.len + 1;
    }
    map.slots[index].value = value;
    return true;
}

fn map_grow(map: *StrMap) -> bool {
    let old_slots: *MapSlot = map.slots;
    let old_cap: int = map.cap;
    let next_cap: int = old_cap * 2;
    let raw: *u8 = alloc(next_cap * 48);
    if (raw == 0) {
        return false;
    }
    map.slots = raw as *MapSlot;
    map.cap = next_cap;
    map.len = 0;
    map_init_slots(map.slots, map.cap);
    let i: int = 0;
    while (i < old_cap) {
        if (old_slots[i].state == 1) {
            map_place_owned(map, old_slots[i].key, old_slots[i].value);
        }
        i = i + 1;
    }
    dealloc(old_slots as *u8);
    return true;
}

fn map_set(map: *StrMap, key: str, value: str) -> bool {
    if (map.slots == 0 || map.cap == 0) {
        return false;
    }
    if ((map.len + 1) * 10 >= map.cap * 7) {
        if (map_grow(map) == false) {
            return false;
        }
    }
    let (found, index) = map_find(map, key);
    if (index < 0) {
        return false;
    }
    let value_copy: str = map_copy(value);
    if (str_ptr(value_copy) == 0) {
        return false;
    }
    if (found) {
        dealloc(str_ptr(map.slots[index].value));
        map.slots[index].value = value_copy;
        return true;
    }
    let key_copy: str = map_copy(key);
    if (str_ptr(key_copy) == 0) {
        dealloc(str_ptr(value_copy));
        return false;
    }
    map.slots[index].key = key_copy;
    map.slots[index].value = value_copy;
    map.slots[index].state = 1;
    map.len = map.len + 1;
    return true;
}

fn map_get(map: *StrMap, key: str) -> (bool, str) {
    let (found, index) = map_find(map, key);
    if (found == false) {
        return (false, "");
    }
    return (true, map.slots[index].value);
}

fn map_has(map: *StrMap, key: str) -> bool {
    let (found, index) = map_find(map, key);
    return found;
}

fn map_del(map: *StrMap, key: str) -> bool {
    let (found, index) = map_find(map, key);
    if (found == false) {
        return false;
    }
    dealloc(str_ptr(map.slots[index].key));
    dealloc(str_ptr(map.slots[index].value));
    map.slots[index].state = 2;
    map.len = map.len - 1;
    return true;
}

fn map_free(map: *StrMap) {
    let i: int = 0;
    while (i < map.cap) {
        if (map.slots[i].state == 1) {
            dealloc(str_ptr(map.slots[i].key));
            dealloc(str_ptr(map.slots[i].value));
        }
        i = i + 1;
    }
    if (map.slots != 0) {
        dealloc(map.slots as *u8);
    }
    map.slots = 0 as *MapSlot;
    map.len = 0;
    map.cap = 0;
}
