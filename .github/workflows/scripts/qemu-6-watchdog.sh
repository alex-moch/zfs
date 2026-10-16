#!/usr/bin/env bash
# DEBUG: while ZTS runs, dump kernel and pool state whenever the test log
# has not changed for 300 s, at most every 10 min and 6 times in total.
# Output goes to /var/tmp/watchdog-*.txt, which qemu-7-prepare.sh collects.
log=/var/tmp/test_results/current/log
echo 1 | sudo tee /proc/sys/kernel/sysrq >/dev/null
n=0; last=0
while [ $n -lt 6 ]; do
  sleep 30
  [ -e "$log" ] || continue
  now=$(date +%s); age=$(( now - $(stat -c %Y "$log") ))
  [ $age -ge 300 ] && [ $(( now - last )) -ge 600 ] || continue
  n=$((n + 1)); last=$now; out=/var/tmp/watchdog-$n.txt
  {
    echo "=== $(date -u) log unchanged for ${age}s"
    echo "=== last test lines"; tail -5 "$log"
    echo "=== D-state tasks"; ps -eo pid,stat,etime,wchan:32,args | awk 'NR==1 || $2 ~ /D/'
    for p in $(ps -eo pid,stat | awk '$2 ~ /D/ {print $1}'); do
      echo "--- /proc/$p/stack ($(cat /proc/$p/comm 2>/dev/null))"; sudo cat /proc/$p/stack 2>&1
    done
    echo "=== zfs/zpool processes"; ps -eo pid,stat,etime,wchan:32,args | grep -E '[z]pool|[z]fs |[z]inject|[k]sh .*\.ksh'
    echo "=== sysrq w (blocked tasks)"; echo w | sudo tee /proc/sysrq-trigger >/dev/null; sleep 2; sudo dmesg | tail -400
    echo "=== zpool status"; sudo zpool status -v 2>&1 | head -100
    echo "=== zfs dbgmsg"; sudo tail -200 /proc/spl/kstat/zfs/dbgmsg 2>&1
  } > "$out" 2>&1
done
