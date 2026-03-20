#!/system/bin/sh
# Files by Google OOM Monitor Script
# Usage: nohup sh /data/local/collect_oom.sh > /data/local/collect_stdout.log 2>&1 &

LOG="/data/local/collect_oom.log"
PKG="com.google.android.apps.nbu.files"
INTERVAL=5

echo "===== OOM Monitor Started: $(date) =====" > "$LOG"
echo "Target: $PKG" >> "$LOG"
echo "Interval: ${INTERVAL}s" >> "$LOG"
echo "" >> "$LOG"

while true; do
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  PID=$(pidof "$PKG")

  echo "[$TS]" >> "$LOG"

  # App status
  if [ -n "$PID" ]; then
    OOM_ADJ=$(cat /proc/$PID/oom_score_adj 2>/dev/null)
    OOM_SCORE=$(cat /proc/$PID/oom_score 2>/dev/null)
    VM_RSS=$(grep VmRSS /proc/$PID/status 2>/dev/null | awk '{print $2}')
    VM_SWAP=$(grep VmSwap /proc/$PID/status 2>/dev/null | awk '{print $2}')
    echo "APP: pid=$PID adj=$OOM_ADJ score=$OOM_SCORE rss=${VM_RSS}kB swap=${VM_SWAP}kB" >> "$LOG"
  else
    echo "APP: NOT RUNNING" >> "$LOG"
  fi

  # System memory
  MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
  MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  DIRTY=$(grep "^Dirty:" /proc/meminfo | awk '{print $2}')
  WRITEBACK=$(grep "^Writeback:" /proc/meminfo | awk '{print $2}')
  CACHED=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')
  SWAP_FREE=$(grep SwapFree /proc/meminfo | awk '{print $2}')
  SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  echo "MEM: free=${MEM_FREE}kB avail=${MEM_AVAIL}kB cached=${CACHED}kB" >> "$LOG"
  echo "DIRTY: dirty=${DIRTY}kB writeback=${WRITEBACK}kB" >> "$LOG"
  echo "SWAP: free=${SWAP_FREE}kB / total=${SWAP_TOTAL}kB" >> "$LOG"

  # vmstat dirty/writeback counts
  NR_DIRTY=$(grep "^nr_dirty " /proc/vmstat | awk '{print $2}')
  NR_WB=$(grep "^nr_writeback " /proc/vmstat | awk '{print $2}')
  echo "VMSTAT: nr_dirty=$NR_DIRTY nr_writeback=$NR_WB" >> "$LOG"

  # PSI memory pressure
  if [ -f /proc/pressure/memory ]; then
    PSI=$(cat /proc/pressure/memory)
    echo "PSI: $PSI" >> "$LOG"
  fi

  echo "" >> "$LOG"
  sleep $INTERVAL
done
