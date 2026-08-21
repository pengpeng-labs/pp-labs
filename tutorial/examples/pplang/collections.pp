import "../../../stdlib/buf.pp";
import "../../../stdlib/strmap.pp";

fn main() -> int {
    let out: Buf = buf_new(4);
    defer out.buf_free();
    if (!out.buf_append("pp")) { return -1; }
    if (!out.buf_push(33 as u8)) { return -2; }

    let config: StrMap = map_new(4);
    defer config.map_free();
    if (!config.map_set("name", out.buf_view())) { return -3; }

    let (found, value) = config.map_get("name");
    if (!found) { return -4; }
    return len(value) as int;
}
