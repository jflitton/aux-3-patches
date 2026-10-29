/* SPDX-License-Identifier: MIT */
/*
 * DaynaPORT SCSI/Link network interface (dp0) for A/UX 3.x, written for the DaynaPORT
 * that BlueSCSI V2 emulates over Wi-Fi. A port of Jeff Flitton's Linux driver
 * (github.com/jflitton/daynaport-scsilink-linux-driver): daynaport.h is its protocol
 * core, unchanged, and the receive policy is its own.
 *
 * A boot.d module (src/master: software module, init routine daynainit at
 * init-last, i.e. interrupts on and process 0 free to sleep). daynainit finds the
 * adapter (in the kernel's boot scan if it can, else by INQUIRY), enables it, reads its
 * MAC and attaches dp0; /etc/startup.d/dayna configures it from /etc/NETADDRS.
 *
 * The adapter has no interrupt, so receiving is polled with READ(6), one command at a
 * time, sharing the target with WRITE(6) for sending:
 *   - a READ that brought frames is followed at once by another (a download runs at
 *     the speed of the SCSI round trip);
 *   - an empty one by a poll after dayna_poll0 ticks while frames to us have been
 *     arriving (for dayna_fast_hold polls), else after dayna_poll ticks;
 *   - queued frames go first, but a due READ goes before a second WRITE in a row.
 * All SCSI work happens in dp_run, from softcall (softint, IPL 0): the SCSI Manager's
 * completion routine and the poll timeout only set flags and softcall it, so it never
 * runs inside the manager's interrupt path and never lowers a raised IPL.
 *
 * Reads are variable length, so the adapter's ID is set to SDC_RDPOLL: the 53C96 driver
 * would otherwise read whole multiples of 256 bytes blind (c94_in) and wait for bytes a
 * short response never sends. Writes are exact, so they keep the blind transfers.
 */
#include "aux.h"
#include "daynaport.h"

#define DAYNA_VERSION	"0.2"
#define NTARGET		7		/* targets 0-6; 7 is the Mac */
#define RX_REQ		4096		/* READ(6) length: room for BlueSCSI's 2-frame batch */
#define RBUF_LEN	(RX_REQ + SCSILINK_RX_HDR)	/* + a zeroed header to end the walk */
#define CMD_TIMEOUT	5		/* seconds */
#define SCSI_INQUIRY	0x12
#define INQ_LEN		36
#define NBPG		4096

/* Receive cadence (the Linux driver's poll_ms=80, poll0_ms=20, fast_hold=16), in
 * clock ticks; global so they can be patched in /unix. dayna_debug: a line about the
 * reads every 256 of them. */
int dayna_poll = 80 * HZ / 1000;
int dayna_poll0 = 20 * HZ / 1000 ? 20 * HZ / 1000 : 1;
int dayna_fast_hold = 16;
int dayna_debug;

struct dp_softc {
	struct arpcom ac;		/* first: the stack's ifnet * is our softc */
	int	id;			/* (bus << 8) | target, for scsireq */
	int	busy;			/* a command is with the SCSI Manager ... */
	volatile int done;		/* ... and has completed */
	int	sending;		/* it is (or the last one was) a WRITE */
	int	rx_due;			/* READ as soon as the target is free */
	int	timer;			/* a poll timeout is pending */
	int	fast_left;		/* daynaport_poll_fast()'s hold counter */
	int	errs;			/* failed commands in a row */
	caddr_t	rbuf_pa, tbuf_pa, sense_pa;
	struct scsireq req;
	unsigned char cdb[6];
	/* dayna_debug */
	int	d_reads, d_empty, d_frames;
	long	d_t0;
};

static struct dp_softc dp_softc;
static unsigned char rbuf[RBUF_LEN] __attribute__((aligned(16)));
static unsigned char tbuf[SCSILINK_MAXFRAME] __attribute__((aligned(16)));
static unsigned char sense[32] __attribute__((aligned(16)));

static void dp_run(void *arg);

static const char *sst(int rc)
{
	return rc > 0 && rc <= SST_CANCEL ? scsi_strings[rc] : "?";
}

/* hex digits of v, most significant first (the kernel's printf has no field widths) */
static char *hex(char *p, unsigned v, int digits)
{
	while (digits--)
		*p++ = "0123456789abcdef"[(v >> (4 * digits)) & 15];
	*p = 0;
	return p;
}

static char *mac(char *p, const unsigned char *a)
{
	int i;

	for (i = 0; i < 6; i++) {
		p = hex(p, a[i], 2);
		if (i < 5)
			*p++ = ':';
	}
	*p = 0;
	return p;
}

/* INQUIRY strings: trailing blanks dropped */
static void inqstr(char *out, const unsigned char *in, int n)
{
	while (n > 0 && (in[n - 1] == ' ' || in[n - 1] == 0))
		n--;
	bcopy(in, out, n);
	out[n] = 0;
}

static int is_dayna(const unsigned char *inq)
{
	return (inq[0] & 0x1f) == 3 &&
	       bcmp(inq + 8, SCSILINK_VENDOR, sizeof(SCSILINK_VENDOR) - 1) == 0 &&
	       bcmp(inq + 16, SCSILINK_MODEL, sizeof(SCSILINK_MODEL) - 1) == 0;
}

/* Is the kernel virtual range physically contiguous (the manager takes one address)? */
static int contig(unsigned char *va, int len)
{
	caddr_t pa = realvtop(RV_KDATA, va);
	int off;

	for (off = NBPG - ((unsigned long)va & (NBPG - 1)); off < len; off += NBPG)
		if (realvtop(RV_KDATA, va + off) != pa + off)
			return 0;
	return 1;
}

static void dp_setup(struct dp_softc *sc, caddr_t pa, int len, int read,
		     int (*done)(struct scsireq *))
{
	struct scsireq *r = &sc->req;

	r->cmdbuf = (caddr_t)sc->cdb;
	r->cmdlen = 6;
	r->databuf = len ? pa : 0;
	r->datalen = len;
	r->datasent = 0;
	r->sensebuf = sc->sense_pa;
	r->senselen = sizeof(sense);
	r->sensesent = 0;
	r->faddr = done;
	r->flags = read ? SRQ_READ : 0;
	r->timeout = CMD_TIMEOUT;
}

/*
 * Attach time: run the command in sc->cdb on target id and sleep until it completes
 * (process context only). Returns the SST_* result, 0 for good.
 */
static int dp_wakeup(struct scsireq *r)
{
	dp_softc.done = 1;
	wakeup(r);
	return 0;
}

static int dp_wait(struct dp_softc *sc, int id, caddr_t pa, int len, int read)
{
	int s, rc;

	dp_setup(sc, pa, len, read, dp_wakeup);
	s = spl2();
	sc->done = 0;
	rc = scsireq(id, &sc->req, 0);
	if (rc == 0) {
		while (!sc->done)
			sleep(&sc->req, PRIBIO);
		rc = sc->req.ret;
	}
	splx(s);
	return rc;
}

/* Running: issue the command in sc->cdb; dp_intr hands its completion to dp_run. */
static int dp_intr(struct scsireq *r)
{
	dp_softc.done = 1;
	softcall(dp_run, &dp_softc);
	return 0;
}

static void dp_issue(struct dp_softc *sc, caddr_t pa, int len, int read)
{
	int s, rc;

	dp_setup(sc, pa, len, read, dp_intr);
	sc->busy = 1;
	sc->done = 0;
	s = spl2();
	rc = scsireq(sc->id, &sc->req, 0);
	splx(s);
	if (rc != 0) {			/* refused: no completion will come */
		sc->req.ret = rc;
		sc->done = 1;
	}
}

static void dp_error(struct dp_softc *sc, const char *what)
{
	if (sc->errs++ % 64 == 0)
		printf("dp0: %s failed: %s, status %d (%d in a row)\n", what, sst(sc->req.ret),
		       sc->req.stat, sc->errs);
}

/* --- receive --- */

/* MCLGET (sys/mbuf.h): give m a cluster; 0 if none */
static int mclget(struct mbuf *m)
{
	struct mbuf *p;
	int s = splimp();

	if (mclfree == 0)
		m_clalloc(1, MPG_CLUSTERS, M_DONTWAIT);
	if ((p = mclfree) != 0) {
		++mclrefcnt[((char *)p - (char *)mbufclusterstart) / MCLBYTES];
		mbstat.m_clfree--;
		mclfree = p->m_next;
	}
	splx(s);
	if (p == 0)
		return 0;
	m->m_off = (char *)p - (char *)m;
	m->m_cltype = MCL_STATIC;
	return 1;
}

/* Copy len bytes into an mbuf chain led by the receiving ifnet *, as ipintr and
 * arpinput expect (IF_DEQUEUEIF, IF_ADJ). */
static struct mbuf *dp_get(const unsigned char *p, int len, struct ifnet *ifp)
{
	struct mbuf *top = 0, **mp = &top, *m;
	int hdr = sizeof(struct ifnet *), room, n;

	while (len > 0) {
		m = m_get(M_DONTWAIT, MT_DATA);
		if (m == 0) {
			m_freem(top);
			return 0;
		}
		room = hdr + len > MLEN && mclget(m) ? MCLBYTES : MLEN;
		if (hdr)
			*mtod(m, struct ifnet **) = ifp;
		n = len < room - hdr ? len : room - hdr;
		bcopy(p, mtod(m, unsigned char *) + hdr, n);
		m->m_len = hdr + n;
		hdr = 0;
		p += n;
		len -= n;
		*mp = m;
		mp = &m->m_next;
	}
	return top;
}

/* daynaport_rx_parse() callback: one frame, FCS stripped */
static void dp_deliver(void *ctx, const unsigned char *frame, int len)
{
	struct dp_softc *sc = ctx;
	struct ifnet *ifp = &sc->ac.ac_if;
	struct mbuf *m;
	int type = (frame[12] << 8) | frame[13], s;

	ifp->if_ipackets++;
	if ((type != ETHERTYPE_IP && type != ETHERTYPE_ARP) || ifp->if_addrlist == 0)
		return;
	m = dp_get(frame + ETHER_HDR, len - ETHER_HDR, ifp);
	if (m == 0) {
		ifp->if_ierrors++;
		return;
	}
	if (type == ETHERTYPE_ARP) {
		arpinput(&sc->ac, m);
		return;
	}
	s = splimp();
	if (IF_QFULL(&ipintrq)) {
		IF_DROP(&ipintrq);
		splx(s);
		m_freem(m);
		return;
	}
	IF_ENQUEUE(&ipintrq, m);
	splx(s);
	softcall((void (*)(void *))ipintr, 0);
}

static void dp_poll(void *arg)
{
	struct dp_softc *sc = arg;

	sc->timer = 0;
	sc->rx_due = 1;
	dp_run(sc);
}

static void dp_tick(void *arg)
{
	softcall(dp_poll, arg);
}

static void dp_settimer(struct dp_softc *sc, int ticks)
{
	if (!sc->timer) {
		sc->timer = 1;
		timeout(dp_tick, sc, ticks);
	}
}

static void dp_recv(struct dp_softc *sc)
{
	sc->rx_due = 0;
	sc->sending = 0;
	bzero(rbuf, RBUF_LEN);
	daynaport_cdb6(sc->cdb, SCSILINK_CMD_RECV, RX_REQ, SCSILINK_RECV_FLAG);
	dp_issue(sc, sc->rbuf_pa, RX_REQ, 1);
}

static void dp_recvdone(struct dp_softc *sc)
{
	struct ifnet *ifp = &sc->ac.ac_if;
	int rc = sc->req.ret, got, ucast = 0, errors = 0, fast;

	if (rc != 0 && rc != SST_LESS) {
		ifp->if_ierrors++;
		dp_error(sc, "read");
		dp_settimer(sc, dayna_poll);
		return;
	}
	sc->errs = 0;
	got = daynaport_rx_parse(rbuf, RBUF_LEN, dp_deliver, sc, &errors, &ucast);
	ifp->if_ierrors += errors;
	fast = daynaport_poll_fast(ucast, &sc->fast_left, dayna_fast_hold);
	if (got)
		sc->rx_due = 1;
	else
		dp_settimer(sc, fast ? dayna_poll0 : dayna_poll);

	if (dayna_debug) {
		if (sc->d_reads == 0)
			sc->d_t0 = lbolt;
		sc->d_reads++;
		sc->d_frames += got;
		if (got == 0)
			sc->d_empty++;
		if (sc->d_reads == 256) {
			printf("dp0: 256 reads in %d ticks, %d empty, %d frames\n",
			       (int)(lbolt - sc->d_t0), sc->d_empty, sc->d_frames);
			sc->d_reads = sc->d_empty = sc->d_frames = 0;
		}
	}
}

/* --- send --- */

static void dp_send(struct dp_softc *sc, struct mbuf *m0)
{
	struct ifnet *ifp = &sc->ac.ac_if;
	struct mbuf *m;
	int len = 0;

	for (m = m0; m; m = m->m_next) {
		if (len + m->m_len > SCSILINK_MAXFRAME)
			break;
		bcopy(mtod(m, unsigned char *), tbuf + len, m->m_len);
		len += m->m_len;
	}
	m_freem(m0);
	if (m) {			/* longer than a frame: the stack keeps to the MTU */
		ifp->if_oerrors++;
		return;
	}
	if (len < SCSILINK_MINFRAME) {
		bzero(tbuf + len, SCSILINK_MINFRAME - len);
		len = SCSILINK_MINFRAME;
	}
	sc->sending = 1;
	daynaport_cdb6(sc->cdb, SCSILINK_CMD_SEND, len, SCSILINK_SEND_FLAG);
	dp_issue(sc, sc->tbuf_pa, len, 0);
}

static void dp_senddone(struct dp_softc *sc)
{
	if (sc->req.ret != 0) {
		sc->ac.ac_if.if_oerrors++;
		dp_error(sc, "write");
		return;
	}
	sc->errs = 0;
	sc->ac.ac_if.if_opackets++;
}

/* The one place commands are issued (softint). */
static void dp_run(void *arg)
{
	struct dp_softc *sc = arg;
	struct ifnet *ifp = &sc->ac.ac_if;
	struct mbuf *m;
	int s;

	for (;;) {
		if (sc->busy) {
			if (!sc->done)
				return;
			sc->busy = 0;
			if (sc->sending)
				dp_senddone(sc);
			else
				dp_recvdone(sc);
		}
		if (!(ifp->if_flags & IFF_RUNNING))
			return;
		m = 0;
		if (!sc->rx_due || !sc->sending) {
			s = splimp();
			IF_DEQUEUE(&ifp->if_snd, m);
			splx(s);
		}
		if (m)
			dp_send(sc, m);
		else if (sc->rx_due)
			dp_recv(sc);
		else
			return;
	}
}

/* --- the interface --- */

static void dp_start(void *arg)
{
	struct dp_softc *sc = arg;

	sc->fast_left = 0;
	sc->rx_due = 1;
	dp_run(sc);
}

static int dp_init(int unit)
{
	struct ifnet *ifp = &dp_softc.ac.ac_if;
	int s = splimp();

	if (!(ifp->if_flags & IFF_RUNNING)) {
		ifp->if_flags |= IFF_RUNNING;
		softcall(dp_start, &dp_softc);
	}
	splx(s);
	return 0;
}

static int dp_output(struct ifnet *ifp, struct mbuf *m0, struct sockaddr *dst)
{
	struct dp_softc *sc = (struct dp_softc *)ifp;
	struct mbuf *m = m0, *mcopy = 0;
	struct in_addr idst;
	unsigned char edst[6], *eh;
	int type, usetrailers, s, error;

	if ((ifp->if_flags & (IFF_UP | IFF_RUNNING)) != (IFF_UP | IFF_RUNNING)) {
		error = ENETDOWN;
		goto bad;
	}
	switch (dst->sa_family) {
	case AF_INET:
		idst = ((struct sockaddr_in *)dst)->sin_addr;
		if (!arpresolve(&sc->ac, m, &idst, edst, &usetrailers))
			return 0;	/* held until ARP answers */
		if (bcmp(edst, etherbroadcastaddr, sizeof(edst)) == 0)
			mcopy = m_copy(m, 0, M_COPYALL);	/* we hear our broadcasts */
		type = ETHERTYPE_IP;
		break;
	case AF_UNSPEC:			/* arpwhohas: dst holds an ether_header */
		bcopy(dst->sa_data, edst, sizeof(edst));
		type = ((unsigned char)dst->sa_data[12] << 8) | (unsigned char)dst->sa_data[13];
		break;
	default:
		printf("dp0: can't handle af%d\n", dst->sa_family);
		error = EAFNOSUPPORT;
		goto bad;
	}

	if (m->m_off > MMAXOFF || m->m_off < MMINOFF + ETHER_HDR) {
		m = m_get(M_DONTWAIT, MT_HEADER);
		if (m == 0) {
			m = m0;
			error = ENOBUFS;
			goto bad;
		}
		m->m_next = m0;
		m->m_off = MMINOFF;
		m->m_len = ETHER_HDR;
	} else {
		m->m_off -= ETHER_HDR;
		m->m_len += ETHER_HDR;
	}
	eh = mtod(m, unsigned char *);
	bcopy(edst, eh, 6);
	bcopy(sc->ac.ac_enaddr, eh + 6, 6);
	eh[12] = type >> 8;
	eh[13] = type;

	s = splimp();
	if (IF_QFULL(&ifp->if_snd)) {
		IF_DROP(&ifp->if_snd);
		splx(s);
		error = ENOBUFS;
		goto bad;
	}
	IF_ENQUEUE(&ifp->if_snd, m);
	splx(s);
	softcall(dp_run, sc);
	if (mcopy)
		looutput(&loif, mcopy, dst);
	return 0;

bad:
	m_freem(m);
	if (mcopy)
		m_freem(mcopy);
	return error;
}

static int dp_ioctl(struct ifnet *ifp, int cmd, caddr_t data)
{
	struct dp_softc *sc = (struct dp_softc *)ifp;
	struct ifaddr *ifa = (struct ifaddr *)data;
	int s = splimp(), error = 0;

	switch (cmd) {
	case SIOCSIFADDR:
		ifp->if_flags |= IFF_UP;
		dp_init(ifp->if_unit);
		if (ifa->ifa_addr.sa_family == AF_INET) {
			struct sockaddr_in *sin = (struct sockaddr_in *)&ifa->ifa_addr;

			sc->ac.ac_ipaddr = sin->sin_addr;
			arpwhohas(&sc->ac, &sin->sin_addr);
		}
		break;
	case SIOCSIFFLAGS:
		if (!(ifp->if_flags & IFF_UP))
			ifp->if_flags &= ~IFF_RUNNING;	/* dp_run stops polling */
		else
			dp_init(ifp->if_unit);
		break;
	default:
		error = EINVAL;
	}
	splx(s);
	return error;
}

/* --- attach --- */

/* The adapter in ss_init's INQUIRY replies, as an id; -1 if not there, -2 if this
 * kernel's ss_init is not the one we know. */
static int dp_find_boot(void)
{
	static const unsigned char load[] = {
		0x4c, 0x3c, 0x08, 0x00, 0x00, 0x00, 0x05, 0x36,	/* muls.l #SS_BUSLEN,d0 */
		0x20, 0x7c					/* movea.l #ss_context,a0 */
	};
	const unsigned char *code = (const unsigned char *)ss_init + SS_CONTEXT_AT - 8;
	const unsigned char *ctx, *bus;
	int b, t, busno;

	if (bcmp(code, load, sizeof(load)) != 0)
		return -2;
	ctx = (const unsigned char *)((unsigned long)code[10] << 24 | code[11] << 16 |
				      code[12] << 8 | code[13]);
	for (b = 0; b < SS_NBUS; b++) {
		bus = ctx + b * SS_BUSLEN;
		busno = bus[0] << 8 | bus[1];
		if (busno == 0)
			break;
		for (t = 0; t < NTARGET; t++)
			if (is_dayna(bus + SS_INQ + t * INQ_LEN))
				return busno << 8 | t;
	}
	return -1;
}

/* INQUIRY id; 1 if it is a DaynaPORT (its INQUIRY data left in rbuf) */
static int dp_inquire(struct dp_softc *sc, int id)
{
	int rc;

	bzero(rbuf, INQ_LEN);
	daynaport_cdb6(sc->cdb, SCSI_INQUIRY, INQ_LEN, 0);
	rc = dp_wait(sc, id, sc->rbuf_pa, INQ_LEN, 1);
	return (rc == 0 || rc == SST_LESS) && is_dayna(rbuf);
}

static int dp_find(struct dp_softc *sc)
{
	int id, t;

	id = dp_find_boot();
	if (id >= 0 && dp_inquire(sc, id))
		return id;
	printf("dayna: %s, scanning\n", id == -2 ? "unknown ss_init" :
	       id == -1 ? "not in the boot scan" : "not where the boot scan saw it");
	for (t = 0; t < NTARGET; t++)	/* bus 0: the manager tries each bus */
		if (dp_inquire(sc, t))
			return t;
	return -1;
}

void daynainit(void)
{
	struct dp_softc *sc = &dp_softc;
	struct ifnet *ifp = &sc->ac.ac_if;
	char product[17], rev[5], ea[18];
	int id, rc;

	printf("dayna: DaynaPORT driver %s\n", DAYNA_VERSION);
	if (!contig(rbuf, RBUF_LEN) || !contig(tbuf, sizeof(tbuf)) ||
	    !contig(sense, sizeof(sense))) {
		printf("dayna: buffers not physically contiguous\n");
		return;
	}
	sc->rbuf_pa = realvtop(RV_KDATA, rbuf);
	sc->tbuf_pa = realvtop(RV_KDATA, tbuf);
	sc->sense_pa = realvtop(RV_KDATA, sense);

	id = dp_find(sc);
	if (id < 0) {
		printf("dayna: no DaynaPORT found\n");
		return;
	}
	inqstr(product, rbuf + 16, 16);
	inqstr(rev, rbuf + 32, 4);
	scsichar(id, SDC_RDPOLL, SDC_RDPOLL);

	daynaport_cdb6(sc->cdb, SCSILINK_CMD_ENABLE, 0, SCSILINK_ENABLE_FLAG);
	rc = dp_wait(sc, id, 0, 0, 0);
	if (rc != 0)
		printf("dayna: enable: %s, status %d\n", sst(rc), sc->req.stat);
	delay(HZ / 2);
	daynaport_cdb6(sc->cdb, SCSILINK_CMD_STATS, SCSILINK_STATS_LEN, 0);
	rc = dp_wait(sc, id, sc->rbuf_pa, SCSILINK_STATS_LEN, 1);
	if (rc != 0 && rc != SST_LESS) {
		printf("dayna: reading the MAC: %s, status %d\n", sst(rc), sc->req.stat);
		return;
	}
	bcopy(rbuf, sc->ac.ac_enaddr, 6);

	sc->id = id;
	ifp->if_name = "dp";
	ifp->if_unit = 0;
	ifp->if_mtu = ETHERMTU;
	ifp->if_flags = IFF_BROADCAST | IFF_NOTRAILERS;
	ifp->if_snd.ifq_maxlen = IFQ_MAXLEN;
	ifp->if_init = dp_init;
	ifp->if_output = dp_output;
	ifp->if_ioctl = dp_ioctl;
	if_attach(ifp);
	mac(ea, sc->ac.ac_enaddr);
	printf("dp0: %s %s at SCSI bus %d id %d, address %s\n", product, rev, id >> 8,
	       id & 0xff, ea);
}
