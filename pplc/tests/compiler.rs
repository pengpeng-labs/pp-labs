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

#[test]
fn sum_type_constructs_and_switches_all_variants() {
    let output = pp(
        "run",
        "sum_type",
        r#"
enum Value { Int(int), Text(str), Flag(bool), None }

fn score(value: Value) -> int {
    let result: int = 0;
    switch value {
        Value.Int(number) { result = number; }
        Value.Text(text) { result = len(text) as int; }
        Value.Flag(flag) { if (flag) { result = 10; } }
        Value.None { result = 1; }
    }
    return result;
}

fn main() -> int {
    return score(Value.Int(7))
        + score(Value.Text("abc"))
        + score(Value.Flag(true))
        + score(Value.None());
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "21\n");
}

#[test]
fn sum_type_wildcard_is_a_fallback() {
    let output = pp(
        "run",
        "sum_type_wildcard",
        r#"
enum Result { Ok(int), Error(str) }

fn unwrap_or(result: Result) -> int {
    switch result {
        Result.Ok(value) { return value; }
        _ { return -1; }
    }
    return 0;
}

fn main() -> int { return unwrap_or(Result.Error("no")); }
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "-1\n");
}

#[test]
fn sum_type_switch_must_be_exhaustive() {
    let output = pp(
        "ir",
        "sum_type_exhaustive",
        r#"
enum Value { Int(int), Text(str), None }
fn score(value: Value) -> int {
    switch value {
        Value.Int(number) { return number; }
        Value.None { return 0; }
    }
    return 0;
}
fn main() -> int { return 0; }
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("non-exhaustive switch: missing Value.Text"));
}

#[test]
fn sum_type_payload_type_is_checked() {
    let output = pp(
        "ir",
        "sum_type_payload",
        r#"
enum Value { Int(int) }
fn main() -> int { let value: Value = Value.Int("wrong"); return 0; }
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("payload type mismatch for 'Value.Int'"));
}

#[test]
fn sum_type_rejects_duplicate_switch_arms() {
    let output = pp(
        "ir",
        "sum_type_duplicate",
        r#"
enum Value { Int(int), None }
fn score(value: Value) -> int {
    switch value {
        Value.Int(first) { return first; }
        Value.Int(second) { return second; }
        Value.None { return 0; }
    }
    return 0;
}
fn main() -> int { return 0; }
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("duplicate switch arm 'Value.Int'"));
}

#[test]
fn sum_type_payload_pattern_requires_one_binding() {
    let output = pp(
        "ir",
        "sum_type_binding",
        r#"
enum Value { Int(int), None }
fn score(value: Value) -> int {
    switch value {
        Value.Int { return 1; }
        Value.None { return 0; }
    }
    return 0;
}
fn main() -> int { return 0; }
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("variant 'Value.Int' requires a payload binding"));
}

#[test]
fn sum_type_unit_pattern_rejects_a_binding() {
    let output = pp(
        "ir",
        "sum_type_unit_binding",
        r#"
enum Value { Int(int), None }
fn score(value: Value) -> int {
    switch value {
        Value.Int(number) { return number; }
        Value.None(unused) { return 0; }
    }
    return 0;
}
fn main() -> int { return 0; }
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("variant 'Value.None' has no payload"));
}

#[test]
fn sum_type_wildcard_must_be_last() {
    let output = pp(
        "ir",
        "sum_type_wildcard_order",
        r#"
enum Value { Int(int), None }
fn score(value: Value) -> int {
    switch value {
        _ { return 0; }
        Value.Int(number) { return number; }
    }
    return 0;
}
fn main() -> int { return 0; }
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("wildcard switch arm must be last"));
}

#[test]
fn sum_type_can_carry_another_sum_type() {
    let output = pp(
        "run",
        "nested_sum_type",
        r#"
enum Inner { Number(int), Empty }
enum Outer { Wrapped(Inner), Missing }

fn inner_score(value: Inner) -> int {
    switch value {
        Inner.Number(number) { return number; }
        Inner.Empty { return 0; }
    }
    return 0;
}

fn outer_score(value: Outer) -> int {
    switch value {
        Outer.Wrapped(inner) { return inner_score(inner); }
        Outer.Missing { return -1; }
    }
    return 0;
}

fn main() -> int { return outer_score(Outer.Wrapped(Inner.Number(9))); }
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "9\n");
}

#[test]
fn explicit_generic_function_is_monomorphized() {
    let output = pp(
        "run",
        "generic_identity",
        r#"
fn identity[T](value: T) -> T { return value; }

fn main() -> int {
    let number: int = identity[int](7);
    let text: str = identity[str]("abcd");
    return number + len(text) as int;
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "11\n");
}

#[test]
fn generic_capability_is_an_explicit_function_parameter() {
    let output = pp(
        "run",
        "generic_capability",
        r#"
fn choose_max[T](a: T, b: T, less: fn(T, T) -> bool) -> T {
    if (less(a, b)) { return b; }
    return a;
}

fn int_less(a: int, b: int) -> bool { return a < b; }

fn main() -> int {
    return choose_max[int](3, 9, &int_less);
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "9\n");
}

#[test]
fn generic_structs_are_distinct_concrete_types() {
    let output = pp(
        "run",
        "generic_struct",
        r#"
struct Pair[T] { first: T, second: T }

fn sum_pair(pair: Pair[int]) -> int {
    return pair.first + pair.second;
}

fn main() -> int {
    let pair: Pair[int] = Pair[int] { first: 8, second: 5 };
    return sum_pair(pair);
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "13\n");
}

#[test]
fn generic_sum_types_support_nested_instances() {
    let output = pp(
        "run",
        "generic_sum_type",
        r#"
struct Pair[T] { first: T, second: T }
enum Option[T] { Some(T), None }

fn unwrap_pair(value: Option[Pair[int]]) -> int {
    switch value {
        Option.Some(pair) { return pair.first + pair.second; }
        Option.None { return -1; }
    }
    return 0;
}

fn main() -> int {
    let pair: Pair[int] = Pair[int] { first: 4, second: 6 };
    return unwrap_pair(Option.Some[Pair[int]](pair));
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "10\n");
}

#[test]
fn generic_calls_require_explicit_type_arguments() {
    let output = pp(
        "ir",
        "generic_explicit",
        r#"
fn identity[T](value: T) -> T { return value; }
fn main() -> int { return identity(1); }
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("requires explicit type arguments"));
}

#[test]
fn generic_size_and_alignment_are_compile_time_values() {
    let output = pp(
        "run",
        "generic_size",
        r#"
struct Pair[T] { first: T, second: T }

fn size_of_pair[T]() -> u64 {
    return sizeof[Pair[T]]();
}

fn main() -> int {
    return size_of_pair[u32]() as int + alignof[u64]() as int;
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "16\n");
}

#[test]
fn generic_operators_require_an_explicit_capability() {
    let output = pp(
        "ir",
        "generic_operator",
        r#"
fn invalid_add[T](a: T, b: T) -> T { return a + b; }
fn main() -> int { return invalid_add[int](1, 2); }
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("pass a function capability"));
}

#[test]
fn generic_recursive_expansion_is_rejected() {
    let output = pp(
        "ir",
        "generic_recursion",
        r#"
enum Option[T] { Some(T), None }

fn grow[T](value: T) -> int {
    return grow[Option[T]](Option.Some[T](value));
}

fn main() -> int { return grow[int](1); }
"#,
    );
    assert!(!output.status.success());
    assert!(stderr(&output).contains("recursively expands to a different instance"));
}

#[test]
fn generic_pointer_receiver_method_uses_an_explicit_type_argument() {
    let output = pp(
        "run",
        "generic_method",
        r#"
struct Box[T] { value: T }

fn box_get[T](box: *Box[T]) -> T { return box.value; }

fn main() -> int {
    let box: Box[int] = Box[int] { value: 17 };
    return box.box_get[int]();
}
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "17\n");
}

#[test]
fn generic_instances_are_deduplicated() {
    let output = pp(
        "ir",
        "generic_dedup",
        r#"
fn identity[T](value: T) -> T { return value; }
fn main() -> int { return identity[int](1) + identity[int](2); }
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(
        stdout(&output)
            .matches("define i32 @__ppg_8_identity_int")
            .count(),
        1
    );
}

#[test]
fn generic_vector_grows_for_multiple_element_types() {
    let output = pp(
        "run",
        "generic_vec",
        &format!(
            r#"
import "{root}/stdlib/vec.pp";

fn main() -> int {{
    let numbers: Vec[int] = vec_new[int]();
    let index: int = 0;
    while (index < 6) {{
        numbers.vec_push[int](index * 3);
        index = index + 1;
    }}
    let bytes: Vec[u8] = vec_new[u8]();
    bytes.vec_push[u8](7);
    let result: int = numbers.vec_get[int](5) + bytes.vec_get[u8](0) as int;
    numbers.vec_free[int]();
    bytes.vec_free[u8]();
    return result;
}}
"#,
            root = env!("CARGO_MANIFEST_DIR").replace("/pplc", "")
        ),
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "22\n");
}

#[test]
fn generic_templates_compose_without_losing_constraints() {
    let output = pp(
        "run",
        "generic_composition",
        r#"
fn compare[T](a: T, b: T, less: fn(T, T) -> bool) -> bool {
    return less(a, b);
}

fn choose[T](a: T, b: T, less: fn(T, T) -> bool) -> T {
    if (compare[T](a, b, less)) { return b; }
    return a;
}

fn int_less(a: int, b: int) -> bool { return a < b; }
fn main() -> int { return choose[int](2, 8, &int_less); }
"#,
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "8\n");

    let invalid = pp(
        "ir",
        "generic_composition_invalid",
        r#"
fn identity[T](value: T) -> T { return value; }
fn invalid[T](value: T) -> T { return identity[T](value) + identity[T](value); }
fn main() -> int { return invalid[int](1); }
"#,
    );
    assert!(!invalid.status.success());
    assert!(stderr(&invalid).contains("pass a function capability"));
}
