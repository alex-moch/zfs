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
# "zfs send" writes a correct stream to an fd opened for appending.
#
# Strategy:
# 1. Send a snapshot with ">>" onto a file that already has content.
# 2. Verify the send succeeded and appended a stream byte for byte
#    identical to the one ">" produces.
# 3. Verify the appended stream still receives.
#
# lzc_send_wrapper() relays through a pipe and used splice() to do it,
# but splice() will not write to an O_APPEND fd -- it fails EINVAL.  The
# relay thread then closed the pipe under the still-running send, which
# died of SIGPIPE without printing anything at all.
#

verify_runnable "both"

typeset send_ds="$POOL2/testfs"
typeset recv_ds="$POOL2/recvfs"
typeset ref="$BACKDIR/append_ref"
typeset out="$BACKDIR/append_out"

function cleanup
{
	destroy_dataset "$send_ds" "-r"
	destroy_dataset "$recv_ds" "-r"
	rm -f $ref $out
}

log_assert "'zfs send' to an append-mode fd writes a correct stream"
log_onexit cleanup

log_must zfs create $send_ds
log_must mkfile 1M /$send_ds/file
log_must zfs snapshot $send_ds@snap

# The reference stream, written the ordinary way.
log_must eval "zfs send $send_ds@snap >$ref"

# The same stream, appended after existing content.
echo "HEADER" >$out
typeset -i hdr=$(stat_size $out)
log_must eval "zfs send $send_ds@snap >>$out"

typeset -i want=$(( hdr + $(stat_size $ref) ))
typeset -i got=$(stat_size $out)
if (( got != want )); then
	log_fail "appended file is $got bytes, expected $want"
fi

# What landed after the header must be exactly the reference stream.
log_must eval "tail -c +$(( hdr + 1 )) $out | cmp - $ref"

# And it must still be a usable stream.
log_must eval "tail -c +$(( hdr + 1 )) $out | zfs receive $recv_ds"
log_must directory_diff /$send_ds /$recv_ds

log_pass "'zfs send' to an append-mode fd writes a correct stream"
