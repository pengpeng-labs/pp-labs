fn strlen(s: str) -> int {
    let i: int = 0;
    while (s[i] != 0) {
        i = i + 1;
    }
    return i;
}

fn strcmp(a: str, b: str) -> int {
    let i: int = 0;
    while (1) {
        let ca: int = a[i];
        let cb: int = b[i];
        if (ca != cb) {
            return ca - cb;
        }
        if (ca == 0) {
            return 0;
        }
        i = i + 1;
    }
    return 0;
}

fn strcpy(dst: str, src: str) {
    let i: int = 0;
    while (1) {
        dst[i] = src[i];
        if (src[i] == 0) {
            return;
        }
        i = i + 1;
    }
}

fn strcat(dst: str, src: str) {
    let n: int = strlen(dst);
    strcpy(dst + n, src);
}
