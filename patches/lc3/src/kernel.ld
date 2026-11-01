/* Link the Sonora module's hooks (src/lc3.S with modules/sonora) over orwellsize and
   memcdjsize, the RAM sizing of the Orwell and djMEMC Quadras, up to _DAFBMonitorDetect
   (which boardinit's Quadra cases call). Both are in pstart, so the code runs where it is
   linked with the MMU off or on. */
SECTIONS
{
	.text orwellsize : {
		*(.text.sonora)
		*(.text .text.*)
		*(.rodata .rodata.*)
	}
	.data : { *(.data .data.*) *(.bss .bss.* COMMON) }
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
ASSERT(SIZEOF(.data) == 0, "the hooks must not use static data")
ASSERT(memcdjsize > orwellsize, "memcdjsize no longer follows orwellsize")
ASSERT(SIZEOF(.text) <= _DAFBMonitorDetect - orwellsize, "patch code overruns _DAFBMonitorDetect")
