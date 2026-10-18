#!/bin/ksh
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
# Copyright (c) 2023 by Findity AB
#

. $STF_SUITE/tests/functional/rsend/rsend.kshlib

#
# Description:
# Verify that receiving a raw encrypted stream, with a FREEOBJECTS
# removing all existing objects in a block followed by an OBJECT write
# to the same block, does not result in a panic.
#
# Strategy:
# 1. Create a new encrypted filesystem
# 2. Create file f1 as the first object in some block
# 3. Take snapshot A
# 4. Create file f2 as another object in the same block
# 5. Delete f1
# 6. Take snapshot B
# 7. Receive a full raw encrypted send of A
# 8. Receive an incremental raw send of B
#
verify_runnable "both"

#
# New objects come from per-CPU chunks of 128 dnodes. A multiple of 128
# starts a new chunk, so nothing else is in its dnode block. Which CPU
# gets one depends on what ran before, so touch on each CPU in turn.
#
function create_first_in_chunk
{
	typeset file=$1
	typeset -i ncpu=$(get_num_cpus)
	typeset -i i onum

	for ((i = 0; i < 300; i++)); do
		cpu=$((i % ncpu))
		run_on_cpu $cpu touch $file
		onum=$(ls -i $file | awk '{print $1}')
		if ((onum % 128 == 0)); then
			num=$onum
			return
		fi
		rm -f $file
	done
	log_fail "No new chunk of objects after $i files"
}

#
# Create the file in the same dnode block as object $num. The CPU that
# got $num hands out the next numbers of that chunk.
#
function create_in_block
{
	typeset file=$1
	typeset -i i onum

	for ((i = 0; i < 100; i++)); do
		run_on_cpu $cpu touch $file
		onum=$(ls -i $file | awk '{print $1}')
		if ((onum > num && onum < num + 32)); then
			return
		fi
		rm -f $file
	done
	log_fail "No object in the block of object $num after $i files"
}

function run_on_cpu
{
	typeset cpu=$1
	shift

	if is_linux; then
		taskset -c $cpu "$@" 2>/dev/null && return
	elif is_freebsd; then
		cpuset -l $cpu "$@" 2>/dev/null && return
	fi
	"$@"
}

log_assert "FREEOBJECTS followed by OBJECT in encrypted stream does not crash"

sendds=sendencfods
recvds=recvencfods
keyfile=/$POOL/keyencfods
f1=/$POOL/$sendds/f1
f2=/$POOL/$sendds/f2

log_must eval "echo 'password' > $keyfile"

#
# xattr=sa and dnodesize=legacy for sequential object numbers, see
# note in send_freeobjects.ksh.
#
log_must zfs create -o xattr=sa -o dnodesize=legacy -o encryption=on \
	-o keyformat=passphrase -o keylocation=file://$keyfile $POOL/$sendds

create_first_in_chunk $f1
log_must zfs snap $POOL/$sendds@A
create_in_block $f2
log_must rm $f1
log_must zfs snap $POOL/$sendds@B

log_must eval "zfs send -w $POOL/$sendds@A | zfs recv $POOL/$recvds"
log_must eval "zfs send -w -i $POOL/$sendds@A $POOL/$sendds@B |" \
	"zfs recv $POOL/$recvds"

log_pass "FREEOBJECTS followed by OBJECT in encrypted stream did not crash"
