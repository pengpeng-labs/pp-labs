enum Value {
    Int(int),
    Text(str),
    Flag(bool),
    None,
}

fn score(value: Value) -> int {
    switch value {
        Value.Int(number) { return number; }
        Value.Text(text) { return len(text) as int; }
        Value.Flag(enabled) {
            if (enabled) { return 1; }
            return 0;
        }
        Value.None { return 0; }
    }
    return 0;
}

fn main() -> int {
    return score(Value.Int(21));
}
