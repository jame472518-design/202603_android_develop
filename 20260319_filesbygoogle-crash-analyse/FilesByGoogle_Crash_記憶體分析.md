# Files by Google Crash — 記憶體狀態分析

## BugReport #1 (2026-02-09) vs BugReport #2 (2026-02-11)

### 系統記憶體 (來自 /proc/meminfo)

| 指標 | BR#1 (02-09) | BR#2 (02-11) | 來源位置 | 這是什麼 | 數值說明什麼 |
|------|-------------|-------------|---------|---------|------------|
| MemTotal | 7,471,928 kB (~7.1GB) | 7,471,928 kB (~7.1GB) | `/proc/meminfo` (搜尋 "MEMORY INFO") | 裝置物理 RAM 總量 | 7.1GB，固定值 |
| MemFree | 1,196,896 kB (16%) | 1,179,292 kB (16%) | `/proc/meminfo` | 完全沒被使用的 RAM | 只剩 16%，這是 crash 後抓的，crash 當下應更低 |
| MemAvailable | 5,264,132 kB | 5,247,160 kB | `/proc/meminfo` | 可被應用程式使用的 RAM（含可回收 cache） | 看起來 5GB 可用，但含 page cache，大量 I/O 時釋放不了 |
| Cached | 4,110,308 kB (~3.9GB) | - | `/proc/meminfo` | Page cache（檔案 I/O 緩衝） | 3.9GB 被 page cache 佔用，USB 複製 24.7GB 產生的，記憶體壓力主因 |
| Dirty | 4,092 kB | 6,716 kB | `/proc/meminfo` | 尚未寫回磁碟的 dirty pages | crash 後才抓所以低，當下應很高（dirty_ratio=80 允許 80%） |
| SwapTotal | 4,194,300 kB (4GB) | 4,194,300 kB (4GB) | `/proc/meminfo` | ZRAM 壓縮交換空間總量 | 4GB ZRAM |
| SwapFree | 3,812,648 kB (91%) | 3,788,248 kB (90%) | `/proc/meminfo` | ZRAM 剩餘可用 | 已用 ~400MB swap，ZRAM 本身未耗盡 |

### 系統記憶體摘要 (來自 dumpsys meminfo)

| 指標 | BR#1 (02-09) | BR#2 (02-11) | 來源位置 | 這是什麼 | 數值說明什麼 |
|------|-------------|-------------|---------|---------|------------|
| Free RAM | 5,625,416 kB | 5,553,820 kB | `dumpsys meminfo` (ActivityManager log) | 可用 + 可回收記憶體 | crash 前 ~1.5 分鐘抓的，當時記憶體還有 |
| Used RAM | 2,025,003 kB | 1,749,112 kB | `dumpsys meminfo` | 正在使用的記憶體（App + kernel） | ~2GB 在使用中 |
| Lost RAM | 236,731 kB | 225,300 kB | `dumpsys meminfo` | 無法追蹤的記憶體（碎片化、driver） | ~230MB 碎片化損失 |
| ZRAM 實體 | 129,472 kB | 20,412 kB | `dumpsys meminfo` | ZRAM 壓縮使用的實體 RAM | BR#1 用了更多 ZRAM = 壓力更大 |
| ZRAM swap free | 3,643,296 kB | 4,115,544 kB | `dumpsys meminfo` | ZRAM 剩餘交換空間 | BR#1 用了更多 swap |

### Files by Google 進程記憶體

| 指標 | BR#1 (02-09) | BR#2 (02-11) | 來源位置 | 這是什麼 | 數值說明什麼 |
|------|-------------|-------------|---------|---------|------------|
| PID | 4796 | 5170 | `dumpsys activity processes` | 進程 ID | 每次不同 |
| 死前狀態 | fg TOP | fg TOP | kernel log: "has died: fg TOP" | 前景最上層 Activity | 使用者正在使用中被殺 |
| PSS（crash 前） | 171,161 kB (~167MB) | 114,221 kB (~111MB) | `dumpsys meminfo` (ActivityManager log) | 比例分配記憶體 | App 自身記憶體正常，不是 memory leak |
| memtrack | 42,440 kB | 41,556 kB | `dumpsys meminfo` | GPU/硬體記憶體 | ~41MB 硬體記憶體，正常 |
| importance | 100 | 100 | `dumpsys activity exit-info` (ApplicationExitInfo) | App 重要性等級 | 100 = IMPORTANCE_FOREGROUND，最高優先級 |
| Kill 原因 | reason=3 (LOW_MEMORY) | reason=3 (LOW_MEMORY) | `dumpsys activity exit-info` | 進程死因 | 系統記憶體不足，非 App crash |

### Kernel 與系統壓力指標

| 指標 | BR#1 (02-09) | BR#2 (02-11) | 來源位置 | 這是什麼 | 數值說明什麼 |
|------|-------------|-------------|---------|---------|------------|
| kswapd CPU | 14%+13% = 27% | 14%+13% = 27% | `dumpsys cpuinfo` (搜尋 "kswapd") | Kernel 記憶體回收守護進程 CPU 佔用 | 27% CPU 在回收記憶體，正常應 ~0%。全力回收仍不夠 |
| oom_reaper 總數 | 242 | 254 | kernel log: grep "oom_reaper: reaped process" | 被 OOM Killer 殺掉的進程總數 | 正常應 ~0。240+ = 系統記憶體瀕臨崩潰 |
| 同秒被殺進程 | 71 | 64 | kernel log: 同一秒的 oom_reaper 記錄 | 同一秒內被殺的進程數 | 記憶體瞬間雪崩，非漸進式降級 |
| lmkd reinit | 有（行 14561） | 有（行 15714） | kernel log: "lmkd.reinit" | LMKD 守護進程被重新初始化 | LMKD 自身出問題，crash 前被重啟 |
| target_dirty_ratio | 80 | 80 | system properties (搜尋 "target_dirty_ratio") | dirty pages 可佔用的最大記憶體比例 | 80% 太高 — 允許 I/O 佔用大部分可用記憶體 |

### 儲存空間（不是主因）

| 指標 | BR#1 (02-09) | BR#2 (02-11) | 來源位置 | 這是什麼 | 數值說明什麼 |
|------|-------------|-------------|---------|---------|------------|
| /data 使用率 | 56% (50GB/89GB) | 37% (32GB/89GB) | `dumpsys diskstats` 或 `df` | 內部儲存空間使用比例 | 兩次差異大但都被殺 = 磁碟空間不是主因，RAM 才是 |

---

## 重點結論

1. **Cached 3.9GB** — USB 複製產生的 page cache 佔掉大部分 RAM
2. **kswapd 27% CPU** — Kernel 全力回收記憶體仍跟不上 I/O 速度
3. **Files by Google PSS 111-167MB** — App 自身記憶體正常，不是 memory leak
4. **importance=100 (前景)** — App 正在使用中，應是最後被殺的
5. **/data 56% vs 37% 都被殺** — 證明跟磁碟空間無關，純粹 RAM 問題
6. **兩次數據幾乎一致** — 可重現的系統行為，非隨機問題

---

## 在 bugreport 中查找這些資訊（搜尋關鍵字）

| 搜尋關鍵字 | 對應 dumpsys 指令 | 可以看到什麼 |
|-----------|----------------|------------|
| `MEMORY INFO (/proc/meminfo)` | 直接 dump | MemFree/Cached/Dirty/Swap 系統記憶體 |
| `Total RAM` 或 `Free RAM` | `dumpsys meminfo`（摘要） | 系統記憶體分配概覽 |
| `DUMP OF SERVICE meminfo` | `dumpsys meminfo` | 每個 App 的 PSS/RSS 記憶體用量排行 |
| `DUMP OF SERVICE cpuinfo` | `dumpsys cpuinfo` | CPU 使用排行，kswapd 在這裡 |
| `ApplicationExitInfo` | `dumpsys activity exit-info` | 所有 App 的歷史死因記錄（reason/importance） |
| `oom_reaper` | kernel log (`logcat -b kernel`) | OOM Killer 殺進程記錄 |
| `lmkd` | init log | LMKD 狀態和 reinit 記錄 |
| `DUMP OF SERVICE diskstats` | `dumpsys diskstats` | 磁碟/儲存空間使用 |
| `DUMP OF SERVICE activity processes` | `dumpsys activity processes` | 所有進程的 oom_adj/oom_score 排行 |
| `target_dirty_ratio` | system properties dump | dirty_ratio kernel 參數值 |
