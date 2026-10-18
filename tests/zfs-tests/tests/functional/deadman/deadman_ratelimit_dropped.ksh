#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

#
# Copyright (c) 2026 by Alexander Moch. All rights reserved.
#

#
# DESCRIPTION:
# Rate limited ereports are counted in the fm kstat, not reported to
# zevent readers as dropped events.
#
# STRATEGY:
# 1. Rate limit deadman events to 1 per second.
# 2. Follow the events with 'zpool events -f'.
# 3. Cause a burst of deadman events with zinject.
# 4. Verify erpt-ratelimited went up and the reader saw no drops.
#
# ZED raises zfs_zevent_len_max for every dropped event it is told
# about, but a longer queue does not keep rate limited events.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/deadman/deadman.cfg

verify_runnable "both"

typeset out=$TEST_BASE_DIR/deadman_ratelimit_dropped.out
typeset -i pid=0

function cleanup
{
	(( pid > 0 )) && kill $pid
	zinject -c all
	default_cleanup_noexit
	set_tunable64 DEADMAN_EVENTS_PER_SECOND $OLD_DEADMAN_EVENTS
	set_tunable64 DEADMAN_ZIOTIME_MS $ZIOTIME_DEFAULT
	set_tunable32 PREFETCH_DISABLE $OLD_PREFETCH
	rm -f $out
}

# empty if the kstat has no such field
function ratelimited
{
	kstat -g fm | awk '$1 == "erpt-ratelimited" { print $2 }'
}

log_assert "Rate limited ereports are not reported as dropped events"
log_onexit cleanup

OLD_DEADMAN_EVENTS=$(get_tunable DEADMAN_EVENTS_PER_SECOND)
OLD_PREFETCH=$(get_tunable PREFETCH_DISABLE)
log_must set_tunable64 DEADMAN_EVENTS_PER_SECOND 1
log_must set_tunable64 DEADMAN_ZIOTIME_MS 1
# Deadman events come only from waited zios. Prefetched reads are not
# waited for, which can leave too few events to be rate limited.
log_must set_tunable32 PREFETCH_DISABLE 1

default_setup_noexit $DISK1
log_must zpool events -c
mntpnt=$(get_prop mountpoint $TESTPOOL/$TESTFS)
log_must file_write -b 1048576 -c 8 -o create -d 0 -f $mntpnt/file
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL

typeset before=$(ratelimited)
zpool events -f -H > $out 2>&1 &
pid=$!

log_must zinject -d $DISK1 -D 5:1 $TESTPOOL
log_must dd if=$mntpnt/file of=/dev/null oflag=sync
log_must zinject -c all

# one more event: a drop count is only reported with the next event read
log_must zpool set comment=done $TESTPOOL

# wait until the reader has read every queued event
typeset -i queued=$(zpool events -H | wc -l)
typeset -i n=0
until (( $(grep -vc '^dropped' $out) >= queued )); do
	(( n++ < 30 )) || log_fail "reader did not read all $queued events"
	sleep 1
done
kill $pid
pid=0

typeset after=$(ratelimited)
log_note "erpt-ratelimited ${before:-none} -> ${after:-none}"
grep '^dropped' $out
log_mustnot grep -q '^dropped' $out
log_must test ${after:-0} -gt ${before:-0}

log_pass "Rate limited ereports are not reported as dropped events"
