extern fn puts(text: str) -> int;

fn main() -> int {
    puts("called through the C ABI");
    return 0;
}
