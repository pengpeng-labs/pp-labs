// Generic growable vector. Ownership stays explicit: vec_new allocates, vec_free releases.
import "alloc.pp";

struct Vec[T] {
    data: *T,
    len: int,
    cap: int,
}

fn vec_new[T]() -> Vec[T] {
    let capacity: int = 4;
    return Vec[T] {
        data: alloc(capacity * sizeof[T]() as int) as *T,
        len: 0,
        cap: capacity
    };
}

fn vec_push[T](vec: *Vec[T], value: T) {
    if (vec.len == vec.cap) {
        let next_cap: int = vec.cap * 2;
        let next: *T = alloc(next_cap * sizeof[T]() as int) as *T;
        let index: int = 0;
        while (index < vec.len) {
            next[index] = vec.data[index];
            index = index + 1;
        }
        dealloc(vec.data as *u8);
        vec.data = next;
        vec.cap = next_cap;
    }
    vec.data[vec.len] = value;
    vec.len = vec.len + 1;
}

fn vec_get[T](vec: *Vec[T], index: int) -> T {
    return vec.data[index];
}

fn vec_free[T](vec: *Vec[T]) {
    dealloc(vec.data as *u8);
    vec.data = 0 as *T;
    vec.len = 0;
    vec.cap = 0;
}
