struct Packet {
    kind: u8,
    payload: str,
}

enum PacketResult {
    Ok(Packet),
    Error(str),
}

fn parse_packet(input: str) -> PacketResult {
    let n: int = len(input) as int;
    if (n < 2) {
        return PacketResult.Error("header too short");
    }
    let declared: int = input[1] as int - 48;
    if (declared < 0 || declared > 9) {
        return PacketResult.Error("invalid length");
    }
    if (n - 2 != declared) {
        return PacketResult.Error("length mismatch");
    }
    let packet: Packet = Packet {
        kind: input[0],
        payload: input[2:n]
    };
    return PacketResult.Ok(packet);
}

fn packet_score(result: PacketResult) -> int {
    switch result {
        PacketResult.Ok(packet) {
            return packet.kind as int + len(packet.payload) as int;
        }
        PacketResult.Error(message) {
            println(message);
            return -1;
        }
    }
    return -1;
}

fn main() -> int {
    let valid: int = packet_score(parse_packet("A3ppp"));
    let invalid: int = packet_score(parse_packet("B4pp"));
    if (invalid != -1) { return 1; }
    return valid;
}
