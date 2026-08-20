import "../stdlib/vec.pp";

fn larger[T](a: T, b: T, less: fn(T, T) -> bool) -> T {
    if (less(a, b)) { return b; }
    return a;
}

fn int_less(a: int, b: int) -> bool {
    return a < b;
}

fn main() -> int {
    let values: Vec[int] = vec_new[int]();
    values.vec_push[int](4);
    values.vec_push[int](9);
    let result: int = larger[int](values.vec_get[int](0), values.vec_get[int](1), &int_less);
    values.vec_free[int]();
    return result;
}
