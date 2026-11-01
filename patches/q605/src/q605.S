/*
 * The q605 group's kernel hooks: the Quadra 605 and LC/Performa 475, with the MEMCjr board
 * module (modules/memcjr). The Cuda transport (modules/cuda/cuda.c) is linked beside it;
 * src/kernel.ld places both.
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

/* d0.w = machineID: branch to \yes on the Macs this group supports; d0 changed */
	.macro	IFOURMAC yes
	sub.w	#LC475,%d0
	cmp.w	#1,%d0
	jbls	\yes			/* LC475, LC475 + 1 */
	subq.w	#QUADRA605-LC475,%d0
	cmp.w	#1,%d0
	jbls	\yes			/* QUADRA605, QUADRA605 + 1 */
	.endm

#include "common/hooks.S"
#include "memcjr/memcjr.S"
