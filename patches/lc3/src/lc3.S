/*
 * The lc3 group's kernel hooks: the LC III and LC III+ and their Performa twins, Sonora
 * Macs with Egret, with the Sonora board module (modules/sonora). src/kernel.ld places it.
 *
 * The machineID is Gestalt - 2. The LC III and Performa 450 are Gestalt 27, the LC III+
 * and Performa 460, 466 and 467 Gestalt 62. The ROM tells them apart by the CPU ID
 * register ($A55A0001 / $A55A0003), which follows the clock Sonora is set to make: an
 * LC III set to 33MHz reports 62, as a 33MHz Quadra 605 reports its own ID.
 */

LCIII = 0x19			/* Gestalt 27: LC III, Performa 450 */
LCIIIPLUS = 0x3c		/* Gestalt 62: LC III+, Performa 460, 466, 467 */

/* d0.w = machineID: branch to \yes on the Macs this group supports */
	.macro	IFOURMAC yes
	cmp.w	#LCIII,%d0
	jbeq	\yes
	cmp.w	#LCIIIPLUS,%d0
	jbeq	\yes
	.endm

#include "common/hooks.S"
#include "sonora/sonora.S"
