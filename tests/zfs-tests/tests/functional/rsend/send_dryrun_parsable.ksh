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
# "zfs send -nP" writes intact parsable output when redirected to a file.
#
# Strategy:
# 1. Redirect "zfs send -nP" to a regular file, for a full, an incremental
#    and a replication stream.
# 2. Verify each line is whole: the size line must not have landed on top
#    of the preceding full/incremental line.
#
# lzc_send_wrapper() relays through a pipe whenever the destination fd is
# not already a FIFO, and its splice() shares that fd with the very code
# printing these lines.  A splice() given no explicit output offset used
# to rewind the fd, so the size line overwrote the line before it.
#

verify_runnable "both"

typeset send_ds="$POOL2/testfs"
typeset out="$BACKDIR/dryrun_parsable.out"

function cleanup
{
	destroy_dataset "$send_ds" "-r"
	rm -f $out
}

log_assert "'zfs send -nP' output is not corrupted by the send relay"
log_onexit cleanup

log_must zfs create $send_ds
log_must mkfile 1M /$POOL2/testfs/file
log_must zfs snapshot $send_ds@snap1
log_must mkfile 1M /$POOL2/testfs/file2
log_must zfs snapshot $send_ds@snap2

#
# Check that $out holds exactly the expected line count, that its last line
# is the size line, and that no earlier line was clobbered by it.
#
function check_output
{
	typeset desc=$1
	typeset first=$2
	typeset -i nlines=$3

	typeset -i got=$(wc -l < $out)
	if (( got != nlines )); then
		log_fail "$desc: expected $nlines lines, got $got:" \
		    "$(cat -v $out)"
	fi

	# Every line must be a whole record: a known keyword in the first
	# tab-separated field, and at least one field after it.  A rewound
	# fd shows up as a line whose first field starts mid-token.
	if ! awk -F'\t' '
	    { last = $1 }
	    NF < 2 { bad = 1; exit }
	    $1 !~ /^(full|incremental|size)$/ { bad = 1; exit }
	    NR == 1 && $1 != first { bad = 1; exit }
	    END { if (bad || last != "size") exit 1 }' first="$first" $out
	then
		log_fail "$desc: corrupted parsable output:" "$(cat -v $out)"
	fi
}

#
# The corruption was timing dependent, so repeat each case.
#
typeset -i i=0
while (( i < 20 )); do
	log_must eval "zfs send -nP $send_ds@snap1 >$out"
	check_output "full send" "full" 2

	log_must eval "zfs send -nP -i $send_ds@snap1 $send_ds@snap2 >$out"
	check_output "incremental send" "incremental" 2

	log_must eval "zfs send -nPR $send_ds@snap2 >$out"
	check_output "replication send" "full" 3

	(( i = i + 1 ))
done

log_pass "'zfs send -nP' output is not corrupted by the send relay"
