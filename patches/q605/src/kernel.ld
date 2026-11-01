/* Link the Cuda transport (modules/cuda/cuda.c) and the MEMCjr module's MMU-off hooks
   (src/q605.S with modules/memcjr) over cEgretDispatch and the Egret helpers they replace,
   all dead once the stubs are in, and the MMU-on hooks and the hooks' data over
   egret_reset's body after its jmp stub. A checkpoint build's .text.ckpt goes over
   orwellsize in pstart (only Orwell machines call it).
   cuda_dispatch must come first: it takes cEgretDispatch's address. */
SECTIONS
{
	/* first, so that .text's wildcard does not take them */
	.text2 egret_reset + 6 : { *(.text.boot605.extra) }
	.text3 orwellsize : { *(.text.ckpt) }
	.text cEgretDispatch : {
		*(.text.cuda_dispatch)
		*(.text .text.*)
		*(.rodata .rodata.*)
	}
	.data : { *(.data .data.*) *(.bss .bss.* COMMON) }
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
ASSERT(SIZEOF(.data) == 0, "cuda.c must not use static data")
ASSERT(SIZEOF(.text) <= shift_reg_intr - cEgretDispatch, "patch code overruns shift_reg_intr")
ASSERT(SIZEOF(.text2) <= init_egret_onesec - egret_reset - 6, ".text2 overruns egret_reset")
ASSERT(SIZEOF(.text3) <= memcdjsize - orwellsize, ".text3 overruns orwellsize")
