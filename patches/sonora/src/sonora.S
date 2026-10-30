/*
 * LC III and LC III+ (Sonora) hooks for the A/UX kernel, linked over orwellsize and
 * memcdjsize in pstart (src/sonora.ld): the RAM sizing routines of the Orwell and djMEMC
 * Quadras, which a Sonora Mac never calls. pstart is identity-mapped, so this code runs
 * at the same address with the MMU off or on. Kernel call sites are redirected here by
 * the patch that kernel-patch.py generates:
 *
 *   _start: jsr boardinit -> sonora_board (MMU off)
 *   boardinit's switch -> sonora_switch  (MMU off)
 *   memsize: tst.l rbv_exists -> jsr sonora_rbv  (MMU off)
 *   memsize: jsr banksize -> sonora_banksize     (MMU off)
 *   vadrspace: jsr setup_autovectors -> sonora_vectors  (MMU on)
 *   aEgretDispatch: jsr cEgretDispatch -> sonora_egret  (MMU on)
 *   cEgretDispatch's first instruction -> jmp sonora_cegret  (MMU on)
 *
 * Every hook leaves other machines alone, but the space the code takes is the Orwell and
 * djMEMC Quadras' RAM sizing, so a kernel with this patch is for these Macs only.
 *
 * Checkpoint build (CKPT_BUILD, build.sh with CKPT=1): holding a digit key through A/UX
 * Startup's "Launching" makes the kernel restart the machine (startup chime) when it
 * reaches that key's checkpoint, so a hang can be located without a console. Keys 1-9
 * and 0 are checkpoints 1-10 (see the CKPT lines below and the ck_* trampolines at the
 * end, which init_first, initfunc and main's call to startup are pointed at in /unix).
 *
 * The machineID is Gestalt - 2. The LC III and Performa 450 are Gestalt 27, the LC III+
 * and Performa 460, 466 and 467 Gestalt 62. The ROM tells them apart by the CPU ID
 * register ($A55A0001 / $A55A0003), which follows the clock Sonora is set to make: an
 * LC III set to 33MHz reports 62, as a 33MHz Quadra 605 reports its own ID. These Macs are
 * an 030 with Egret, a VIA, an RBV-style pseudo-VIA as VIA2 at $50026000, a 5380, a SWIM 2
 * and built-in video with its own VRAM: A/UX's IIvx case in boardinit, which has all of
 * that, fits.
 */

LCIII = 0x19			/* Gestalt 27: LC III, Performa 450 */
LCIIIPLUS = 0x3c		/* Gestalt 62: LC III+, Performa 460, 466, 467 */
IIVX = 0x2e

	.macro	CKPT n
#ifdef CKPT_BUILD
	move.w	#\n,-(%sp)
	jsr	ckpt
#endif
	.endm

	.section .text.sonora,"ax"

/*
 * int issonora(void): 1 on an LC III or LC III+, else 0, with the condition codes set
 * from it. Only d0 changes.
 */
issonora:
	move.w	machineID,%d0
	cmp.w	#LCIII,%d0
	jbeq	1f
	cmp.w	#LCIIIPLUS,%d0
	jbeq	1f
	moveq	#0,%d0
	rts
1:	moveq	#1,%d0
	rts

/*
 * In place of boardinit's "move.w machineID,d0; ext.l d0; bra switch": take the IIvx
 * case (Egret, RBV-style VIA2, on-board video, cpuspeed 32) on these Macs, but only here;
 * machineID stays as it is for every other user. All of them compare it with single
 * machines or with "above the IIci" (9) or "above the IIsi" (0x10), so 0x19 and 0x3c go
 * where the IIvx's 0x2e goes. cpuspeed only sizes the SCSI timeout loops; 32 suits both
 * clocks.
 */
	.globl	sonora_switch
sonora_switch:
	jbsr	issonora
	jbne	1f
	move.w	machineID,%d0
	ext.l	%d0
	jmp	boardinit_switch
1:	moveq	#IIVX,%d0
	jmp	boardinit_switch

/*
 * In place of memsize's "tst.l rbv_exists" before its "bne.w" to the RBV banks: on these
 * Macs, say no (Z set), so memsize sizes one bank from the kernel's end with banksize
 * (sonora_banksize below). Sonora's RAM is one contiguous bank from 0, but the RBV path
 * would also probe a second bank at $04000000, where the IIci has one, and it probes
 * without a limit.
 */
	.globl	sonora_rbv
sonora_rbv:
	jbsr	issonora
	jbne	1f
	tst.l	rbv_exists
	rts
1:	cmp.l	%d0,%d0
	rts

/*
 * In place of memsize's "jsr banksize" for one bank (with "moveq #0,d0; move.l d0,-(sp)"
 * before it shortened to "clr.l -(sp)"). Other machines go to banksize itself.
 *
 * banksize(start, from, bank) probes RAM a page at a time upward from `from' with no
 * limit, until a page fails its pattern or alias checks. A bus error on the way goes to
 * _start's memerror%, which abandons memsize with the bank unrecorded. This is banksize's
 * algorithm with a bus error catch around each probe (as pdsprobe does for PDS cards) and
 * a limit from Mac OS's low memory, which launch copies to kstart: the larger of BufPtr
 * ($10C) and PhysMemTop ($1EF8), rounded up to 1MB. In 24-bit mode (32-bit addressing off,
 * as System 7.1 starts on these Macs) Mac OS uses only the first 8MB and BufPtr is below
 * that, while PhysMemTop is the end of physical RAM either way (MAME, 32MB: BufPtr
 * $7E9428, PhysMemTop $2000000); with BufPtr alone A/UX got 8MB of a real LC III's 36.
 * Otherwise the MEMCjr patch's b605_banksize. Same results as banksize: bank = {start,
 * from, end, 1}, numbanks++, probed pages zeroed, lowmem 0 restored.
 */
	.globl	sonora_banksize
sonora_banksize:
	jbsr	issonora
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
6:	CKPT	3			/* RAM sized */
	movem.l	(%sp)+,%d2-%d7/%a2-%a4
	rts

/*
 * In place of vadrspace's "jsr setup_autovectors". Sonora interrupts at levels 1 (VIA1),
 * 2 (VIA2: SCSI, sound, video, PDS) and 4 (SCC). Past the Quadra 700, A/UX leaves levels
 * 3 and 5 on faulthdlr (an "unexpected kernel trap" panic) and 6 on powerintr (SIGPWR to
 * init). Point 3, 5 and 6 at nointr (rte), as setup_autovectors itself does for the
 * Quadra 700 and older: a 33MHz Quadra 605 took a stray level 3 once.
 */
	.globl	sonora_vectors
sonora_vectors:
	CKPT	4			/* MMU on */
	jbsr	issonora
	jbeq	1f
	move.l	#nointr,%d0
	move.l	%d0,autovec+8		/* level 3 */
	move.l	%d0,autovec+16		/* level 5 */
	move.l	%d0,autovec+20		/* level 6 */
1:	jmp	setup_autovectors

/*
 * In place of aEgretDispatch's "jsr cEgretDispatch". aEgretDispatch is A/UX's handler for
 * the ROM's _EgretDispatch trap and passes back cEgretDispatch's C result (1 = done) in
 * d0. Mac OS returns pbResult (0 = noErr). The LC III ROM's XPRAM routine (ROM+$B37D6,
 * the Quadra 605's ROM+$B37EC) hands that d0 on as _ReadXPRam's and _WriteXPRam's result,
 * so ROM code in the kernel saw every PRAM access fail; on the 605 that stopped the video
 * driver's Open before it read its slot PRAM. On these Macs, return pbResult, with the
 * condition codes set from it; elsewhere, as before. A/UX's own callers of ReadXPRam and
 * WriteXPRam ignore d0.
 */
	.globl	sonora_egret
sonora_egret:
	jbsr	issonora
	jbeq	1f
	move.l	4(%sp),-(%sp)		/* the parameter block aEgretDispatch pushed */
	jsr	cEgretDispatch
	addq.l	#4,%sp
	movea.l	4(%sp),%a0
	move.w	14(%a0),%d0		/* pbResult */
	ext.l	%d0
	rts
1:	jmp	cEgretDispatch

/*
 * In place of _start's "jsr boardinit", MMU off. On these Macs, after boardinit's IIvx
 * case:
 *   devices[0] = 2  the sound chip as on the Quadras (IOSB/EASC), not the IIvx's 3.
 *                   Sonora's ASC reads FIFO A as always empty in playback and flags
 *                   "half empty" in bit 2 (FIFO B), with FIFO interrupt enables at $F09
 *                   and $F29 (MAME's hardware-tested model). The classic ASC path waits
 *                   for bit 0 and never sends a sample (writes to /dev/snd hang); the
 *                   Quadra path refills on bit 2 and manages $F09/$F29. It writes FIFO B
 *                   only, which src/snd-sonora.txt changes, and has no square-wave
 *                   synthesizer, which src/toolbox-sonora.txt works around.
 *   sonora_dfac     the DFAC bits sonora_cegret puts into every DFAC setting.
 * The checkpoint build also notes the held key and has checkpoints around boardinit.
 */
	.globl	sonora_board
sonora_board:
#ifdef CKPT_BUILD
	jbsr	ckpt_capture
#endif
	CKPT	1			/* kernel entered, cpuinit done */
	jsr	boardinit
	CKPT	2			/* boardinit done */
	jbsr	issonora
	jbeq	1f
	move.b	#2,devices
	move.l	kstart,%a0
	moveq	#7,%d1
	and.b	0x260(%a0),%d1		/* Mac OS SdVolume, 0-7 */
	move.b	vol_bits(%pc,%d1.w),%d0
	lea	sonora_dfac(%pc),%a0
	move.b	%d0,(%a0)
1:	rts

/*
 * In place of cEgretDispatch's first instruction ("link.l a6,#-12"), for every Egret
 * request. The DFAC, set with the Egret pseudo-command $0E, is in these Macs' sound output
 * path (sound chip PWM -> DFAC low pass filter -> amplifier -> volume attenuator). A/UX's
 * sound input code (setDFACByte) sends its own setting, 0 and then AGC bits, which cut the
 * output off (MAME: Mac OS $6A, A/UX $00 then $08). On these Macs, turn on bit 1 (low pass
 * filter to amplifier, the output path) and set bits 7-5 (volume) from Mac OS's SdVolume,
 * which is where Mac OS puts it (MAME: SdVolume 3, $6A). A/UX's volume control writes the
 * sound chip's own volume ($806), which the real Sonora applies, so this setting stays as
 * it is. The byte travels bit-reversed (setDFACByte's reverse_bits), so those are bits 6
 * and 2-0 of the request's data byte here. sonora_dfac holds them, worked out by
 * sonora_board.
 */
	.globl	sonora_cegret
sonora_cegret:
	move.l	4(%sp),%a0		/* the parameter block */
	cmp.w	#0x010e,(%a0)		/* pseudo command, set DFAC */
	jbne	1f
	jbsr	issonora
	jbeq	1f
	moveq	#0xb8-0x100,%d0		/* all but bit 6 and bits 2-0 */
	and.b	2(%a0),%d0
	or.b	sonora_dfac(%pc),%d0
	move.b	%d0,2(%a0)
1:	link.l	%a6,#-12
	jmp	cEgretDispatch+6

vol_bits:				/* bit 6 (output path) + SdVolume 0-7 bit-reversed */
	.byte	0x40, 0x44, 0x42, 0x46, 0x41, 0x45, 0x43, 0x47
sonora_dfac:
	.byte	0
	.balign	2

#ifdef CKPT_BUILD
/* CKPT n: move.w #n,-(sp); jsr ckpt. Restarts if n is the held key's checkpoint;
   otherwise returns with n popped and all registers but the condition codes kept. */
ckpt:
	move.l	%d0,-(%sp)
	move.b	ckpt_key(%pc),%d0
	cmp.b	9(%sp),%d0
	jbeq	1f
	move.l	(%sp)+,%d0
	rtd	#2
1:	move.w	#0x2700,%sr		/* as A/UX's doboot: the ROM's restart entry */
	jmp	0x4080000a

/*
 * Record which checkpoint key Mac OS saw held (its KeyMap, as launch left it at
 * kstart+$174) in ckpt_key, 0 for none. MMU off.
 */
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

ckpt_keys:				/* Mac key codes of 1-9, 0 */
	.byte	0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1a, 0x1c, 0x19, 0x1d, 0xff
ckpt_key:
	.byte	0
	.balign	2

/* Checkpoints in tables and calls the patch redirects (init tables: /unix only) */
	.globl	ck_egret_init, ck_video_init, ck_fdb_init, ck_startup, ck_iinit, ck_nvram_init
ck_egret_init:	CKPT 5			/* VIAs set up, before the Egret */
	jmp	egret_init
ck_video_init:	CKPT 6			/* Egret up, before video and the Slot Manager */
	jmp	video_init
ck_fdb_init:	CKPT 7			/* video up, before ADB */
	jmp	fdb_init
ck_startup:	CKPT 8			/* all init_first done, before driver startup */
	jmp	startup
ck_iinit:	CKPT 9			/* drivers started (SCSI), before mounting root */
	jmp	iinit
ck_nvram_init:	CKPT 10			/* root mounted (key 0) */
	jmp	nvram_init
#endif
