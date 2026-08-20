use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT_FILE: AtomicUsize = AtomicUsize::new(0);

fn source_file(name: &str, source: &str) -> PathBuf {
    let id = NEXT_FILE.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "pp_compiler_test_{}_{}_{}.pp",
        std::process::id(),
        name,
        id
    ));
    fs::write(&path, source).expect("write test source");
    path
}

fn pp(command: &str, name: &str, source: &str) -> Output {
    let path = source_file(name, source);
    let output = Command::new(env!("CARGO_BIN_EXE_pp"))
        .arg(command)
        .arg(&path)
        .output()
        .expect("run pp compiler");
    let _ = fs::remove_file(path);
    output
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

#[test]
fn runs_a_small_program() {
    let output = pp(
        "run",
        "run",
        "fn main() -> int { let x: int = 40; return x + 2; }",
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "42\n");
}

#[test]
fn unsigned_operations_use_unsigned_llvm_instructions() {
    let output = pp(
        "ir",
        "unsigned",
        r#"
fn div_u64(a: u64, b: u64) -> u64 { return a / b; }
fn rem_u32(a: u32, b: u32) -> u32 { return a % b; }
fn less_u16(a: u16, b: u16) -> bool { return a < b; }
fn main() -> int { return 0; }
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    let ir = stdout(&output);
    assert!(ir.contains("udiv i64"), "{ir}");
    assert!(ir.contains("urem i32"), "{ir}");
    assert!(ir.contains("icmp ult i16"), "{ir}");
}

#[test]
fn conditions_require_bool() {
    let output = pp(
        "ir",
        "bool_condition",
        "fn main() -> int { if (1) { return 1; } return 0; }",
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("condition must be bool"));
}

#[test]
fn block_shadowing_restores_the_outer_binding() {
    let output = pp(
        "run",
        "scope",
        r#"
fn main() -> int {
    let x: int = 7;
    if (true) {
        let x: int = 9;
        println(x);
    }
    return x;
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "9\n7\n");
}

#[test]
fn block_local_is_not_visible_after_the_block() {
    let output = pp(
        "ir",
        "scope_escape",
        r#"
fn main() -> int {
    if (true) { let hidden: int = 1; }
    return hidden;
}
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("unknown variable 'hidden'"));
}

#[test]
fn legacy_array_type_syntax_is_rejected() {
    let output = pp(
        "ir",
        "legacy_array",
        "fn main() -> int { let a: [u8; 4]; return 0; }",
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("legacy array type syntax"));
}

#[test]
fn string_helpers_use_slice_length() {
    let string_lib = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("stdlib/string.pp");
    let output = pp(
        "run",
        "string_len",
        &format!(
            "import {:?}; fn main() -> int {{ return strlen(\"abc\"[0:2]); }}",
            string_lib
        ),
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "2\n");
}

#[test]
fn allocator_returns_a_raw_pointer() {
    let alloc_lib = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("stdlib/alloc.pp");
    let output = pp(
        "run",
        "allocator",
        &format!(
            r#"import {:?};
fn main() -> int {{
    let p: *u8 = alloc(4);
    if (p == 0) {{ return 1; }}
    p[0] = 42;
    let value: int = p[0];
    dealloc(p);
    return value;
}}"#,
            alloc_lib
        ),
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "42\n");
}

#[test]
fn extern_cannot_return_a_lengthless_string() {
    let output = pp(
        "ir",
        "extern_str",
        "extern fn getenv(name: str) -> str; fn main() -> int { return 0; }",
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("cannot return str without a length"));
}

#[test]
fn slice_bounds_are_checked() {
    let output = pp(
        "run",
        "slice_bounds",
        "fn main() -> int { let s: str = \"abc\"; let bad: str = s[1:4]; return 0; }",
    );
    assert!(
        !output.status.success(),
        "out-of-bounds slice unexpectedly ran"
    );
}

#[test]
fn method_call_auto_borrows_an_addressable_struct() {
    let output = pp(
        "run",
        "pointer_receiver",
        r#"
struct Counter { value: int }

fn counter_add(counter: *Counter, amount: int) {
    counter.value = counter.value + amount;
}

fn main() -> int {
    let counter: Counter = Counter { value: 7 };
    counter.counter_add(5);
    return counter.value;
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "12\n");
}

#[test]
fn tuple_return_and_destructuring_work() {
    let output = pp(
        "run",
        "tuple",
        r#"
fn divmod(a: int, b: int) -> (int, int) {
    return (a / b, a % b);
}

fn main() -> int {
    let (quotient, remainder) = divmod(17, 5);
    return quotient * 10 + remainder;
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "32\n");
}

#[test]
fn byte_buffer_grows_and_exposes_a_slice() {
    let buf_lib = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("stdlib/buf.pp");
    let output = pp(
        "run",
        "buf",
        &format!(
            r#"import {:?};
fn main() -> int {{
    let buf: Buf = buf_new(1);
    buf.buf_append("hello");
    buf.buf_push(33);
    let view: str = buf.buf_view();
    let result: int = (len(view) as int) * 10 + view[5] - 33;
    buf.buf_free();
    return result;
}}"#,
            buf_lib
        ),
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "60\n");
}

#[test]
fn strmap_handles_empty_values_updates_deletes_and_growth() {
    let map_lib = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("stdlib/strmap.pp");
    let output = pp(
        "run",
        "strmap",
        &format!(
            r#"import {:?};
fn main() -> int {{
    let map: StrMap = map_new(2);
    map.map_set("empty", "");
    map.map_set("a", "one");
    map.map_set("b", "two");
    map.map_set("c", "three");
    map.map_set("a", "updated");
    let (found_empty, empty) = map.map_get("empty");
    let (found_a, value_a) = map.map_get("a");
    let removed: bool = map.map_del("b");
    let still_b: bool = map.map_has("b");
    let result: int = 0;
    if (found_empty && len(empty) == 0 && found_a && len(value_a) == 7 && removed && still_b == false) {{
        result = map.len;
    }}
    map.map_free();
    return result;
}}"#,
            map_lib
        ),
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "3\n");
}
