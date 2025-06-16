/* 极简 freestanding libc 函数（供 BearSSL 链接） */
#include <stddef.h>

void *memcpy(void *dest, const void *src, size_t n)
{
    unsigned char *d = dest;
    const unsigned char *s = src;
    while (n--) {
        *d++ = *s++;
    }
    return dest;
}

void *memmove(void *dest, const void *src, size_t n)
{
    unsigned char *d = dest;
    const unsigned char *s = src;
    if (d < s) {
        while (n--) {
            *d++ = *s++;
        }
    } else {
        d += n;
        s += n;
        while (n--) {
            *--d = *--s;
        }
    }
    return dest;
}

void *memset(void *s, int c, size_t n)
{
    unsigned char *p = s;
    while (n--) {
        *p++ = (unsigned char)c;
    }
    return s;
}

int memcmp(const void *s1, const void *s2, size_t n)
{
    const unsigned char *a = s1;
    const unsigned char *b = s2;
    while (n--) {
        if (*a != *b) {
            return (int)(*a - *b);
        }
        a++;
        b++;
    }
    return 0;
}

size_t strlen(const char *s)
{
    size_t n = 0;
    while (*s++) {
        n++;
    }
    return n;
}
