enum Result {
    Ok(int),
    Error(str),
}

fn divide(a: int, b: int) -> Result {
    if (b == 0) { return Result.Error("division by zero"); }
    return Result.Ok(a / b);
}

fn main() -> int {
    let result: Result = divide(84, 2);
    switch result {
        Result.Ok(value) { return value; }
        Result.Error(message) {
            println(message);
            return 1;
        }
    }
    return 1;
}
