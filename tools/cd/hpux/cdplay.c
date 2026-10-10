/* cdplay -- play an audio CD on HP-UX 10.20 through the SCSI pass-through
 * (SIOC_IO on the CD's raw device). K&R C: the bundled cc compiles it.
 *   cc -o cdplay cdplay.c
 *   cdplay /dev/rdsk/c2t2d0 toc | status | play T1 [T2] | msf M:S:F M:S:F
 *                           | pause | resume | stop | volume N (0-255) | sense
 * (sense: MODE SENSE page 0x0E, the ports' channels and volumes)
 */
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/scsi.h>

static int fd;

static int cmd(cdb, n, buf, len, rd)
unsigned char *cdb; int n; unsigned char *buf; int len, rd;
{
	struct sctl_io s;
	memset((char *)&s, 0, sizeof(s));
	s.flags = rd ? SCTL_READ : 0;
	s.cdb_length = n;
	memcpy((char *)s.cdb, (char *)cdb, n);
	s.data = (void *)buf;
	s.data_length = len;
	s.max_msecs = 10000;
	if (ioctl(fd, SIOC_IO, &s) < 0) { perror("SIOC_IO"); return -1; }
	if (s.cdb_status != 0) {
		printf("status %x, sense key %x asc %x\n", s.cdb_status, s.sense[2] & 15, s.sense[12]);
		return -1;
	}
	return s.data_xfer;
}

static int toc(show)
int show;
{
	unsigned char c[10], b[804];
	int n, i;
	memset((char *)c, 0, 10);
	c[0] = 0x43; c[1] = 2; c[7] = 804 >> 8; c[8] = 804 & 255;
	if ((n = cmd(c, 10, b, 804, 1)) < 4) return -1;
	if (show) {
		printf("tracks %d-%d\n", b[2], b[3]);
		for (i = 4; i + 8 <= n && i < ((b[0] << 8 | b[1]) + 2); i += 8)
			printf("  track %3d %s  %02d:%02d:%02d\n", b[i + 2],
			       (b[i + 1] & 4) ? "data " : "audio", b[i + 5], b[i + 6], b[i + 7]);
	}
	return b[3];
}

int main(argc, argv)
int argc; char **argv;
{
	unsigned char c[12], b[64];
	int m0, s0, f0, m1, s1, f1, t1, t2;
	if (argc < 3) { printf("usage: cdplay dev toc|status|play T1 [T2]|msf M:S:F M:S:F|pause|resume|stop|volume N|sense\n"); return 1; }
	if ((fd = open(argv[1], O_RDONLY)) < 0) { perror(argv[1]); return 1; }
	memset((char *)c, 0, 12);
	if (!strcmp(argv[2], "toc")) return toc(1) < 0;
	if (!strcmp(argv[2], "status")) {
		c[0] = 0x42; c[1] = 2; c[2] = 0x40; c[3] = 1; c[8] = 16;
		if (cmd(c, 10, b, 16, 1) < 16) return 1;
		printf("audio status %02x  track %d  at %02d:%02d:%02d  (in track %02d:%02d:%02d)\n",
		       b[1], b[6], b[9], b[10], b[11], b[13], b[14], b[15]);
		return 0;
	}
	if (!strcmp(argv[2], "play") && argc > 3) {
		t1 = atoi(argv[3]); t2 = argc > 4 ? atoi(argv[4]) : t1;
		c[0] = 0x48; c[4] = t1; c[5] = 1; c[7] = t2; c[8] = 1;
		return cmd(c, 10, b, 0, 0) < 0;
	}
	if (!strcmp(argv[2], "msf") && argc > 4) {
		sscanf(argv[3], "%d:%d:%d", &m0, &s0, &f0);
		sscanf(argv[4], "%d:%d:%d", &m1, &s1, &f1);
		c[0] = 0x47; c[3] = m0; c[4] = s0; c[5] = f0; c[6] = m1; c[7] = s1; c[8] = f1;
		return cmd(c, 10, b, 0, 0) < 0;
	}
	if (!strcmp(argv[2], "pause") || !strcmp(argv[2], "resume")) {
		c[0] = 0x4B; c[8] = argv[2][0] == 'r';
		return cmd(c, 10, b, 0, 0) < 0;
	}
	if (!strcmp(argv[2], "stop")) { c[0] = 0x4E; return cmd(c, 10, b, 0, 0) < 0; }
	if (!strcmp(argv[2], "volume") && argc > 3) {
		/* MODE SELECT(6), page 0x0E: ports 0 and 1 */
		memset((char *)b, 0, 20);
		b[4] = 0x0E; b[5] = 0x0E; b[6] = 4; b[12] = 1; b[13] = atoi(argv[3]); b[14] = 2; b[15] = b[13];
		c[0] = 0x15; c[1] = 0x10; c[4] = 20;
		return cmd(c, 6, b, 20, 0) < 0;
	}
	if (!strcmp(argv[2], "sense")) {
		int i, n;
		c[0] = 0x1A; c[2] = 0x0E; c[4] = 40;
		if ((n = cmd(c, 6, b, 40, 1)) < 4) return 1;
		for (i = 0; i < n; i++) printf("%02x%c", b[i], i + 1 == n ? '\n' : ' ');
		i = 4 + b[3];
		if (i + 16 <= n) printf("page %02x: port 0 ch %d vol %d, port 1 ch %d vol %d\n",
		                       b[i] & 0x3F, b[i + 8], b[i + 9], b[i + 10], b[i + 11]);
		return 0;
	}
	printf("unknown command %s\n", argv[2]);
	return 1;
}
