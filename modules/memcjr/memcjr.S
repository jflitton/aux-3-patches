/*
 * MEMCjr board module: the Quadra 605 and LC/Performa 475 (Cuda, MEMCjr with DAFB, IOSB
 * style I/O). Kernel hooks for A/UX, included by a group's source (patches/q605/src/q605.S)
 * after modules/common/hooks.S, once the group has defined its Macs:
 *
 *   IFOURMAC yes   with d0.w = machineID, branch to yes on the group's Macs (d0 changed)
 *
 * The code goes in three sections for the group's linker script to place: .text.boot605,
 * the hooks that run with the MMU off; .text.boot605.extra, the MMU-on hooks and the
 * ProductInfo buffer; .text.ckpt, the checkpoint code (CKPT_BUILD only). The q605 group
 * links the first two in the dead Egret code after the Cuda transport (modules/cuda), and
 * the third over orwellsize. Kernel call sites are redirected here by the group's
 * kernel-patch.py:
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
 */

CENTRIS650 = 0x1c
MEMCJR_HOLD = 0x50f0e07c	/* upper six bits of 12-bit DAFB/MEMCjr registers */
PI_CPUID = 0x45			/* ProductInfo: low byte of the CPU ID; bit 1 set at 33MHz */

	.section .text.boot605,"ax"

/*
 * int ourmac(void): 1 on the group's Macs, else 0, with the condition codes set from it.
 * Only d0 changes, so the Cuda transport (modules/cuda/cuda.c) calls it too.
 */
	.globl	ourmac
ourmac:
	move.w	machineID,%d0
	IFOURMAC 1f
	moveq	#0,%d0
	rts
1:	moveq	#1,%d0
	rts

/*
 * In place of boardinit's "move.w machineID,d0; ext.l d0; bra switch": take the
 * Centris 650 case (djMEMC/IOSB: 53C96, SWIM, SCC, sound, DAFB) on our Macs, but only
 * here; machineID stays as it is for every other user.
 */
	.globl	b605_switch
b605_switch:
	CKPT	2			/* setupProductInfo done */
	jbsr	ourmac
	jbne	1f
	move.w	machineID,%d0
	ext.l	%d0
	jbra	2f
1:	moveq	#CENTRIS650,%d0
2:	jmp	boardinit_switch

/*
 * Wraps the call to boardinit. On our Macs:
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
	jbsr	ourmac
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
 * In place of memsize's "jsr banksize" for machines without djMEMC, Orwell or RBV (see
 * modules/common/hooks.S). Its limit, the larger of Mac OS's BufPtr and PhysMemTop, is the
 * end of RAM: in MAME, BufPtr rounded up to 1MB is the RAM size exactly (Mac OS keeps
 * 0x20000-0x50000 at the top for itself), and PhysMemTop covers Mac OS in 24-bit mode,
 * where BufPtr is below 8MB.
 */
	BANKSIZE b605_banksize, 9

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
	jbsr	ourmac
	jbeq	1f
	move.l	#pi_buf,ProductInfoPtr
1:	jmp	setup_lowmem_globals

/* In place of vadrspace's "jsr setup_autovectors" (see modules/common/hooks.S) */
	NOINTR_VECTORS b605_vectors

/* In place of aEgretDispatch's "jsr cEgretDispatch" (see modules/common/hooks.S) */
	EGRET_RESULT b605_egret

	.balign	4
pi_buf:
	.space	VI_AT + VI_SIZE

#ifdef CKPT_BUILD
	.section .text.ckpt,"ax"

	CKPT_CODE

/*
 * Restart, d0 = checkpoint: as A/UX's doboot, the ROM's restart entry. On our Macs, first
 * empty MEMCjr's holding register, which every DAFB read loads and the next register write
 * ORs in, so the ROM's start-up writes do not inherit it. Checkpoint 20 skips that, as the
 * first checkpoint image did. (Its own test: ourmac is in .text, not reachable from here
 * with the MMU off.)
 */
ckpt_restart:
	move.w	#0x2700,%sr
	cmp.b	#20,%d0
	jbeq	1f
	move.w	machineID,%d0
	IFOURMAC 2f
	jbra	1f
2:	clr.l	MEMCJR_HOLD
1:	jmp	0x4080000a

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
