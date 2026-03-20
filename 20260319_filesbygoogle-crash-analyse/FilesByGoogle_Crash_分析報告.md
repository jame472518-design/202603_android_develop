# Files by Google Crash 分析報告

**日期:** 2026-03-19
**裝置:** Thorpe DVT3 (T70)
**OS:** 2.01.02 / 2.01.03 (Build: AQ3A.250408.001)
**RAM:** ~7.1 GB + 4 GB ZRAM Swap

---

## 1. 問題描述

使用 SanDisk USB-C 隨身碟（32GB/64GB），將 10 個 2.47GB ZIP 檔從 USB 複製到內部儲存空間。反覆填滿/刪除/重啟，在約 10~15 次操作過程中 **Files by Google 發生 2 次閃退**。

測試者懷疑是 Android 層級問題（在 Akita 專案也見到類似現象）。

---

## 2. 關鍵結論

**Files by Google 並非 App Crash，而是被 Linux Kernel OOM Killer 強制終止。**

兩次事件的 kill reason 均為 `reason=3 (LOW_MEMORY)`，由 kernel `oom_reaper` 直接回收進程記憶體。

---

## 3. 兩次 Crash 對比

| 項目 | BugReport #1 (02-09) | BugReport #2 (02-11) |
|------|---------------------|---------------------|
| Crash 時間 | 15:44:47 | 13:01:01 |
| 被 Kill 的 PID | 4796 | 5170 |
| Kill 原因 | LOW_MEMORY (reason=3) | LOW_MEMORY (reason=3) |
| oom_reaper 回收 | anon-rss:0kB, file-rss:3244kB | anon-rss:0kB, file-rss:2728kB |
| 前景 Activity | AdvancedBrowsingActivity | AdvancedBrowsingActivity |
| Crash 前被 reap 的進程數 | 71 (同一秒內) | 64 (同一秒內) |
| /data 使用率 | 56% (50GB/89GB) | 37% (32GB/89GB) |
| kswapd CPU | 14% + 13% | 14% + 13% |
| 總 oom_reaper 事件 | 256 | 266 |

---

## 4. Root Cause 分析

### 4.1 直接原因
Linux Kernel OOM Killer 強制終止 Files by Google 進程。Log 證據：
```
oom_reaper: reaped process 4796 (.apps.nbu.files), now anon-rss:0kB, file-rss:3244kB, shmem-rss:3724kB
ActivityManager: Process com.google.android.apps.nbu.files (pid 4796) has died: fg TOP
process=com.google.android.apps.nbu.files reason=3 (LOW_MEMORY) subreason=0 (UNKNOWN)
```

### 4.2 記憶體壓力來源
- **Page Cache 壓力**：從 USB 複製 ~24.7GB 檔案，kernel 需大量 page cache 緩衝 I/O
- **FUSE 開銷**：Android /storage/emulated 使用 FUSE，每次 I/O 需額外 buffer copy
- **kswapd 持續高負載**：14% CPU 使用率，表示 kernel 不斷回收記憶體
- **ZRAM 壓力**：4GB swap 在大量 I/O 時不足以緩衝
- **反覆填滿/刪除**：導致檔案系統碎片化，增加 metadata 記憶體使用

### 4.3 結論
**這是 Android/Kernel 層級的記憶體管理問題，非 Files by Google App bug。** Files by Google 是 OOM Killer 的受害者。

> 詳細責任歸屬分析請參見 [FilesByGoogle_Crash_責任歸屬分析.md](FilesByGoogle_Crash_責任歸屬分析.md)

---

## 5. 建議處理方案

| 優先級 | 方案 | 層級 | 負責方 |
|--------|------|------|--------|
| P0 | 向 Google 回報 Bug (附 bugreport) | Android Framework | ODM -> Google |
| P1 | 調整 LMK 參數保護前景 I/O App | Kernel/Vendor | BSP 團隊 |
| P1 | 降低 vm.dirty_ratio / dirty_background_ratio | Kernel | BSP 團隊 |
| P2 | 評估增加 ZRAM 至 6GB | Vendor | BSP 團隊 |
| P2 | 建議 Google 實作 chunked I/O + memory-aware throttling | App | Google Files 團隊 |

---

## 6. 向 Google 回報建議

**Title:** OOM kills foreground Files by Google during large USB-to-internal file copy

**Component:** Android > Framework > ActivityManager (or Storage)

**附件:** 兩份完整 bugreport

**關鍵 Log 證據：**
```
oom_reaper: reaped process 4796 (.apps.nbu.files)
am_proc_died: [0,4796,com.google.android.apps.nbu.files,0,2]
process kill reason=3 (LOW_MEMORY) subreason=0 (UNKNOWN)
256+ oom_reaper events in single bugreport session
kswapd at 14% CPU continuously
```
