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
# A command does not inherit the history pool of an exited process
# that had the same pid.
#
# STRATEGY:
# 1. Create a mirror and offline both sides in one command. The first
#    offline sets the history pool of the process, the second fails, so
#    the command exits without logging.
# 2. Run zpool sync with the pid of that command.
# 3. Verify that the pool history has no zpool sync entry. zpool sync
#    never sets the history pool itself.
#

. $STF_SUITE/include/libtest.shlib

verify_runnable "global"

typeset pool=histpid
typeset dir=$TEST_BASE_DIR/history_pid_reuse
typeset ns_last_pid=/proc/sys/kernel/ns_last_pid

function cleanup
{
	poolexists $pool && destroy_pool $pool
	rm -rf $dir
}

# run "$@" in a new process, write its pid to $1 first
function run_with_pidfile
{
	typeset pidfile=$1
	shift
	sh -c 'echo $$ > "$0"; exec "$@"' $pidfile "$@"
}

log_assert "A command does not inherit the history pool of an exited process"
log_onexit cleanup

[[ -w $ns_last_pid ]] || log_unsupported "$ns_last_pid is not writable"

log_must mkdir -p $dir
log_must truncate -s $MINVDEVSIZE $dir/a $dir/b
log_must zpool create $pool mirror $dir/a $dir/b

# not under log_must, a subshell there would take the pid
run_with_pidfile $dir/pid1 zpool offline -t $pool $dir/a $dir/b &&
    log_fail "offlining both sides of the mirror succeeded"
log_must zpool online $pool $dir/a
typeset -i pid=$(<$dir/pid1)

typeset -i tries=0
while :; do
	echo $((pid - 1)) > $ns_last_pid
	run_with_pidfile $dir/pid2 zpool sync $pool || log_fail "zpool sync failed"
	(( $(<$dir/pid2) == pid )) && break
	(( ++tries < 10 )) || log_unsupported "pid $pid not reused"
done

# write out what the sync may have logged
log_must zpool sync $pool
zpool history $pool
log_mustnot eval "zpool history $pool | grep -q 'zpool sync'"

log_pass "A command does not inherit the history pool of an exited process"
