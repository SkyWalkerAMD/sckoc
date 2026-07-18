// SPDX-License-Identifier: GPL-2.0-only
/* hsmp-msg: generic HSMP query. usage: hsmp-msg <msg_id> <response_sz> <sock> [arg0..]
   prints response words space-separated */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/types.h>

#if defined(__has_include)
# if __has_include(<asm/amd_hsmp.h>)
#  include <asm/amd_hsmp.h>
#  define HAVE_HSMP_HDR
# endif
#endif
#ifndef HAVE_HSMP_HDR
#pragma pack(4)
struct hsmp_message {
	__u32 msg_id;
	__u16 num_args;
	__u16 response_sz;
	__u32 args[8];
	__u16 sock_ind;
};
#pragma pack()
#define HSMP_IOCTL_CMD _IOWR(0xF8, 0, struct hsmp_message)
#endif

int main(int argc, char *argv[])
{
	struct hsmp_message msg = {0};
	int i, fd;
	if (argc < 4) { fprintf(stderr, "usage: %s msg_id response_sz sock [args..]\n", argv[0]); return 1; }
	fd = open("/dev/hsmp", O_RDONLY);
	if (fd < 0) { perror("open /dev/hsmp"); return 1; }
	msg.msg_id = strtoul(argv[1], NULL, 0);
	msg.response_sz = strtoul(argv[2], NULL, 0);
	if (msg.response_sz > 8) msg.response_sz = 8; /* args[] holds at most 8 words */
	msg.sock_ind = strtoul(argv[3], NULL, 0);
	msg.num_args = argc - 4;
	for (i = 4; i < argc && i - 4 < 8; i++) msg.args[i - 4] = strtoul(argv[i], NULL, 0);
	if (ioctl(fd, HSMP_IOCTL_CMD, &msg) < 0) { perror("hsmp ioctl"); return 2; }
	for (i = 0; i < msg.response_sz; i++) printf("%u%s", msg.args[i], i + 1 < msg.response_sz ? " " : "\n");
	close(fd);
	return 0;
}
