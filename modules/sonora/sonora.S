/*
 * Sonora board module: Macs built on Apple's Sonora chip (a 68030, a VIA, an RBV-style
 * pseudo-VIA as VIA2 at $50026000, a 5380, a SWIM 2, built-in video with its own VRAM, an
 * ASC-style sound chip with a DFAC in the output path). Kernel hooks for A/UX, included by
 * a group's source (patches/lc3/src/lc3.S) after modules/common/hooks.S, once the group
 * has defined its Macs:
 *
 *   IFOURMAC yes   with d0.w = machineID, branch to yes on the group's Macs (d0 changed)
 *
 * All of it goes in .text.sonora, which the lc3 group links over orwellsize and memcdjsize
 * in pstart: the RAM sizing routines of the Orwell and djMEMC Quadras, which a Sonora Mac
 * never calls. pstart is identity-mapped, so this code runs at the same address with the
 * MMU off or on. Kernel call sites are redirected here by the group's kernel-patch.py:
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
 * The checkpoint build's keys 1-9 and 0 are checkpoints 1-10 (see the CKPT lines below
 * and the ck_* trampolines at the end, which init_first, initfunc and main's call to
 * startup are pointed at in /unix).
 *
 * A/UX's IIvx case in boardinit has the hardware of the LC III (an 030 with Egret, a VIA,
 * an RBV-style VIA2, a 5380, a SWIM 2 and built-in video with its own VRAM), so it fits.
 */

IIVX = 0x2e

	.section .text.sonora,"ax"

/*
 * int ourmac(void): 1 on the group's Macs, else 0, with the condition codes set from it.
 * Only d0 changes.
 */
ourmac:
	move.w	machineID,%d0
	IFOURMAC 1f
	moveq	#0,%d0
	rts
1:	moveq	#1,%d0
	rts

/*
 * In place of boardinit's "move.w machineID,d0; ext.l d0; bra switch": take the IIvx
 * case (Egret, RBV-style VIA2, on-board video, cpuspeed 32) on these Macs, but only here;
 * machineID stays as it is for every other user. All of them compare it with single
 * machines or with "above the IIci" (9) or "above the IIsi" (0x10), so our Macs' IDs (the
 * LC III's 0x19 and 0x3c) go where the IIvx's 0x2e goes. cpuspeed only sizes the SCSI
 * timeout loops; 32 suits 25 and 33MHz alike.
 */
	.globl	sonora_switch
sonora_switch:
	jbsr	ourmac
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
	jbsr	ourmac
	jbne	1f
	tst.l	rbv_exists
	rts
1:	cmp.l	%d0,%d0
	rts

/* In place of memsize's "jsr banksize" for one bank (see modules/common/hooks.S) */
	BANKSIZE sonora_banksize, 3

/*
 * In place of vadrspace's "jsr setup_autovectors" (see modules/common/hooks.S). Sonora
 * interrupts at levels 1 (VIA1), 2 (the pseudo-VIA: SCSI, sound, video, PDS) and 4 (SCC).
 */
	NOINTR_VECTORS sonora_vectors, 4

/* In place of aEgretDispatch's "jsr cEgretDispatch" (see modules/common/hooks.S) */
	EGRET_RESULT sonora_egret

/*
 * In place of _start's "jsr boardinit", MMU off. On these Macs, after boardinit's IIvx
 * case:
 *   devices[0] = 2  the sound chip as on the Quadras (IOSB/EASC), not the IIvx's 3.
 *                   Sonora's ASC reads FIFO A as always empty in playback and flags
 *                   "half empty" in bit 2 (FIFO B), with FIFO interrupt enables at $F09
 *                   and $F29 (MAME's hardware-tested model). The classic ASC path waits
 *                   for bit 0 and never sends a sample (writes to /dev/snd hang); the
 *                   Quadra path refills on bit 2 and manages $F09/$F29. It writes FIFO B
 *                   only, which the group's src/snd.txt changes, and has no square-wave
 *                   synthesizer, which its src/toolbox.txt works around.
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
	jbsr	ourmac
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
	jbsr	ourmac
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
	CKPT_CODE

ckpt_restart:				/* as A/UX's doboot: the ROM's restart entry */
	move.w	#0x2700,%sr
	jmp	0x4080000a

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
