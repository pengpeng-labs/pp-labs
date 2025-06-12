struct Point {
    x: int,
    y: int,
}

fn dist2(p: Point) -> int {
    return p.x * p.x + p.y * p.y;
}

fn main() -> int {
    let p: Point = Point { x: 3, y: 4 };
    return dist2(p);
}
