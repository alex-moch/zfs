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
#

. $STF_SUITE/include/libtest.shlib

DISK=${DISKS%% *}

zed_setup all-debug.sh all-syslog.sh

# ZED raises zfs_zevent_len_max only after it has lost events. Give the
# error storms of these tests a queue that does not overflow.
log_must eval "get_tunable ZEVENT_LEN_MAX > $TEST_BASE_DIR/zevent_len_max"
log_must set_tunable32 ZEVENT_LEN_MAX 20000

default_setup $DISK
