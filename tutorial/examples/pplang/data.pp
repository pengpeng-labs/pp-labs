struct Point {
    x: int,
    y: int,
}

fn move_by(point: *Point, dx: int, dy: int) {
    point.x = point.x + dx;
    point.y = point.y + dy;
}

fn minmax(a: int, b: int) -> (int, int) {
    if (a < b) { return (a, b); }
    return (b, a);
}

fn main() -> int {
    let point: Point = Point { x: 2, y: 3 };
    point.move_by(4, 5);
    let values: [3]int = [9, 2, 7];
    let (lo, hi) = minmax(values[0], values[1]);
    return point.x + point.y + lo + hi;
}
