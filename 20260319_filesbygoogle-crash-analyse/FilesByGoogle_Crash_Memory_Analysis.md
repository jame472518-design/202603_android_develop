# Files by Google Crash — Memory State Analysis

## BugReport #1 (2026-02-09) vs BugReport #2 (2026-02-11)

### System Memory (from /proc/meminfo)

| Metric | BR#1 (02-09) | BR#2 (02-11) | Source | What is this | What the value tells us |
|--------|-------------|-------------|--------|-------------|------------------------|
| MemTotal | 7,471,928 kB (~7.1GB) | 7,471,928 kB (~7.1GB) | `/proc/meminfo` (search: "MEMORY INFO") | Total physical RAM | Fixed value, device has 7.1GB RAM |
| MemFree | 1,196,896 kB (16%) | 1,179,292 kB (16%) | `/proc/meminfo` | Completely unused RAM | Only 16% free. This is captured AFTER crash — during crash it was even lower |
| MemAvailable | 5,264,132 kB | 5,247,160 kB | `/proc/meminfo` | RAM available to apps (including reclaimable cache) | Looks like 5GB available, but includes page cache that can't be released during heavy I/O |
| Cached | 4,110,308 kB (~3.9GB) | - | `/proc/meminfo` | Page cache (file I/O buffer) | 3.9GB consumed by page cache from USB copy of 24.7GB — this is the main cause of memory pressure |
| Dirty | 4,092 kB | 6,716 kB | `/proc/meminfo` | Dirty pages not yet written to disk | Low because captured AFTER crash. During crash it should be much higher (dirty_ratio=80 allows up to 80%) |
| SwapTotal | 4,194,300 kB (4GB) | 4,194,300 kB (4GB) | `/proc/meminfo` | ZRAM compressed swap total size | 4GB ZRAM configured |
| SwapFree | 3,812,648 kB (91%) | 3,788,248 kB (90%) | `/proc/meminfo` | ZRAM remaining available | ~400MB swap used, ZRAM itself is not exhausted |

### System Memory Summary (from dumpsys meminfo)

| Metric | BR#1 (02-09) | BR#2 (02-11) | Source | What is this | What the value tells us |
|--------|-------------|-------------|--------|-------------|------------------------|
| Free RAM | 5,625,416 kB | 5,553,820 kB | `dumpsys meminfo` (ActivityManager log) | Free + reclaimable memory | Captured ~1.5min before crash, memory was still available then |
| Used RAM | 2,025,003 kB | 1,749,112 kB | `dumpsys meminfo` | Memory in active use by apps + kernel | ~2GB in use |
| Lost RAM | 236,731 kB | 225,300 kB | `dumpsys meminfo` | Memory unaccounted for (fragmentation, driver alloc) | ~230MB lost to fragmentation |
| ZRAM physical | 129,472 kB | 20,412 kB | `dumpsys meminfo` | Physical RAM used by ZRAM compression | BR#1 used more ZRAM = higher pressure |
| ZRAM swap free | 3,643,296 kB | 4,115,544 kB | `dumpsys meminfo` | ZRAM swap space remaining | BR#1 used more swap |

### Files by Google Process Memory

| Metric | BR#1 (02-09) | BR#2 (02-11) | Source | What is this | What the value tells us |
|--------|-------------|-------------|--------|-------------|------------------------|
| PID | 4796 | 5170 | `dumpsys activity processes` | Process ID | Different PID each time |
| State at death | fg TOP | fg TOP | kernel log: "has died: fg TOP" | Foreground top activity | User was actively using the app when killed |
| PSS (before crash) | 171,161 kB (~167MB) | 114,221 kB (~111MB) | `dumpsys meminfo` (ActivityManager log) | Proportional Set Size | App's own memory usage — NOT excessive, normal for a file manager |
| memtrack | 42,440 kB | 41,556 kB | `dumpsys meminfo` | GPU/hardware memory tracked | ~41MB hardware memory, normal |
| importance | 100 | 100 | `dumpsys activity exit-info` (ApplicationExitInfo) | App importance level | 100 = IMPORTANCE_FOREGROUND, highest priority |
| Kill reason | reason=3 (LOW_MEMORY) | reason=3 (LOW_MEMORY) | `dumpsys activity exit-info` | Why the process was killed | System low memory, not app crash |

### Kernel & System Pressure Indicators

| Metric | BR#1 (02-09) | BR#2 (02-11) | Source | What is this | What the value tells us |
|--------|-------------|-------------|--------|-------------|------------------------|
| kswapd CPU | 14% + 13% = 27% | 14% + 13% = 27% | `dumpsys cpuinfo` (search: "kswapd") | Kernel memory reclaim daemon CPU usage | 27% CPU on memory reclaim. Should be ~0% normally. Kernel reclaiming at full speed but can't keep up |
| oom_reaper count | 242 | 254 | kernel log: grep "oom_reaper: reaped process" | Total processes killed by OOM Killer | Should be ~0 normally. 240+ = system memory near collapse |
| Processes killed in 1 sec | 71 | 64 | kernel log: same-second oom_reaper entries | Processes killed in the same second | Memory collapsed instantly, not gradual degradation |
| lmkd reinit | Yes (line 14561) | Yes (line 15714) | kernel log: "lmkd.reinit" | LMKD daemon reinitialized | LMKD itself had problems, was restarted before crash |
| target_dirty_ratio | 80 | 80 | system properties (search: "target_dirty_ratio") | Max % of reclaimable memory allowed for dirty pages | 80% is too high — allows I/O to consume most available memory |

### Storage (not the cause)

| Metric | BR#1 (02-09) | BR#2 (02-11) | Source | What is this | What the value tells us |
|--------|-------------|-------------|--------|-------------|------------------------|
| /data usage | 56% (50GB/89GB) | 37% (32GB/89GB) | `dumpsys diskstats` or `df` output | Internal storage usage | Different usage but both crashed = storage space is NOT the cause. RAM is |

---

## Key Conclusions

1. **Cached 3.9GB** — Page cache from USB file copy consumed most RAM
2. **kswapd 27% CPU** — Kernel reclaim running at full capacity, can't keep up with I/O
3. **Files by Google PSS 111-167MB** — App's own memory usage is normal, it's NOT a memory leak
4. **importance=100 (FOREGROUND)** — App was actively in use, should be last to be killed
5. **/data 56% vs 37% both crashed** — Proves disk space is irrelevant, pure RAM issue
6. **Two reports nearly identical** — Reproducible system behavior, not random

---

## Where to find these in bugreport (search keywords)

| Search keyword | dumpsys command | What you can see |
|---------------|----------------|-----------------|
| `MEMORY INFO (/proc/meminfo)` | direct dump | MemFree / Cached / Dirty / Swap system memory |
| `Total RAM` or `Free RAM` | `dumpsys meminfo` (summary) | System memory allocation overview |
| `DUMP OF SERVICE meminfo` | `dumpsys meminfo` | Per-app PSS/RSS memory usage ranking |
| `DUMP OF SERVICE cpuinfo` | `dumpsys cpuinfo` | CPU usage ranking, kswapd shows here |
| `ApplicationExitInfo` | `dumpsys activity exit-info` | Historical kill reasons for all apps (reason/importance) |
| `oom_reaper` | kernel log (`logcat -b kernel`) | OOM Killer process kill records |
| `lmkd` | init log | LMKD status and reinit records |
| `DUMP OF SERVICE diskstats` | `dumpsys diskstats` | Disk/storage space usage |
| `DUMP OF SERVICE activity processes` | `dumpsys activity processes` | All processes oom_adj/oom_score ranking |
| `target_dirty_ratio` | system properties dump | dirty_ratio kernel parameter value |
