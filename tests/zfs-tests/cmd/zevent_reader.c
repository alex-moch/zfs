// SPDX-License-Identifier: CDDL-1.0
/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * https://opensource.org/license/CDDL-1.0.
 */

/*
 * Copyright (c) 2026 by Alexander Moch. All rights reserved.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libzfs.h>
#include <sys/nvpair.h>

#define	ZEVENT_NONBLOCK	0x1

/*
 * A zevent reader that keeps one cursor and reads only when told to.
 * For every line on stdin it reads all queued events and prints
 *
 *   read <events> dropped <dropped> last <eid>
 *
 * Used by zed_events_overflow.ksh to stop reading at a known event
 * without signals, which make a blocking read fail with EINTR.
 */
int
main(void)
{
	libzfs_handle_t *hdl;
	char line[64];
	int fd;

	hdl = libzfs_init();
	if (hdl == NULL) {
		(void) fprintf(stderr, "libzfs_init: %s\n", strerror(errno));
		exit(2);
	}
	fd = open(ZFS_DEV, O_RDWR);
	if (fd < 0) {
		(void) fprintf(stderr, "open: %s\n", strerror(errno));
		libzfs_fini(hdl);
		exit(2);
	}

	while (fgets(line, sizeof (line), stdin) != NULL) {
		uint64_t eid = 0;
		int events = 0, total = 0, dropped;
		nvlist_t *nvl;

		while (zpool_events_next(hdl, &nvl, &dropped,
		    ZEVENT_NONBLOCK, fd) == 0 && nvl != NULL) {
			(void) nvlist_lookup_uint64(nvl, "eid", &eid);
			total += dropped;
			events++;
			nvlist_free(nvl);
		}
		(void) printf("read %d dropped %d last %llu\n", events, total,
		    (u_longlong_t)eid);
		(void) fflush(stdout);
	}

	(void) close(fd);
	libzfs_fini(hdl);

	return (0);
}
