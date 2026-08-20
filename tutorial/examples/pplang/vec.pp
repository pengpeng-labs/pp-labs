import "../../../stdlib/vec.pp";

fn main() -> int {
    let values: Vec[int] = vec_new[int]();
    defer values.vec_free[int]();
    values.vec_push[int](4);
    values.vec_push[int](8);
    return values.vec_get[int](0) + values.vec_get[int](1);
}
