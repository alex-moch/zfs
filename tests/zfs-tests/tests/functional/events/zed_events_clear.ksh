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
# 'zpool events -c' does not make ZED raise zfs_zevent_len_max.
#
# STRATEGY:
# 1. Set zfs_zevent_len_max to 512 and start ZED.
# 2. Several times: generate an event, wait for ZED to handle it, then
#    clear the events.
# 3. Verify zfs_zevent_len_max is still 512 and ZED logged no missed
#    events.
#
# ZED doubles zfs_zevent_len_max whenever it is told it missed events.
# Clearing the queue used to count as missed events for every reader,
# so each 'zpool events -c' doubled the limit, up to 1M events.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/events/events_common.kshlib

verify_runnable "both"

function cleanup
{
	zed_stop
	log_must set_tunable32 ZEVENT_LEN_MAX $old_len_max
}

log_assert "'zpool events -c' does not raise zfs_zevent_len_max"

typeset old_len_max=$(get_tunable ZEVENT_LEN_MAX)
log_onexit cleanup

log_must set_tunable32 ZEVENT_LEN_MAX 512
log_must zpool events -c
log_must zed_start

for i in 1 2 3 4 5; do
	log_must zpool scrub -w $TESTPOOL
	# ZED's cursor now points at an event the clear will remove
	typeset n=0
	until (( $(grep -c '^ZEVENT_CLASS=sysevent.fs.zfs.scrub_finish' \
	    $ZED_DEBUG_LOG) >= i )); do
		(( n++ < 60 )) || log_fail "ZED did not handle scrub_finish $i"
		sleep 1
	done
	log_must zpool events -c
done

# one more event, so ZED reads past the last clear
log_must zpool scrub -w $TESTPOOL
log_must file_wait_event $ZED_DEBUG_LOG 'sysevent.fs.zfs.scrub_finish' 60
log_must sleep 2

typeset len_max=$(get_tunable ZEVENT_LEN_MAX)
grep 'Missed' $ZED_LOG
[[ $len_max -eq 512 ]] || log_fail "zfs_zevent_len_max is $len_max, not 512"
log_mustnot grep -q 'Missed' $ZED_LOG

log_pass "'zpool events -c' does not raise zfs_zevent_len_max"
