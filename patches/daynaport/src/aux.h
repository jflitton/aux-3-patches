/*
 * aux.h - the parts of the A/UX 3.x kernel interface the DaynaPORT module uses.
 *
 * The module is built with GCC, not A/UX's cc, so these are declared here to match the
 * layouts in A/UX's <sys/scsireq.h> and <sys/vio.h>; the asserts at the end pin the
 * offsets the kernel relies on. Calling convention: arguments on the stack, result in
 * d0 (A/UX also copies pointer results to d0), d0-d1/a0-a1 scratch, as GCC's m68k-elf.
 * Kernel symbols the module refers to must be global in /unix (tools/elf2coff.py undef).
 */
#ifndef AUX_H
#define AUX_H

typedef char *caddr_t;

#define HZ		60	/* clock ticks per second (sys/param.h) */
#define PRIBIO		20	/* sleep priority, not interruptible by signals */

/*
 * The SCSI Manager. scsireq(id, req, 0) queues the request (behind any other request
 * for the same target) and returns 0 at once; when it completes the manager calls
 * req->faddr(req) from its interrupt path. id is (bus << 8) | target, bus 0 being the
 * built-in bus. With vio 0 the manager transfers datalen bytes at databuf, which (like
 * sensebuf) is a physical address: realvtop(RV_KDATA, va).
 */
#define MAXVIO		34

struct iov {
	caddr_t	vio_base;
	int	vio_len;
	char	vio_flags;
};

struct vio {
	short	vio_niov;
	short	vio_ngdiskbp;
	int	vio_tot;
	struct iov vio_iov[MAXVIO];
	void	*vio_gdiskbp[MAXVIO];
};

struct scsireq {
	caddr_t	cmdbuf;			/* command block (kernel virtual) */
	caddr_t	databuf;		/* data buffer (physical) */
	unsigned datalen;		/* bytes to transfer */
	unsigned datasent;		/* bytes actually transferred */
	caddr_t	sensebuf;		/* sense buffer (physical) or 0 */
	int	(*faddr)(struct scsireq *);	/* completion routine */
	long	driver;			/* ours */
	struct scsireq *link;		/* the manager's queue */
	unsigned short flags;		/* SRQ_* */
	unsigned char cmdlen;
	unsigned char senselen;
	unsigned char sensesent;
	unsigned char msg;
	unsigned char stat;		/* SCSI status byte */
	unsigned char ret;		/* SST_* result */
	unsigned char reserve1;
	short	timeout;		/* seconds; 0 = one per KB of datalen, plus one */
	char	revcode[4];		/* left zero, as devscsi does */
	struct vio vio;
	int	niovsent;
};

#define SRQ_READ	0x01		/* data in */

#define SST_SEL		5		/* no unit responded to selection */
#define SST_TIMEOUT	6
#define SST_MORE	9		/* more data than the device expected */
#define SST_LESS	10		/* less data than requested */
#define SST_STAT	11		/* non-zero status; sense fetched if senselen */
#define SST_CANCEL	14

#define SDC_RDPOLL	2		/* scsichar(): poll each data-in byte, no blind loop */
#define SDC_WRPOLL	4		/* same for data out */

int	scsireq(int id, struct scsireq *req, struct vio *vio);
int	scsichar(int id, int value, int mask);
extern char *scsi_strings[];		/* indexed by SST_* */

#define RV_KDATA	5		/* realvtop space for kernel data, as devscsi uses */
caddr_t	realvtop(int space, void *va);	/* physical address, or (caddr_t)-1 */

/*
 * The boot-time bus scan (ss_init) keeps each target's INQUIRY reply in the static
 * ss_context; ss_init loads its address with movea.l #ss_context,a0 at SS_CONTEXT_AT.
 * Per bus (at most SS_NBUS, SS_BUSLEN bytes apart): a short bus number (scsitab index,
 * 0 for an unused entry), a short, then 36 bytes of INQUIRY data for targets 0-6 (type
 * byte 0xff where nothing answered).
 */
void	ss_init(void);
#define SS_CONTEXT_AT	0xd4
#define SS_NBUS		4
#define SS_BUSLEN	0x536
#define SS_INQ		4

/* kernel services */
int	printf(const char *fmt, ...);
int	sleep(void *chan, int pri);
void	wakeup(void *chan);
void	delay(int ticks);		/* sleeps */
int	spl2(void);
int	splimp(void);			/* spl6, as splnet */
int	splx(int s);
void	bcopy(const void *from, void *to, unsigned n);
void	bzero(void *p, unsigned n);
int	bcmp(const void *a, const void *b, unsigned n);
extern long lbolt;			/* clock ticks since boot */

/*
 * softcall(f, a) runs f(a) from softint at IPL 0 once the processor next returns to IPL
 * 0 (a pending f, a pair is not queued twice). timeout(f, a, ticks) runs f(a) from the
 * clock at spl5 (4.3BSD callouts: untimeout(f, a) cancels).
 */
void	softcall(void (*f)(void *), void *a);
void	timeout(void (*f)(void *), void *a, int ticks);
void	untimeout(void (*f)(void *), void *a);

/*
 * Networking: 4.3BSD-Tahoe (net/if.h, netinet/if_ether.h, sys/mbuf.h). The m68k ABI
 * aligns ints and pointers to 2 bytes, as A/UX's cc does, hence arpcom's ac_ipaddr at 0x5a.
 */
#define EINVAL		22
#define EAFNOSUPPORT	67
#define ENETDOWN	70
#define ENOBUFS		75

#define AF_UNSPEC	0
#define AF_INET		2

struct sockaddr {
	unsigned short sa_family;
	char	sa_data[14];
};

struct in_addr {
	unsigned long s_addr;
};

struct sockaddr_in {
	short	sin_family;
	unsigned short sin_port;
	struct in_addr sin_addr;
	char	sin_zero[8];
};

#define MSIZE		128
#define MMINOFF		12		/* header */
#define MTAIL		4		/* m_act */
#define MMAXOFF		(MSIZE - MTAIL)
#define MLEN		(MSIZE - MMINOFF - MTAIL)	/* 112 data bytes */
#define MCLBYTES	1024
#define MT_DATA		1
#define MT_HEADER	2
#define MCL_STATIC	1
#define M_DONTWAIT	0
#define MPG_CLUSTERS	1
#define M_COPYALL	1000000000

struct mbuf {
	struct mbuf *m_next;
	unsigned long m_off;		/* data at (char *)m + m_off; >= MSIZE: a cluster */
	short	m_len;
	short	m_type;
	union {
		unsigned char mun_dat[MLEN];
		struct {
			short	mun_cltype;
			int	(*mun_clfun)(void);
			int	mun_clarg;
			int	(*mun_clswp)(void);
		} mun_cl;
	} m_un;
	struct mbuf *m_act;		/* next packet on a queue */
};
#define m_cltype	m_un.mun_cl.mun_cltype
#define mtod(m, t)	((t)((char *)(m) + (m)->m_off))

struct mbstat {
	unsigned long m_mbufs, m_clusters, m_space, m_clfree, m_drops, m_wait, m_drain;
	unsigned short m_mtypes[256];
};

struct mbuf *m_get(int canwait, int type);
struct mbuf *m_copy(struct mbuf *m, int off, int len);
void	m_freem(struct mbuf *m);
caddr_t	m_clalloc(int ncl, int how, int canwait);
/* the cluster free list, for MCLGET (sys/mbuf.h's macro; the kernel has no function) */
extern struct mbuf *mclfree;
extern char mclrefcnt[];
extern struct mbstat mbstat;
extern struct mbuf *mbufclusterstart;

struct ifqueue {
	struct mbuf *ifq_head;
	struct mbuf *ifq_tail;
	int	ifq_len;
	int	ifq_maxlen;
	int	ifq_drops;
};
#define IFQ_MAXLEN	50

struct ifnet;

struct ifaddr {
	struct sockaddr ifa_addr;
	struct sockaddr ifa_broadaddr;
	struct ifnet *ifa_ifp;
	struct ifaddr *ifa_next;
};

struct ifnet {
	char	*if_name;
	short	if_unit;
	short	if_mtu;
	short	if_flags;
	short	if_timer;
	int	if_metric;
	struct ifaddr *if_addrlist;
	struct ifqueue if_snd;
	int	(*if_init)(int unit);
	int	(*if_output)(struct ifnet *ifp, struct mbuf *m, struct sockaddr *dst);
	int	(*if_ioctl)(struct ifnet *ifp, int cmd, caddr_t data);
	int	(*if_reset)(int unit);
	int	(*if_watchdog)(int unit);
	int	if_ipackets;
	int	if_ierrors;
	int	if_opackets;
	int	if_oerrors;
	int	if_collisions;
	struct ifnet *if_next;
};
#define IFF_UP		0x1
#define IFF_BROADCAST	0x2
#define IFF_NOTRAILERS	0x20
#define IFF_RUNNING	0x40

/* ifq_* under splimp, as net/if.h's macros */
#define IF_QFULL(q)	((q)->ifq_len >= (q)->ifq_maxlen)
#define IF_DROP(q)	((q)->ifq_drops++)
#define IF_ENQUEUE(q, m) do { \
	(m)->m_act = 0; \
	if ((q)->ifq_tail == 0) \
		(q)->ifq_head = (m); \
	else \
		(q)->ifq_tail->m_act = (m); \
	(q)->ifq_tail = (m); \
	(q)->ifq_len++; \
} while (0)
#define IF_DEQUEUE(q, m) do { \
	(m) = (q)->ifq_head; \
	if (m) { \
		if (((q)->ifq_head = (m)->m_act) == 0) \
			(q)->ifq_tail = 0; \
		(m)->m_act = 0; \
		(q)->ifq_len--; \
	} \
} while (0)

/* sys/ioctl.h: _IOW('i', n, struct ifreq) */
#define SIOCSIFADDR	0x8020690c
#define SIOCSIFFLAGS	0x80206910

#define ETHERTYPE_IP	0x0800
#define ETHERTYPE_ARP	0x0806
#define ETHERMTU	1500
#define ETHER_HDR	14

struct arpcom {
	struct ifnet ac_if;
	unsigned char ac_enaddr[6];
	struct in_addr ac_ipaddr;
	void	*ac_multiaddrs;
};

void	if_attach(struct ifnet *ifp);
/* 1 with desten filled in; 0 when m is held for (or freed by) ARP */
int	arpresolve(struct arpcom *ac, struct mbuf *m, struct in_addr *destip,
		   unsigned char *desten, int *usetrailers);
void	arpinput(struct arpcom *ac, struct mbuf *m);	/* m starts with the ifnet * */
void	arpwhohas(struct arpcom *ac, struct in_addr *addr);
int	looutput(struct ifnet *ifp, struct mbuf *m, struct sockaddr *dst);
void	ipintr(void);
extern struct ifqueue ipintrq;		/* packets start with the receiving ifnet * */
extern struct ifnet loif;
extern unsigned char etherbroadcastaddr[6];

#define AUX_OFFSET(t, f, off) \
	_Static_assert(__builtin_offsetof(struct t, f) == (off), #t "." #f)
AUX_OFFSET(scsireq, faddr, 0x14);
AUX_OFFSET(scsireq, flags, 0x20);
AUX_OFFSET(scsireq, cmdlen, 0x22);
AUX_OFFSET(scsireq, ret, 0x27);
AUX_OFFSET(scsireq, timeout, 0x2a);
AUX_OFFSET(scsireq, vio, 0x30);
_Static_assert(sizeof(struct scsireq) == 0x218, "scsireq size");	/* devscsi's stride */
AUX_OFFSET(mbuf, m_act, 0x7c);
_Static_assert(sizeof(struct mbuf) == MSIZE, "mbuf size");
AUX_OFFSET(mbstat, m_clfree, 0xc);
_Static_assert(sizeof(struct mbstat) == 0x21c, "mbstat size");
AUX_OFFSET(ifnet, if_addrlist, 0x10);
AUX_OFFSET(ifnet, if_snd, 0x14);
AUX_OFFSET(ifnet, if_output, 0x2c);
AUX_OFFSET(ifnet, if_ioctl, 0x30);
AUX_OFFSET(ifnet, if_ipackets, 0x3c);
_Static_assert(sizeof(struct ifnet) == 0x54, "ifnet size");
AUX_OFFSET(arpcom, ac_enaddr, 0x54);
AUX_OFFSET(arpcom, ac_ipaddr, 0x5a);

#endif /* AUX_H */
