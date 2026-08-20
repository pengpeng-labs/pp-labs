enum Option[T] {
    Some(T),
    None,
}

fn larger[T](a: T, b: T, less: fn(T, T) -> bool) -> T {
    if (less(a, b)) { return b; }
    return a;
}

fn int_less(a: int, b: int) -> bool {
    return a < b;
}

fn main() -> int {
    let best: int = larger[int](6, 9, &int_less);
    let value: Option[int] = Option.Some[int](best);
    switch value {
        Option.Some(number) { return number; }
        Option.None { return 0; }
    }
    return 0;
}
