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
# A reader that falls behind a full zevent queue is told exactly how
# many events it missed.
#
# STRATEGY:
# 1. Set zfs_zevent_len_max to 4 and clear the events.
# 2. Start a zevent_reader, post a few events and let it read them.
# 3. Post more events than the queue holds without reading.
# 4. Let the reader read again and verify it reports as dropped exactly
#    the events posted since its last read minus the queue length.
#
# Everything queued at the reader's last read had already been read,
# so the overflows that remove those events are no loss.  Only the
# events posted later and removed before the next read are.
#

. $STF_SUITE/include/libtest.shlib

verify_runnable "both"

typeset -i pid=0
typeset -i len_max=4

function cleanup
{
	(( pid > 0 )) && kill $pid
	log_must set_tunable32 ZEVENT_LEN_MAX $old_len_max
}

# the EID of the newest queued event
function last_eid
{
	zpool events -v | awk '$1 == "eid" { eid = $3 } END { print eid }'
}

# let the reader read all queued events, sets $read $dropped $last
function reader_read
{
	typeset word
	print -p
	read -p word read word dropped word last
	log_note "reader: read $read dropped $dropped last $last"
}

log_assert "A reader behind a full zevent queue gets the exact drop count"

typeset old_len_max=$(get_tunable ZEVENT_LEN_MAX)
log_onexit cleanup

log_must set_tunable32 ZEVENT_LEN_MAX $len_max
log_must zpool events -c

zevent_reader |&
pid=$!
log_must zpool set comment=c0 $TESTPOOL
typeset -i n=0
reader_read
until (( last == $(last_eid) )); do
	(( n++ < 30 )) || log_fail "reader did not catch up"
	sleep 1
	reader_read
done
typeset -i first=$last

for i in 1 2 3 4; do
	log_must zpool set comment=c$i $TESTPOOL
done

# Count from the reader's own last EID, more events can be posted
# after the last zpool set.
reader_read
typeset -i posted=$(( last - first ))
typeset -i lost=$(( posted - len_max ))
log_note "posted $posted events since the last read, expect $lost dropped"
(( lost >= 2 )) || log_fail "only $posted events posted, need more"
log_must test $dropped -eq $lost
log_must test $read -eq $len_max

log_pass "A reader behind a full zevent queue gets the exact drop count"
