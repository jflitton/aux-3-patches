/* m68k-elf-ld -r script for A/UX boot.d modules: exactly .text, .data and .bss, the
   three sections tools/elf2coff.py turns into an A/UX COFF object. Read-only data goes
   with the code, as A/UX's own modules have no .rodata. */
SECTIONS
{
	.text : { *(.text .text.*) *(.rodata .rodata.*) }
	.data : { *(.data .data.*) }
	.bss : { *(.bss .bss.*) }
	/DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame) }
}
