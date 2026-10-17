#!/usr/bin/env bash
# DEBUG: while ZTS runs, dump kernel and pool state to
# /var/tmp/watchdog-*.txt, which qemu-7-prepare.sh collects.
# - On a ZFS assertion (PANIC at ...) dump once right away, then stop
#   test-runner. The panicking thread never returns, so every later test
#   would only hang and get KILLED.
# - When the test log has not changed for 300 s, dump at most every
#   10 min and 6 times in total.
# The debug log is read before any zpool command, and every zpool command
# runs under timeout, since they block on a pool whose txg_sync is stuck.
log=/var/tmp/test_results/current/log
echo 1 | sudo tee /proc/sys/kernel/sysrq >/dev/null

dump() {
  echo "=== $(date -u) $1"
  echo "=== last test lines"; tail -20 "$log" 2>&1
  echo "=== kernel messages"; sudo dmesg | grep -v 'sysrq: Show' | tail -150
  echo "=== D-state tasks"; ps -eo pid,stat,etime,wchan:32,args | awk 'NR==1 || $2 ~ /D/'
  for p in $(ps -eo pid,stat | awk '$2 ~ /D/ {print $1}'); do
    echo "--- /proc/$p/stack ($(cat "/proc/$p/comm" 2>/dev/null))"; sudo cat /proc/"$p"/stack 2>&1
  done
  echo "=== ZFS kernel threads"
  for p in $(ps -eo pid,comm | awk '$2 ~ /^(txg_|z_|spa_|dp_|vdev_|l2arc|arc_|zthr)/ {print $1}'); do
    st=$(sudo cat /proc/"$p"/stack 2>&1)
    echo "$st" | grep -q 'cv_wait\|spl_panic\|mutex\|rwsem\|zio_wait' || continue
    echo "--- /proc/$p/stack ($(cat "/proc/$p/comm" 2>/dev/null))"; echo "$st"
  done
  echo "=== zfs/zpool processes"; ps -eo pid,stat,etime,wchan:32,args | grep -E '[z]pool|[z]fs |[z]inject|[z]ed|[k]sh .*\.ksh'
  echo "=== zfs dbgmsg"; sudo tail -4000 /proc/spl/kstat/zfs/dbgmsg 2>&1
  echo "=== zpool status"; sudo timeout -k 5 20 zpool status -v 2>&1 | head -100
  echo "=== zpool events"; sudo timeout -k 5 20 zpool events -v 2>&1 | tail -600
  echo "=== zpool history"; sudo timeout -k 5 20 zpool history -il 2>&1 | tail -100
  echo "=== sysrq w (blocked tasks)"; echo w | sudo tee /proc/sysrq-trigger >/dev/null; sleep 2
  sudo dmesg | sed -n '/sysrq: Show Blocked State/,$p' | tail -400
}

n=0; last=0
while true; do
  sleep 10
  if sudo dmesg | grep -q 'PANIC at '; then
    dump "ZFS assertion" > /var/tmp/watchdog-panic.txt 2>&1
    sudo pkill -f '/test-runner\.py' || true
    exit 0
  fi
  [ -e "$log" ] && [ $n -lt 6 ] || continue
  now=$(date +%s); age=$(( now - $(stat -c %Y "$log") ))
  [ $age -ge 300 ] && [ $(( now - last )) -ge 600 ] || continue
  n=$((n + 1)); last=$now
  dump "log unchanged for ${age}s" > /var/tmp/watchdog-$n.txt 2>&1
done
