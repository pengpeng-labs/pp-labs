fn main() -> int {
    let message: str = "pplang";
    let middle: str = message[1:5];
    if (112 in message && len(middle) == 4) {
        println(middle);
        return 0;
    }
    return 1;
}
