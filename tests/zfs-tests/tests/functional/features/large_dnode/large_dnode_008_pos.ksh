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
# Copyright (c) 2017 by Lawrence Livermore National Security, LLC.
# Use is subject to license terms.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# Run many xattrtests on a dataset with large dnodes and xattr=sa to
# stress concurrent allocation of large dnodes.
#

TEST_FS=$TESTPOOL/large_dnode

verify_runnable "both"

function cleanup
{
	datasetexists $TEST_FS && destroy_dataset $TEST_FS
}

function verify_dnode_packing
{
	zdb -dd $TEST_FS | grep -A 3 'Dnode slots' | awk '
		/Total used:/ {total_used=$NF}
		/Max used:/ {max_used=$NF}
		/Percent empty:/ {print total_used, max_used, int($NF)}
	' | while read total_used max_used pct_empty
	do
		log_note "total_used $total_used max_used $max_used pct_empty $pct_empty"
		if [ $pct_empty -gt 5 ]; then
			log_fail "Holes in dnode array: pct empty $pct_empty > 5"
		fi
	done
}

# DEBUG: dnode allocator counters, to see where the holes come from
function dnstats
{
	typeset p=/sys/module/zfs/parameters/zfs_debug_objalloc
	awk 'NR > 2 {print $1, $3}' /proc/spl/kstat/zfs/dnodestats
	for c in chunk_lost chunk_lost_slots skip_slots stray; do
		echo "$c $(cat ${p}_$c 2>/dev/null || echo 0)"
	done
}

log_onexit cleanup
log_assert "xattrtest runs concurrently on dataset with large dnodes"

log_note "DEBUG check_end $(cat \
    /sys/module/zfs/parameters/zfs_debug_objalloc_check_end 2>/dev/null)"
dnstats > $TEST_BASE_DIR/dnstats.before
log_must zfs create $TEST_FS
log_must zfs set dnsize=auto $TEST_FS
log_must zfs set xattr=sa $TEST_FS

for ((i=0; i < 100; i++)); do
	dir="/$TEST_FS/dir.$i"
	log_must mkdir "$dir"
	log_must eval "xattrtest -R -r -y -x 1 -f 1024 -k -p $dir >/dev/null 2>&1 &"
done

log_must wait
sync_pool $TESTPOOL

dnstats > $TEST_BASE_DIR/dnstats.after
log_note "DEBUG dnstats $(awk 'NR == FNR {b[$1] = $2; next}
	$2 != b[$1] {printf "%s=%d ", $1, $2 - b[$1]}' \
	$TEST_BASE_DIR/dnstats.before $TEST_BASE_DIR/dnstats.after)"

verify_dnode_packing

log_pass
