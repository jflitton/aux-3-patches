/*
 * Cuda transport for the A/UX Egret driver, for the Macs with Cuda in place of Egret (in
 * the q605 group, the Quadra 605 and LC/Performa 475).
 *
 * Cuda speaks the same packets as Egret but drives the VIA1 port B handshake
 * differently (see Linux drivers/macintosh/via-cuda.c):
 *
 *   PB3 TREQ  in   active low  (Egret: transceiver session, same sense)
 *   PB4 TACK  out  active low, toggled once per byte  (Egret: "VIA full" pulse)
 *   PB5 TIP   out  active low  (Egret: system session, active high)
 *
 * These routines replace cEgretDispatch (linked at its address), and are reached
 * from jmp stubs at shift_reg_intr, egret_reset and abort_pending_transactions.
 * Everything above the wire is A/UX's own: the Egret Manager parameter block,
 * valid_packet, the byte-count tables, resprec and the fdb/key completions.
 * Polled like the original; callers run at spl1 or above.
 *
 * Only the group's Macs (ourmac, from the board module linked with this) get Cuda
 * signalling. A/UX's Egret machines (IIsi, IIvi, IIvx, Performa 600, Quadra 900 and 950)
 * reach the same entry points, and there the Egret is left alone: resets do nothing,
 * requests fail as on a timeout, and interrupts are only acknowledged. That keeps a patched
 * disk booted on one of them from driving the Egret's handshake lines the Cuda way; a
 * kernel with this transport does not support them.
 */

typedef unsigned char u8;

struct egretpb {			/* Egret Manager parameter block */
	u8	type;			/* 0  pbCmdType: 0 ADB, 1 pseudo, 0xfe/0xff hooks */
	u8	cmd;			/* 1  pbCmd */
	u8	param[4];		/* 2  pbParam */
	unsigned short count;		/* 6  pbByteCnt */
	u8	*buf;			/* 8  pbBufPtr */
	u8	flags, spare;		/* 12 */
	short	result;			/* 14 pbResult */
	void	(*completion)();	/* 16 pbCompletion */
};

/* kernel symbols (addresses come from the kernel's COFF symbol table) */
extern int	valid_packet(struct egretpb *);
extern int	param_send_bytecnt(struct egretpb *);
extern int	buffer_send_bytecnt(struct egretpb *);
extern void	egret_delay_us(int);
extern int	getsr(void);
extern int	spl1(void);
extern void	splx(int);
extern void	onesec(void);
extern void	(*fdb_completion)(u8 *);
extern void	(*key_completion)(void);
extern u8	keysw_position;
extern u8	resprec[];

/* the board module (modules/memcjr): 1 on the group's Macs, from machineID */
extern int	ourmac(void);

#define VIA1	((volatile u8 *)0x50000000)
#define vBufB	0x0000
#define vDirB	0x0400
#define vSR	0x1400
#define vACR	0x1600
#define vIFR	0x1a00

#define TREQ	0x08
#define TACK	0x10
#define TIP	0x20
#define SR_OUT	0x10
#define SR_CTRL	0x1c
#define SR_EXT	0x0c
#define SR_INT	0x04

#define TIMEOUT	0x40000			/* VIA reads, a few hundred ms */

#define PKT_ADB		0
#define PKT_TIMER	3
#define PKT_POWER	4

static inline void
via_w(int reg, u8 v)
{
	VIA1[reg] = v;
	__asm__ volatile("nop");	/* as A/UX does after every VIA write */
}

static int
wait_sr(void)
{
	long n = TIMEOUT;

	while (!(VIA1[vIFR] & SR_INT))
		if (--n == 0)
			return -1;
	return 0;
}

static int
wait_treq(int asserted)
{
	long n = TIMEOUT;

	while (((VIA1[vBufB] & TREQ) == 0) != asserted)
		if (--n == 0)
			return -1;
	return 0;
}

static void
end_transfer(void)
{
	via_w(vACR, VIA1[vACR] & ~SR_OUT);
	(void)VIA1[vSR];
	via_w(vBufB, VIA1[vBufB] | TIP | TACK);
}

/* i-th byte of the outgoing packet: type, cmd, pn params, then the buffer */
static u8
pb_byte(struct egretpb *pb, int i, int pn)
{
	if (i < 2)
		return i ? pb->cmd : pb->type;
	if (i < 2 + pn)
		return pb->param[i - 2];
	return pb->buf[i - 2 - pn];
}

/* 0 sent, -1 Cuda wants to talk first (receive, then retry), -2 timeout */
static int
cuda_send(struct egretpb *pb)
{
	int pn = param_send_bytecnt(pb);
	int n = 2 + pn + buffer_send_bytecnt(pb);
	int i;

	if (!(VIA1[vBufB] & TREQ))
		return -1;
	via_w(vACR, VIA1[vACR] | SR_OUT);
	via_w(vSR, pb_byte(pb, 0, pn));
	via_w(vBufB, VIA1[vBufB] & ~TIP);
	if (wait_sr())
		goto timeout;
	if (!(VIA1[vBufB] & TREQ)) {	/* collision: Cuda wins */
		end_transfer();
		return -1;
	}
	for (i = 1; i < n; i++) {
		via_w(vSR, pb_byte(pb, i, pn));
		via_w(vBufB, VIA1[vBufB] ^ TACK);
		if (wait_sr())
			goto timeout;
	}
	end_transfer();
	return 0;
timeout:
	end_transfer();
	return -2;
}

struct rx {
	u8	hdr[3];			/* packet type, flags, command */
	u8	*data;
	int	max;
	int	n;			/* data bytes stored */
};

/*
 * Receive one packet. Cuda starts every transfer with an idle byte that raises
 * the SR interrupt; `primed` says the caller has already read it. Cuda ends a
 * packet by negating TREQ, except for open-ended replies (reading 6805 memory or
 * PRAM), which run until the host stops them: we stop once `data` is full.
 */
static int
cuda_recv(struct rx *rx, int primed)
{
	int i = 0;
	u8 b, c;

	rx->n = 0;
	if (!primed) {
		if (wait_sr())
			return -1;
		(void)VIA1[vSR];
	}
	via_w(vBufB, VIA1[vBufB] & ~TIP);
	for (;;) {
		if (wait_sr())
			break;
		b = VIA1[vBufB];
		c = VIA1[vSR];
		if (i < 3)
			rx->hdr[i] = c;
		else if (rx->n < rx->max)
			rx->data[rx->n++] = c;
		i++;
		if (b & TREQ)		/* TREQ negated: that was the last byte */
			break;
		if (i > 3 && rx->n >= rx->max)
			break;		/* full: end it like Linux does */
		via_w(vBufB, VIA1[vBufB] ^ TACK);
	}
	via_w(vBufB, VIA1[vBufB] | TIP | TACK);
	if (wait_sr() == 0)		/* "read done" interrupt */
		(void)VIA1[vSR];
	return i;
}

/* an unsolicited packet: autopoll ADB data, one-second tick, power key */
static void
cuda_unsolicited(struct rx *rx, int len)
{
	int i, n;

	if (len <= 1 || rx->hdr[0] == PKT_TIMER) {
		onesec();
		return;
	}
	if (rx->hdr[0] == PKT_ADB && fdb_completion) {
		n = rx->n < rx->max ? rx->n : rx->max;
		resprec[0] = n;
		resprec[1] = rx->hdr[0];
		resprec[2] = rx->hdr[1];
		resprec[3] = rx->hdr[2];
		for (i = 0; i < n; i++)
			resprec[4 + i] = rx->data[i];
		fdb_completion(resprec);
	}
	if (rx->hdr[0] == PKT_POWER) {
		keysw_position = rx->hdr[2];
		if (key_completion)
			key_completion();
	}
}

static void
receive_unsolicited(int primed)
{
	struct rx rx;
	u8 buf[16];
	int len;

	if (!ourmac())
		return;
	rx.data = buf;
	rx.max = sizeof buf;
	if ((len = cuda_recv(&rx, primed)) > 0)
		cuda_unsolicited(&rx, len);
}

/* same contract as cEgretDispatch: returns 1 when pbResult is 0 */
int
cuda_dispatch(struct egretpb *pb)
{
	struct rx rx;
	int s, i, r, tries;

	if (!ourmac()) {
		pb->result = -1;
		return 0;
	}
	s = getsr();
	if ((s & 0x700) == 0)
		s = spl1();
	if (valid_packet(pb)) {
		if (pb->type == 0xff)
			fdb_completion = (void (*)(u8 *))pb->completion;
		else if (pb->type == 0xfe)
			key_completion = (void (*)(void))pb->completion;
		else {
			for (tries = 0; (r = cuda_send(pb)) == -1 && tries < 16; tries++)
				receive_unsolicited(0);
			if (r < 0)
				pb->result = -1;
			else {
				/* where the reply data goes, as in A/UX's read_pbdata */
				if (pb->type == 1 && (pb->cmd == 2 || pb->cmd == 7)) {
					rx.data = pb->buf;
					rx.max = pb->count;
				} else if (pb->type == 1) {
					rx.data = pb->param;
					rx.max = 4;
				} else {
					rx.data = pb->buf;
					rx.max = pb->type == 0 ? 8 : 0;
				}
				if (cuda_recv(&rx, 0) < 3)
					pb->result = -1;
				else if (rx.hdr[0] == PKT_ADB) {
					/* as recv_response: resprec copies from pbParam */
					resprec[0] = rx.n;
					resprec[1] = rx.hdr[0];
					resprec[2] = rx.hdr[1];
					resprec[3] = rx.hdr[2];
					for (i = 0; i < rx.n; i++)
						resprec[4 + i] = pb->param[i];
					if (fdb_completion)
						fdb_completion(resprec);
				} else if (rx.hdr[0] == PKT_POWER && key_completion)
					key_completion();
			}
		}
	}
	splx(s);
	return pb->result == 0;
}

/* VIA1 shift register interrupt (installed by egret_init via shift_reg_intr) */
void
cuda_intr(void)
{
	(void)VIA1[vSR];
	if (!(VIA1[vBufB] & TREQ))
		receive_unsolicited(1);
}

/* drain a transfer Cuda has started */
void
cuda_abort(void)
{
	if (!(VIA1[vBufB] & TREQ))
		receive_unsolicited(0);
}

static void
pseudo(int cmd, int arg)
{
	struct egretpb pb;

	pb.type = 1;
	pb.cmd = cmd;
	pb.param[0] = arg;
	pb.count = 0;
	pb.buf = 0;
	pb.flags = 0;
	pb.result = 0;
	pb.completion = 0;
	cuda_dispatch(&pb);
}

/* replaces egret_reset: Cuda VIA sync, then the same setup packets */
void
cuda_reset(void)
{
	if (!ourmac())
		return;
	via_w(vDirB, (VIA1[vDirB] | TACK | TIP) & ~TREQ);
	via_w(vACR, (VIA1[vACR] & ~SR_CTRL) | SR_EXT);
	(void)VIA1[vSR];
	if (!(VIA1[vBufB] & TREQ))
		receive_unsolicited(0);
	via_w(vBufB, VIA1[vBufB] | TIP | TACK);
	egret_delay_us(4000);
	(void)VIA1[vSR];
	via_w(vIFR, SR_INT);

	/* sync: assert TACK alone; Cuda answers with TREQ and an SR interrupt */
	via_w(vBufB, VIA1[vBufB] & ~TACK);
	if (wait_treq(1) == 0 && wait_sr() == 0) {
		(void)VIA1[vSR];
		via_w(vIFR, SR_INT);
	}
	via_w(vBufB, VIA1[vBufB] | TACK);
	if (wait_treq(0) == 0 && wait_sr() == 0) {
		(void)VIA1[vSR];
		via_w(vIFR, SR_INT);
	}

	pseudo(0x1b, 0);		/* one-second interrupts off */
	pseudo(0x01, 0);		/* autopoll off (fdb_init turns it on) */
	pseudo(0x1c, 1);		/* as egret_reset */
	pseudo(0x1b, 3);
}
