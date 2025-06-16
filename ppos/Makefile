# pp-os 构建脚本（两阶段：64 位内核内嵌进 32 位 multiboot v1 ELF）

PP      = ../pplc/target/debug/pp
AS      = x86_64-elf-as
LD      = x86_64-elf-ld
OBJCOPY = x86_64-elf-objcopy
QEMU    = qemu-system-x86_64

all: kernel.elf

# ---- 阶段 1：64 位内核（entry64 固定在 0x200000）----
kernel.o: kernel.pp fs.pp net.pp tls.pp json.pp agent.pp browser.pp app.pp mcp.pp wasm.pp ../ppdb/db_core.pp ../ppdb/host_ppos.pp ../ppdb/host_file_ppos.pp ../ppdb/db_sql_parse.pp ../ppdb/db_sql_exec.pp ../ppdb/db_kv.pp ../ppdb/db_doc.pp ../ppdb/db_persist.pp
	$(PP) os kernel.pp -o kernel.o

boot/boot64.o: boot/boot64.S
	$(AS) boot/boot64.S -o boot/boot64.o

boot/libc.o: boot/libc.c
	x86_64-elf-gcc -ffreestanding -Os -c boot/libc.c -o boot/libc.o

boot/tls_glue.o: boot/tls_glue.c boot/libc.c boot/include/string.h
	x86_64-elf-gcc -ffreestanding -Os -Iboot/bearssl -Iboot/include \
		-c boot/tls_glue.c -o boot/tls_glue.o

# ---- uIP 协议栈（TCP 层替换手写 net.pp 的简化实现）----
UIP_SRCS = boot/uip/uip.c boot/uip/uip_arp.c boot/uip/timer.c
UIP_OBJS = $(UIP_SRCS:.c=.o)
UIP_INC  = -Iboot/uip

boot/uip/%.o: boot/uip/%.c
	x86_64-elf-gcc -ffreestanding -Os $(UIP_INC) -Iboot/include -c $< -o $@

boot/uip_glue.o: boot/uip_glue.c $(UIP_OBJS)
	x86_64-elf-gcc -ffreestanding -Os $(UIP_INC) -Iboot/include -c boot/uip_glue.c -o boot/uip_glue.o

boot/libuip.a: $(UIP_OBJS) boot/uip_glue.o
	x86_64-elf-ar rcs boot/libuip.a $(UIP_OBJS) boot/uip_glue.o

kernel.elf64: boot/boot64.o boot/libc.o boot/tls_glue.o kernel.o boot/libbearssl.a boot/libuip.a boot/kernel64.ld
	$(LD) -T boot/kernel64.ld boot/boot64.o boot/libc.o boot/tls_glue.o kernel.o boot/libbearssl.a boot/libuip.a -o kernel.elf64

kernel.bin: kernel.elf64
	$(OBJCOPY) -O binary kernel.elf64 kernel.bin

# 把 raw binary 包装成 32 位目标文件，section 名为 .kernel（带执行位）
kernel.bin.o: kernel.bin
	$(OBJCOPY) -I binary -O elf32-i386 -B i386 \
		--rename-section .data=.kernel,alloc,load,code,contents \
		kernel.bin kernel.bin.o

# ---- 阶段 2：32 位启动桩 + 内嵌内核 ----
boot/boot32.o: boot/boot32.S
	$(AS) --32 boot/boot32.S -o boot/boot32.o

kernel.elf: boot/boot32.o kernel.bin.o boot/boot32.ld
	$(LD) -m elf_i386 -T boot/boot32.ld boot/boot32.o kernel.bin.o -o kernel.elf

run: kernel.elf
	$(QEMU) -kernel kernel.elf -nographic

clean:
	rm -f kernel.elf kernel.elf64 kernel.bin kernel.bin.o kernel.o boot/boot32.o boot/boot64.o boot/libc.o boot/tls_glue.o
	rm -f boot/uip/*.o boot/uip_glue.o boot/libuip.a

.PHONY: all run clean
