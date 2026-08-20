fn classify(value: int) -> int {
    if (value < 0) { return -1; }
    if (value == 0) { return 0; }
    return 1;
}

fn main() -> int {
    let total: int = 0;
    for value in range(5) {
        total = total + value;
    }
    return total + classify(8);
}
