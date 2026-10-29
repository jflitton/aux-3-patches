/*
 * Quadra 605 and LC/Performa 475 boot hooks for the A/UX kernel, linked after the Cuda
 * transport in the dead Egret code (src/kernel605.ld; .text.boot605.extra, the MMU-on hooks
 * and the ProductInfo buffer, goes in egret_reset's dead body). Kernel call sites are
 * redirected here by the patch that kernel-patch.py generates:
 *
 *   boardinit's switch    -> b605_switch   (MMU off)
 *   _start: jsr boardinit -> b605_board    (MMU off)
 *   memsize: jsr banksize -> b605_banksize (MMU off)
 *   vadrspace: jsr setup_lowmem_globals -> b605_lowmem  (MMU on)
 *   vadrspace: jsr setup_autovectors -> b605_vectors    (MMU on)
 *   aEgretDispatch: jsr cEgretDispatch -> b605_egret    (MMU on)
 *
 * With the MMU off this code runs at its physical address (kernel .text is loaded at
 * the first 4KB page after pstart), so it reaches itself PC-relative and the kernel
 * only through pstart, which is identity-mapped. Every hook leaves other machines alone.
 * DAFB monitor sensing is A/UX's own (DAFBReadSenseLines), as on a Centris 650.
 *
 * The machineID (Gestalt - 2) follows the clock: the ROM picks its ProductInfo by the CPU
 * ID register, whose low bits give the speed. Quadra 605: $2225 25MHz (Gestalt 94), $2226
 * 33MHz (Gestalt 95), so 0x5c and 0x5d. LC 475 and Performa 475/476: $2221 25MHz
 * (Gestalt 89), $2222 33MHz (Gestalt 90), so 0x57 and 0x58. The ROM's 475 records differ
 * from the 605's only in ProductKind and CPU ID, so the 475 gets the 605's treatment; it is
 * untested on a real 475.
 */

QUADRA605 = 0x5c		/* 25MHz; 33MHz is QUADRA605 + 1 */
LC475 = 0x57			/* 25MHz; 33MHz is LC475 + 1 */
CENTRIS650 = 0x1c
MEMCJR_HOLD = 0x50f0e07c	/* upper six bits of 12-bit DAFB/MEMCjr registers */
PI_CPUID = 0x45			/* ProductInfo: low byte of the CPU ID; bit 1 set at 33MHz */

/* d0.w = machineID: branch to \yes on the Macs this patch supports; d0 changed */
	.macro	IFMEMCJR yes
	sub.w	#LC475,%d0
	cmp.w	#1,%d0
	jbls	\yes			/* LC475, LC475 + 1 */
	subq.w	#QUADRA605-LC475,%d0
	cmp.w	#1,%d0
	jbls	\yes			/* QUADRA605, QUADRA605 + 1 */
	.endm

/*
 * Checkpoint build (CKPT_BUILD, build.sh with CKPT=1): holding a key
 * through A/UX Startup's "Launching" makes the kernel restart the machine (startup
 * chime) when it reaches that key's checkpoint, so a hang can be located without a
 * console. Keys 1-9, 0 are checkpoints 1-10; Q W E R T Y U I O P are 11-20. The
 * checkpoint code lives in .text.ckpt, linked over orwellsize in pstart (identity-mapped,
 * so it runs the same with the MMU off or on; only Orwell machines call orwellsize).
 */
	.macro	CKPT n
#ifdef CKPT_BUILD
	move.w	#\n,-(%sp)
	jsr	ckpt
#endif
	.endm

	.section .text.boot605,"ax"

/*
 * int ismemcjr(void): 1 on a 605 or a 475 (either speed), else 0, with the condition codes
 * set from it. Only d0 changes, so cuda.c calls it too.
 */
	.globl	ismemcjr
ismemcjr:
	move.w	machineID,%d0
	IFMEMCJR 1f
	moveq	#0,%d0
	rts
1:	moveq	#1,%d0
	rts

/*
 * In place of boardinit's "move.w machineID,d0; ext.l d0; bra switch": take the
 * Centris 650 case (djMEMC/IOSB: 53C96, SWIM, SCC, sound, DAFB) for the 605 and 475, but
 * only here; machineID stays as it is for every other user.
 */
	.globl	b605_switch
b605_switch:
	CKPT	2			/* setupProductInfo done */
	jbsr	ismemcjr
	jbne	1f
	move.w	machineID,%d0
	ext.l	%d0
	jbra	2f
1:	moveq	#CENTRIS650,%d0
2:	jmp	boardinit_switch

/*
 * Wraps the call to boardinit. On the 605 and 475:
 *   devices[1] = 1  Egret present: the Cuda transport stands in for it (ADB, RTC,
 *                   PRAM, power off, reboot)
 *   devices[5] = 0  size RAM with the generic banksize probe, not memcdjsize
 *                   (MEMCjr is not djMEMC)
 *   cpuspeed = 25 or 33 (MHz)  scales the SCSI timeout loops; the C650 case sets it
 *                   only for 0x1c. Taken from the CPU ID in ProductInfo, as the ROM's
 *                   video init does: machineID's low bit means 33MHz on the 605 but
 *                   25MHz on the 475.
 * and builds the ProductInfo copy that b605_lowmem installs.
 */
	.globl	b605_board
b605_board:
#ifdef CKPT_BUILD
	jsr	ckpt_capture
#endif
	CKPT	1			/* kernel entered, cpuinit done */
	jsr	boardinit
	CKPT	8			/* boardinit done */
	CKPT	20			/* the same, restarting as the first ckpt image did */
	jbsr	ismemcjr
	jbeq	1f
	move.b	#1,devices+1
	clr.b	devices+5
	jbsr	b605_prodinfo
	moveq	#25,%d0
	lea	pi_buf(%pc),%a0		/* physical */
	btst	#1,PI_CPUID(%a0)
	jbeq	2f
	moveq	#33,%d0
2:	move.l	%d0,cpuspeed
1:	rts

/*
 * Copy the ROM's ProductInfo (Mac OS's UnivInfoPtr, as setupProductInfo finds it) to
 * pi_buf: all 0x48 bytes, since the 605 ROM uses the routine tables at +0x34 and +0x38
 * (A/UX copies only 0x34 bytes when it copies at all). Self-relative offsets are
 * rebased for pi_buf's virtual address; 0 means absent and stays 0. The VideoInfo goes
 * along to +0x60 with its 32-bit logical VRAM address set to the physical one: the 605
 * ROM says $51900000, where its own MMU setup maps VRAM, but A/UX maps $40000000-
 * $7FFFFFFF one to one, so slot 0's primary init would find no VRAM there.
 */
PI_SIZE = 0x48
VI_AT = 0x60
VI_SIZE = 0x20

b605_prodinfo:
	movem.l	%d2/%a2,-(%sp)
	move.l	kstart,%a0
	move.l	0xdd8(%a0),%a0		/* the ROM's ProductInfo */
	lea	pi_buf(%pc),%a1		/* physical */
	move.l	%a0,%d2
	sub.l	#pi_buf,%d2		/* source - copy (virtual) */
	moveq	#PI_SIZE/4-1,%d0
1:	move.l	(%a0,%d0.w*4),(%a1,%d0.w*4)
	dbra	%d0,1b
	lea	pi_offsets(%pc),%a2
2:	move.w	(%a2)+,%d0
	jbmi	3f
	tst.l	(%a1,%d0.w)
	jbeq	2b
	add.l	%d2,(%a1,%d0.w)
	jbra	2b
3:	add.l	8(%a0),%a0		/* the ROM's VideoInfo */
	moveq	#VI_SIZE/4-1,%d0
4:	move.l	(%a0,%d0.w*4),VI_AT(%a1,%d0.w*4)
	dbra	%d0,4b
	move.l	VI_AT(%a1),VI_AT+4(%a1)	/* VRAMLogAddr32 = VRAMPhysAddr */
	moveq	#VI_AT,%d0
	move.l	%d0,8(%a1)
	movem.l	(%sp)+,%d2/%a2
	rts

pi_offsets:
	.word	0x00, 0x04, 0x08, 0x0c, 0x28, 0x2c, 0x30, 0x34, 0x38, -1

/*
 * In place of memsize's "jsr banksize" for machines without djMEMC, Orwell or RBV
 * (with "moveq #0,d0; move.l d0,-(sp)" before it shortened to "clr.l -(sp)"). Other
 * machines go to banksize itself.
 *
 * banksize(start, from, bank) probes RAM a page at a time upward from `from' with no
 * limit, until a page fails its pattern or alias checks. A bus error on the way (real
 * MEMCjr past the last SIMM?) goes to _start's memerror%, which abandons memsize with the
 * bank unrecorded. This is banksize's algorithm with a bus error catch around each probe
 * (as pdsprobe does for PDS cards) and a limit from Mac OS: its BufPtr, which launch
 * leaves at kstart+$10C (MemTop there is the kernel's end), rounded up to 1MB. In MAME
 * that is the RAM size exactly: Mac OS keeps 0x20000-0x50000 at the top for itself.
 * Same results: bank = {start, from, end, 1}, numbanks++, probed pages zeroed, lowmem 0
 * restored.
 */
	.globl	b605_banksize
b605_banksize:
	jbsr	ismemcjr
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
	add.l	#0xfffff,%d7
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
6:	CKPT	9			/* RAM sized */
	movem.l	(%sp)+,%d2-%d7/%a2-%a4
	rts

/*
 * The hooks below run with the MMU on, so they can live in .text.boot605.extra (egret_reset's
 * dead body, next to pi_buf) and leave room in .text for the code that runs at physical
 * addresses.
 */
	.section .text.boot605.extra,"ax"

/*
 * In place of vadrspace's "jsr setup_lowmem_globals", just after turnon_mmu: point
 * ProductInfoPtr at the copy, which setup_lowmem_globals then hands to the ROM as
 * UnivInfoPtr ($DD8). Physical-mode users of ProductInfoPtr (get_rbv_info in
 * boardinit) have already seen the ROM's own record, which is valid there.
 */
	.globl	b605_lowmem
b605_lowmem:
	CKPT	10			/* MMU on */
	jbsr	ismemcjr
	jbeq	1f
	move.l	#pi_buf,ProductInfoPtr
1:	jmp	setup_lowmem_globals

/*
 * In place of vadrspace's "jsr setup_autovectors". The 605 and 475 interrupt at levels 1
 * (VIA1), 2 (VIA2) and 4 (SCC). Past the Quadra 700, A/UX leaves levels 3 and 5 on
 * faulthdlr (an "unexpected kernel trap" panic) and 6 on powerintr (SIGPWR to init). A
 * 33MHz 605 took a stray level 3 (trap type 27) at IPL 2 in the SCSI interrupt, root
 * already mounted: most likely the IPL lines reading 3 for a moment between levels 1 and
 * 2. Point 3, 5 and 6 at nointr (rte), as setup_autovectors itself does for the Quadra
 * 700 and older.
 */
	.globl	b605_vectors
b605_vectors:
	jbsr	ismemcjr
	jbeq	1f
	move.l	#nointr,%d0
	move.l	%d0,autovec+8		/* level 3 */
	move.l	%d0,autovec+16		/* level 5 */
	move.l	%d0,autovec+20		/* level 6 */
1:	jmp	setup_autovectors

/*
 * In place of aEgretDispatch's "jsr cEgretDispatch". aEgretDispatch is A/UX's handler for
 * the ROM's _EgretDispatch trap and passes back cEgretDispatch's C result (1 = done) in
 * d0. Mac OS returns pbResult (0 = noErr), and the 605 ROM's XPRAM routine (ROM+$B37EC)
 * hands that d0 on as _ReadXPRam's and _WriteXPRam's result. So in the kernel every slot
 * PRAM read "failed": the DAFB driver's Open gave up before reading its PRAM flags, and
 * its mode sets then left out the MEMCjr pipeline correction to HAL/HFP (picture shifted
 * left, more at lower depths; Thousands broken). On the 605 and 475, return pbResult,
 * with the condition codes set from it; elsewhere, as before. A/UX's own callers of
 * ReadXPRam and WriteXPRam ignore d0.
 */
	.globl	b605_egret
b605_egret:
	jbsr	ismemcjr
	jbeq	1f
	move.l	4(%sp),-(%sp)		/* the parameter block aEgretDispatch pushed */
	jsr	cEgretDispatch
	addq.l	#4,%sp
	movea.l	4(%sp),%a0
	move.w	14(%a0),%d0		/* pbResult */
	ext.l	%d0
	rts
1:	jmp	cEgretDispatch

	.balign	4
pi_buf:
	.space	VI_AT + VI_SIZE

#ifdef CKPT_BUILD
	.section .text.ckpt,"ax"

/* CKPT n: move.w #n,-(sp); jsr ckpt. Restarts if n is the held key's checkpoint;
   otherwise returns with n popped and all registers but the condition codes kept. */
ckpt:
	move.l	%d0,-(%sp)
	move.b	ckpt_key(%pc),%d0
	cmp.b	9(%sp),%d0
	jbeq	ckpt_restart
	move.l	(%sp)+,%d0
	rtd	#2

/*
 * As A/UX's doboot: the ROM's restart entry. On the 605 and 475, first empty MEMCjr's
 * holding register, which every DAFB read loads and the next register write ORs in, so
 * the ROM's start-up writes do not inherit it. Checkpoint 20 skips that, as the first
 * checkpoint image did. (Its own test: ismemcjr is in .text, not reachable from here
 * with the MMU off.)
 */
ckpt_restart:				/* d0 = checkpoint */
	move.w	#0x2700,%sr
	cmp.b	#20,%d0
	jbeq	1f
	move.w	machineID,%d0
	IFMEMCJR 2f
	jbra	1f
2:	clr.l	MEMCJR_HOLD
1:	jmp	0x4080000a

/*
 * Called first thing in b605_board, MMU off: record which checkpoint key Mac OS saw
 * held (its KeyMap, as launch left it at kstart+$174) in ckpt_key, 0 for none.
 */
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

/*
 * In place of _DAFBMonitorDetect's jsr DAFBReadSenseLines in this build: A/UX's own
 * DAFBReadSenseLines, on every machine, with a checkpoint after each DAFB access.
 */
	.globl	b605_sense
b605_sense:
	CKPT	3			/* before the first DAFB access */
	movea.l	#0xf9800000,%a0
	jsr	DAFBResetDelay		/* reads $2C four times */
	CKPT	4
	clr.l	-(%sp)
	move.l	0x1c(%a0),(%sp)		/* sense lines */
	CKPT	5
	not.b	3(%sp)
	andi.b	#7,3(%sp)
	move.l	#7,0x1c(%a0)		/* stop driving them */
	CKPT	6
	jsr	DAFBResetDelay
	CKPT	7
	move.b	3(%sp),%d0
	tst.l	(%sp)+
	rts

/* Checkpoints in tables and calls the patch redirects (init tables: /unix only) */
	.globl	ck_extsense
	.globl	ck_egret_init, ck_video_init, ck_fdb_init, ck_startup, ck_iinit, ck_nvram_init
ck_extsense:	CKPT 17			/* sense lines read 7: extended sense next */
	jmp	ReadExtendedSense
ck_egret_init:	CKPT 11			/* VIAs set up, before the Cuda */
	jmp	egret_init
ck_video_init:	CKPT 12			/* Cuda up, before video and the Slot Manager */
	jmp	video_init
ck_fdb_init:	CKPT 13			/* video up, before ADB */
	jmp	fdb_init
ck_startup:	CKPT 14			/* all init_first done, before driver startup */
	jmp	startup
ck_iinit:	CKPT 15			/* drivers started (SCSI), before mounting root */
	jmp	iinit
ck_nvram_init:	CKPT 16			/* root mounted */
	jmp	nvram_init
#endif
