/* 极简 freestanding stdlib.h（满足 mm_malloc.h 等编译需求） */
#ifndef PP_STDLIB_H
#define PP_STDLIB_H

#include <stddef.h>

void *malloc(size_t n);
void free(void *p);

#endif
