/*
 * Kernel hooks that more than one board module uses, as assembler macros: a board module
 * (modules/memcjr, modules/sonora) puts each where its group's linker script wants it.
 * Nothing here emits code until a macro is used.
 *
 * Every hook first asks ourmac, the board module's test for the Macs its group's kernel is
 * for (1 or 0 in d0, condition codes set, nothing else changed), and leaves every other Mac
 * to A/UX's own code.
 */

/*
 * Checkpoint build (CKPT_BUILD, a group's build.sh with CKPT=1): holding a key through A/UX
 * Startup's "Launching" makes the kernel restart the machine (startup chime) when it
 * reaches that key's checkpoint, so a hang can be located without a console. Keys 1-9, 0
 * are checkpoints 1-10; Q W E R T Y U I O P are 11-20. Each board module numbers its own.
 */
	.macro	CKPT n
#ifdef CKPT_BUILD
	move.w	#\n,-(%sp)
	jsr	ckpt
#endif
	.endm

/*
 * In place of aEgretDispatch's "jsr cEgretDispatch". aEgretDispatch is A/UX's handler for
 * the ROM's _EgretDispatch trap and passes back cEgretDispatch's C result (1 = done) in
 * d0. Mac OS returns pbResult (0 = noErr), and the ROM's XPRAM routine (the Quadra 605's
 * ROM+$B37EC, the LC III's ROM+$B37D6) hands that d0 on as _ReadXPRam's and _WriteXPRam's
 * result. So in the kernel every slot PRAM read "failed": on the 605, the DAFB driver's
 * Open gave up before reading its PRAM flags, and its mode sets then left out the MEMCjr
 * pipeline correction to HAL/HFP (picture shifted left, more at lower depths; Thousands
 * broken). On our Macs, return pbResult, with the condition codes set from it; elsewhere,
 * as before. A/UX's own callers of ReadXPRam and WriteXPRam ignore d0.
 */
	.macro	EGRET_RESULT name
	.globl	\name
\name:
	jbsr	ourmac
	jbeq	1f
	move.l	4(%sp),-(%sp)		/* the parameter block aEgretDispatch pushed */
	jsr	cEgretDispatch
	addq.l	#4,%sp
	movea.l	4(%sp),%a0
	move.w	14(%a0),%d0		/* pbResult */
	ext.l	%d0
	rts
1:	jmp	cEgretDispatch
	.endm

/*
 * In place of vadrspace's "jsr setup_autovectors", MMU on, with checkpoint ck if given.
 * Our Macs interrupt at levels 1 (VIA1), 2 (VIA2 or Sonora's pseudo-VIA) and 4 (SCC). Past
 * the Quadra 700, A/UX leaves levels 3 and 5 on faulthdlr (an "unexpected kernel trap"
 * panic) and 6 on powerintr (SIGPWR to init). A 33MHz 605 took a stray level 3 (trap type
 * 27) at IPL 2 in the SCSI interrupt, root already mounted: most likely the IPL lines
 * reading 3 for a moment between levels 1 and 2. Point 3, 5 and 6 at nointr (rte), as
 * setup_autovectors itself does for the Quadra 700 and older.
 */
	.macro	NOINTR_VECTORS name, ck
	.globl	\name
\name:
	.ifnb	\ck
	CKPT	\ck
	.endif
	jbsr	ourmac
	jbeq	1f
	move.l	#nointr,%d0
	move.l	%d0,autovec+8		/* level 3 */
	move.l	%d0,autovec+16		/* level 5 */
	move.l	%d0,autovec+20		/* level 6 */
1:	jmp	setup_autovectors
	.endm

/*
 * In place of memsize's "jsr banksize" for one bank (with "moveq #0,d0; move.l d0,-(sp)"
 * before it shortened to "clr.l -(sp)"), MMU off; checkpoint ck once RAM is sized. Other
 * machines go to banksize itself.
 *
 * banksize(start, from, bank) probes RAM a page at a time upward from `from' with no
 * limit, until a page fails its pattern or alias checks. A bus error on the way (real
 * MEMCjr past the last SIMM?) goes to _start's memerror%, which abandons memsize with the
 * bank unrecorded. This is banksize's algorithm with a bus error catch around each probe
 * (as pdsprobe does for PDS cards) and a limit from Mac OS's low memory, which launch
 * copies to kstart: the larger of BufPtr ($10C) and PhysMemTop ($1EF8), rounded up to 1MB.
 * In 24-bit mode (32-bit addressing off, as System 7.1 starts on the LC III) Mac OS uses
 * only the first 8MB and BufPtr is below that, while PhysMemTop is the end of physical RAM
 * either way (MAME, 32MB: BufPtr $7E9428, PhysMemTop $2000000); with BufPtr alone A/UX got
 * 8MB of a real LC III's 36. Same results as banksize: bank = {start, from, end, 1},
 * numbanks++, probed pages zeroed, lowmem 0 restored.
 */
	.macro	BANKSIZE name, ck
	.globl	\name
\name:
	jbsr	ourmac
	jbne	1f
	jmp	banksize
1:	movem.l	%d2-%d7/%a2-%a4,-(%sp)
	move.l	9*4+12(%sp),%a2		/* bank */
	move.l	9*4+8(%sp),%d2		/* from */
	add.l	#0xfff,%d2
	and.l	#-0x1000,%d2
	move.l	9*4+4(%sp),(%a2)	/* bank->start */
	move.l	%d2,4(%a2)
	move.l	%d2,8(%a2)		/* bank->end: next page to probe */
	move.l	kstart,%a0
	move.l	0x10c(%a0),%d7		/* Mac OS BufPtr */
	cmp.l	0x1ef8(%a0),%d7
	jbcc	8f
	move.l	0x1ef8(%a0),%d7		/* PhysMemTop, if higher */
8:	add.l	#0xfffff,%d7
	and.l	#-0x100000,%d7		/* limit */
	cmp.l	%d2,%d7
	jbhi	7f
	move.l	#0x40000000,%d7		/* implausible: RAM space ends at the ROM */
7:
	moveq	#1,%d3			/* d3 = first power of two >= from */
2:	cmp.l	%d2,%d3
	jbcc	3f
	add.l	%d3,%d3
	jbra	2b
3:	move.l	%d3,%a4
	move.l	%a4,%d0
	lsr.l	#1,%d0
	move.l	%d0,%a4			/* alias sentinel at d3/2 */
	move.l	(%a4),%d5
	move.l	0,%d4			/* lowmem 0, to catch wrap-around */
	movec	%vbr,%a1
	move.l	8(%a1),%d6		/* bus error vector */
	lea	ram_berr(%pc),%a0
	move.l	%a0,8(%a1)
	move.l	%sp,%a3			/* for ram_berr */
4:	move.l	8(%a2),%a0
	cmp.l	%d7,%a0
	jbcc	ram_end
	move.w	#0x5aa5,(%a0)
	move.w	#0xa55a,2(%a0)
	cmp.l	0,%d4
	jbne	ram_end
	cmp.w	#0x5aa5,(%a0)
	jbne	ram_end
	cmp.w	#0xa55a,2(%a0)
	jbne	ram_end
	cmp.l	(%a4),%d5
	jbeq	5f
	move.l	%d5,(%a4)
	jbra	ram_end
5:	move.l	#0x1000,-(%sp)
	move.l	%a0,-(%sp)
	jsr	bzero
	addq.l	#8,%sp
	add.l	#0x1000,8(%a2)
	cmp.l	8(%a2),%d3
	jbcc	4b
	move.l	%d3,%a4			/* crossed d3: watch it for aliases now */
	move.l	(%a4),%d5
	add.l	%d3,%d3
	jbra	4b

ram_berr:				/* bus error while probing: end of RAM */
	move.l	%a3,%sp
ram_end:
	movec	%vbr,%a1
	move.l	%d6,8(%a1)
	move.l	%d4,0
	move.l	8(%a2),%d0
	cmp.l	4(%a2),%d0
	jbls	6f
	moveq	#1,%d0
	move.l	%d0,12(%a2)
	addq.l	#1,numbanks
6:	CKPT	\ck			/* RAM sized */
	movem.l	(%sp)+,%d2-%d7/%a2-%a4
	rts
	.endm

/*
 * The checkpoint code (checkpoint builds only), where it runs the same with the MMU off or
 * on (pstart, identity-mapped). The board module supplies ckpt_restart, entered with the
 * checkpoint in d0, which restarts the machine.
 *
 * ckpt: CKPT n is "move.w #n,-(sp); jsr ckpt". Restarts if n is the held key's checkpoint;
 * otherwise returns with n popped and all registers but the condition codes kept.
 * ckpt_capture: called first thing in the board module's boardinit hook, MMU off: records
 * which checkpoint key Mac OS saw held (its KeyMap, as launch left it at kstart+$174) in
 * ckpt_key, 0 for none.
 */
	.macro	CKPT_CODE
ckpt:
	move.l	%d0,-(%sp)
	move.b	ckpt_key(%pc),%d0
	cmp.b	9(%sp),%d0
	jbeq	ckpt_restart
	move.l	(%sp)+,%d0
	rtd	#2

	.globl	ckpt_capture
ckpt_capture:
	move.l	%d2,-(%sp)
	move.l	kstart,%a0
	lea	0x174(%a0),%a0
	lea	ckpt_keys(%pc),%a1
	moveq	#1,%d1
1:	moveq	#0,%d0
	move.b	(%a1)+,%d0
	jbmi	3f
	move.l	%d0,%d2
	lsr.l	#3,%d2
	btst	%d0,(%a0,%d2.l)
	jbne	2f
	addq.l	#1,%d1
	jbra	1b
3:	moveq	#0,%d1
2:	lea	ckpt_key(%pc),%a1
	move.b	%d1,(%a1)
	move.l	(%sp)+,%d2
	rts

ckpt_keys:				/* Mac key codes of 1-9, 0, Q W E R T Y U I O P */
	.byte	0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1a, 0x1c, 0x19, 0x1d
	.byte	0x0c, 0x0d, 0x0e, 0x0f, 0x11, 0x10, 0x20, 0x22, 0x1f, 0x23, 0xff
ckpt_key:
	.byte	0
	.balign	2
	.endm
