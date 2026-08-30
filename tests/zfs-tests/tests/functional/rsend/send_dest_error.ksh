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

. $STF_SUITE/tests/functional/rsend/rsend.kshlib

#
# Description:
# A send whose destination fails mid-stream reports an error instead of
# dying of SIGPIPE.
#
# Strategy:
# 1. Send a snapshot to /dev/full, which takes the whole stream as
#    ENOSPC.
# 2. Verify the send exits with an ordinary failure status, not a
#    signal death, and says something on stderr.
#
# lzc_send_wrapper()'s relay thread closes its end of the pipe when the
# destination fails, and the send still writing into that pipe was then
# killed by SIGPIPE -- exit 141, no message, truncated output, and the
# real error (ENOSPC here) never reported at all.
#
# The relay only exists on Linux; elsewhere the send writes to the
# destination directly.
#

verify_runnable "both"

if ! is_linux; then
	log_unsupported "lzc_send_wrapper() only relays on Linux"
fi

typeset send_ds="$POOL2/testfs"
typeset err="$BACKDIR/dest_error.err"

function cleanup
{
	destroy_dataset "$send_ds" "-r"
	rm -f $err
}

log_assert "a failing send destination is reported, not fatal"
log_onexit cleanup

log_must zfs create $send_ds
log_must mkfile 1M /$send_ds/file
log_must zfs snapshot $send_ds@snap

zfs send $send_ds@snap >/dev/full 2>$err
typeset -i rc=$?

if (( rc == 0 )); then
	log_fail "send to /dev/full unexpectedly succeeded"
fi

#
# Anything above 128 is a death by signal; SIGPIPE (141) is the one
# this used to be.
#
if (( rc > 128 )); then
	log_fail "send to /dev/full was killed by signal $(( rc - 128 ))," \
	    "expected an ordinary error exit"
fi

if [[ ! -s $err ]]; then
	log_fail "send to /dev/full failed silently, expected a message"
fi

log_note "send failed as expected: rc=$rc, stderr: $(cat $err)"
log_pass "a failing send destination is reported, not fatal"
