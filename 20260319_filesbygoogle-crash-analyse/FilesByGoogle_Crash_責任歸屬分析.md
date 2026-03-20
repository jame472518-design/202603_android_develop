# Files by Google Crash 責任歸屬詳細分析

**日期:** 2026-03-19
**裝置:** Thorpe DVT3 (T70)
**問題:** Files by Google 在大量 USB 檔案複製時被 OOM Killer 強制終止

---

## 結論

這是一個**多層級共同責任**的問題，但主要責任在 **Linux Kernel 記憶體管理** 與 **Android Framework (LMKD)**。

---

## 責任分配總覽

| 責任方 | 佔比 | 具體問題 | 應該做什麼 |
|--------|------|----------|-----------|
| **Linux Kernel (記憶體管理)** | 40% | OOM Killer 不應殺前景 App；dirty page 管理不當 | 調整 dirty_ratio、優化 OOM Killer 的 adj 判斷 |
| **Android Framework (LMKD)** | 25% | LMKD 未保護前景 I/O App | 向 Google 回報，改善 LMKD 對前景 I/O 的保護 |
| **Android FUSE 架構** | 20% | FUSE 雙重 buffer 大幅增加記憶體消耗 | Google 長期架構問題，短期無法改變 |
| **Files by Google (App)** | 10% | 缺乏 memory-aware 複製策略 | 建議 Google 實作 chunked I/O |
| **ODM/BSP (Thorpe)** | 5% | RAM/ZRAM 配置、dirty_ratio 參數 | 調整 kernel 參數、評估增加 ZRAM |

---

## 各層級責任詳細拆解

### 1. Linux Kernel (記憶體管理) — 主要責任 40%

#### 為什麼是 Kernel 的問題

- Kernel 的 OOM Killer 選擇了**正在前景運行的 App** 來殺，這是不合理的行為
- 正常情況下，OOM Killer 應該優先殺 background/cached 進程，而非 foreground TOP 進程
- Log 證據顯示 OOM Killer 在同一秒內回收了 64~71 個進程，說明記憶體管理已經完全失控，不是漸進式的 graceful degradation

#### 具體問題

| 問題 | 說明 |
|------|------|
| `vm.dirty_ratio` 設定不當 | 目前 `target_dirty_ratio=80`，允許 80% 可回收記憶體被 dirty pages 佔用，太高了 |
| USB I/O dirty pages 擠壓 | 大量 USB I/O 導致 dirty pages 佔用過多 page cache，擠壓了其他進程的記憶體 |
| kswapd 搶救不及 | kswapd 持續 14% CPU 表示 kernel 一直在搶救記憶體但來不及回收 |
| OOM Killer adj 判斷失誤 | 前景 TOP 進程的 oom_adj 應該是最低優先被殺的，但保護機制失效 |

#### Log 證據

```
oom_reaper: reaped process 4796 (.apps.nbu.files)  ← 前景 App 被殺
reason=3 (LOW_MEMORY) subreason=0 (UNKNOWN)
kswapd0:1: 14% CPU, kswapd-1:0: 13% CPU            ← 持續高壓
256+ oom_reaper events                               ← 大量進程被回收
```

#### 建議修復

1. 調低 `target_dirty_ratio` 從 **80 → 40~50**
2. 調低 `dirty_reclaim_rate` 從 **0.5 → 0.3**
3. 優化 OOM Killer 的 oom_adj 評分，確保前景 TOP 進程有更強的保護

---

### 2. Android Framework (LMKD / ActivityManager) — 次要責任 25%

#### 為什麼是 Framework 的問題

- Android 的 Low Memory Killer Daemon (LMKD) 的職責就是在記憶體不足時**有序地**殺進程
- LMKD 應該保護 `oom_adj` 為前景 (fg TOP) 的進程不被殺
- 但從 log 看，LMKD 的保護機制失效了 — 前景正在複製檔案的 App 還是被殺了

#### 具體問題

| 問題 | 說明 |
|------|------|
| LMKD reinit | `lmkd --reinit` 在 crash 前執行，說明 LMKD 自己也出了狀況 |
| 前景 I/O 無保護 | Framework 沒有針對「前景 App 正在進行大量 I/O」的額外保護機制 |
| mem-pressure-event 失效 | `mem-pressure-event` 頻繁觸發但未能有效阻止前景 App 被殺 |

#### Log 證據

```
init: processing action (lmkd.reinit=1)                              ← LMKD 被重新初始化
init: starting service 'exec 37 (/system/bin/lmkd --reinit)'
Rescheduling restart of crashed service ... for mem-pressure-event    ← 記憶體壓力事件頻繁
```

#### 建議修復

- 向 Google Issue Tracker 回報 Bug
- 分類建議：**Android > Framework > ActivityManager** 或 **Android > Framework > Storage**
- 強調 LMKD 應保護正在進行 I/O 的前景 App

---

### 3. Android Storage / FUSE — 次要責任 20%

#### 為什麼是 FUSE 的問題

- Android 11+ 強制使用 FUSE (Filesystem in Userspace) 來掛載 `/storage/emulated`
- FUSE 的架構本身就比 direct I/O 多消耗約 **2-3 倍記憶體**：
  - 每次 read/write 需要 kernel → userspace (MediaProvider) → kernel 的雙重 buffer
  - `ExternalStorageServiceImpl` 作為 FUSE daemon 也需要額外記憶體
- 複製 24.7GB 檔案通過 FUSE 的記憶體開銷遠大於直接寫入

#### 影響說明

這是 **Google 的架構決策**，為了 scoped storage 的安全性而犧牲了 I/O 效率。短期內無法改變，但 Google 每個 Android 版本都在優化 FUSE 效能。

#### FUSE I/O 路徑圖示

```
USB Storage → Kernel VFS → FUSE Daemon (MediaProvider) → Kernel VFS → Internal Storage
                              ↑                    ↑
                          額外 buffer            額外 context switch
                          記憶體消耗             CPU 消耗
```

---

### 4. Files by Google (App) — 輕微責任 10%

#### 為什麼 App 也有一點責任

- 作為執行大量檔案複製的 App，理應實作 memory-aware 的複製策略
- 可以使用 `ComponentCallbacks2.onTrimMemory()` 來響應記憶體壓力
- 可以實作 chunked I/O，分批複製而非一次性大量寫入
- 可以在記憶體壓力時主動暫停複製、提示使用者

#### 但為什麼責任很輕

App 被 OOM Killer **直接殺掉**，連 `onTrimMemory()` 都來不及收到就死了，所以 App 層能做的有限。這是系統層級的暴力終止，App 無法防禦。

#### 建議改善

- 建議 Google Files 團隊實作 chunked I/O with backpressure
- 在開始大量複製前檢查可用記憶體
- 實作 memory pressure callback 以在壓力時降速

---

### 5. ODM / BSP 團隊 (Thorpe 裝置) — 配置責任 5%

#### 為什麼 ODM 也有一點責任

| 配置項 | 現況 | 問題 |
|--------|------|------|
| RAM | 7.1 GB | 對於支援 USB 大量檔案傳輸的使用場景可能偏低 |
| ZRAM | 4 GB | 在大量 I/O 時不足以緩衝 |
| `target_dirty_ratio` | 80 | 太高，允許 80% 的可回收記憶體被 dirty pages 佔用 |
| `dirty_reclaim_rate` | 0.5 | 可以更積極回收 |

#### 建議調整

1. 調低 `target_dirty_ratio` 從 **80 → 40~50**
2. 調低 `dirty_reclaim_rate` 從 **0.5 → 0.3**
3. 評估增加 ZRAM 從 **4GB → 6GB**
4. 測試以上調整是否能緩解問題

---

## 行動計劃

### Phase 1: 立即行動（ODM 可自行處理）

- [ ] 調低 `target_dirty_ratio` 從 80 → 40~50
- [ ] 調低 `dirty_reclaim_rate` 從 0.5 → 0.3
- [ ] 評估增加 ZRAM 從 4GB → 6GB
- [ ] 在 Thorpe 裝置上測試以上調整
- [ ] 驗證：反覆進行 USB → 內部儲存複製 24.7GB 測試，確認不再閃退

### Phase 2: 需要 Google 介入

- [ ] 向 Google Issue Tracker 提交 Bug Report
  - **Title:** OOM kills foreground Files by Google during large USB-to-internal file copy
  - **Component:** Android > Framework > ActivityManager (or Storage)
  - **附件:** 兩份完整 bugreport
- [ ] 強調以下重點：
  - LMKD 應保護正在進行 I/O 的前景 App
  - 前景 TOP 進程不應被 OOM Killer 殺掉
  - FUSE 架構下大量 I/O 的記憶體消耗過高
- [ ] 建議 Google Files 團隊實作 chunked I/O

### Phase 3: 長期追蹤

- [ ] 追蹤 Google 對 FUSE I/O 效率的改善（每個 Android 版本都有 FUSE 優化）
- [ ] 確認是否在後續 Android 版本中修復 LMKD 保護機制
- [ ] 監控 Thorpe 裝置上調整參數後的長期穩定性

---

## Google Issue Tracker 回報範本

### Title
OOM kills foreground Files by Google during large USB-to-internal file copy on 7GB RAM device

### Description

```
## Summary
Files by Google (com.google.android.apps.nbu.files) is killed by Linux Kernel OOM Killer
while actively copying files from USB storage to internal storage in the foreground.

## Steps to Reproduce
1. Connect a USB-C flash drive (32GB/64GB SanDisk) with 10x 2.47GB ZIP files
2. Open Files by Google, browse USB storage
3. Select all files and copy to internal storage
4. Repeat fill/delete/reboot cycle 10-15 times
5. Files by Google crashes (OOM killed) during copy

## Device Info
- Device: Thorpe DVT3 (T70)
- Build: AQ3A.250408.001
- RAM: ~7.1 GB + 4 GB ZRAM
- Android version: [version]

## Expected Behavior
Files by Google should complete the file copy without being killed.
Foreground TOP process should be protected from OOM Killer.

## Actual Behavior
Files by Google is killed by OOM Killer with reason=3 (LOW_MEMORY).
71 processes reaped in the same second, indicating catastrophic memory exhaustion.

## Key Log Evidence
oom_reaper: reaped process 4796 (.apps.nbu.files)
ActivityManager: Process com.google.android.apps.nbu.files (pid 4796) has died: fg TOP
process kill reason=3 (LOW_MEMORY) subreason=0 (UNKNOWN)
kswapd at 14% CPU continuously
256+ oom_reaper events in single bugreport session
lmkd --reinit executed before crash

## Root Cause Analysis
1. Large USB I/O via FUSE causes excessive page cache / dirty page consumption
2. LMKD fails to protect foreground TOP process performing I/O
3. OOM Killer inappropriately selects foreground app for termination
4. target_dirty_ratio=80 allows too much memory to be consumed by dirty pages

## Attachments
- bugreport-T70-AQ3A.250408.001-2026-02-09-15-45-18.zip
- bugreport-T70-AQ3A.250408.001-2026-02-11-13-01-30.zip
```

### Suggested Component
Android > Framework > ActivityManager
or
Android > Framework > Storage

---

## 附錄：記憶體壓力時間線

### BugReport #1 (2026-02-09) 時間線

```
[時間軸] 記憶體壓力累積過程
────────────────────────────────────
15:30:xx  USB 複製開始，page cache 開始累積
   ...    kswapd CPU 逐漸升高到 14%
   ...    dirty pages 持續增加（dirty_ratio=80 允許大量累積）
   ...    LMKD 開始殺 background 進程
15:44:46  mem-pressure-event 頻繁觸發
15:44:47  OOM Killer 觸發，71 個進程在同一秒內被 reap
          → Files by Google (PID 4796) 被殺
15:44:47  ActivityManager 記錄: fg TOP process died
15:45:18  Bugreport 擷取
```

### BugReport #2 (2026-02-11) 時間線

```
[時間軸] 記憶體壓力累積過程（與 #1 高度相似）
────────────────────────────────────
12:50:xx  USB 複製開始
   ...    同樣的壓力累積模式
13:01:00  OOM Killer 觸發，64 個進程被 reap
          → Files by Google (PID 5170) 被殺
13:01:30  Bugreport 擷取
```

---

## 附錄：線上技術文章比對分析

以下比對線上已有的 Android OOM/LMK 技術文章，驗證本分析的正確性並標示差異。

### 1. Android 官方文件 — Memory Management

**來源：** [developer.android.com/topic/performance/memory-management](https://developer.android.com/topic/performance/memory-management)

**相關性：高**

官方文件明確指出：
- kswapd 在記憶體不足時將 dirty pages 移入 ZRAM 壓縮，釋放 RAM
- 系統先透過 `onTrimMemory()` 通知 App 減少記憶體使用
- 若不足以緩解，kernel 啟動 LMK 開始殺進程
- **「Killing the foreground app looks like an application crash」** — 與本 Case 完全吻合

**與本 Case 的關係：** 官方承認殺前景 App 看起來像 crash，但正常情況下前景 App 應是最後被殺的。本 Case 中保護機制失效。

---

### 2. AndroidPerformance — 低記憶體導致卡頓分析

**來源：** [androidperformance.com — Android Jank Due To Low Memory](https://androidperformance.com/en/2019/09/18/Android-Jank-Due-To-Low-Memory/)

**相關性：最高 — 與本 Case 最接近的分析**

| 比較項目 | 該文章 | 本 Case |
|---------|--------|---------|
| kswapd | kswapd 激活佔用 CPU，導致 I/O 放大 | kswapd 持續 14% CPU |
| I/O 阻塞 | `Uninterruptible Sleep` 從 130ms 飆到 750ms | USB→FUSE 大量 I/O 加劇問題 |
| 死亡-重啟循環 | LMK 頻繁殺進程，父進程立即重啟，惡性循環 | 256+ oom_reaper 事件，64-71 進程同秒被殺 |
| 核心洞察 | 低記憶體引發 **I/O 放大效應** | dirty_ratio=80 + FUSE 雙重 buffer = I/O 放大 |

**該文章提出的 11 項建議中，直接適用於本 Case 的：**
1. 調整 `extra_free_kbytes` 提高記憶體回收閾值
2. 調整 `swappiness` 平衡交換策略
3. 使用 cgroup blkio 限制背景 I/O
4. 改進 LMK 避免死亡-重啟循環
5. 調整 `read_ahead_kb` 避免過度預讀

---

### 3. learn-house — LowMemoryKiller 防止應用被殺

**來源：** [learn-house.idv.tw — Android LowMemoryKiller](https://learn-house.idv.tw/?p=3998)

**相關性：中等**

該文章詳細解釋了 LMKD 的 14 級 `oom_score_adj` 優先順序：

| 等級 | adj 值 | 說明 |
|------|--------|------|
| NATIVE_ADJ | -1000 | 原生進程，永不被殺 |
| PERSISTENT_PROC_ADJ | -800 | 持久進程（需 system 權限） |
| FOREGROUND_APP_ADJ | **0** | **前景 App — 本 Case 的 Files by Google** |
| CACHED_APP_MAX_ADJ | 906 | 快取 App，最先被殺 |

**與本 Case 的關係：**
- Files by Google 在 crash 時的狀態是 `fg TOP`（adj=0），理論上應是**倒數第二個**被殺的等級
- 但 OOM Killer 還是殺了它 — 說明記憶體壓力已經到了連 adj=0 都保護不了的程度
- 該文建議的 `android:persistent="true"` 解法不適用於第三方 App

---

### 4. 阿里雲 — Android OOM 解決方案

**來源：** [topic.alibabacloud.com — Android OOM 解決方案](https://topic.alibabacloud.com/tc/a/an-example-of-a-memory-overflow-solution-for-android-programming-oom-is-summarized-_android_1_21_20155919.html)

**相關性：低 — 不同類型的 OOM**

| | 該文章 | 本 Case |
|---|---|---|
| OOM 類型 | **App 層級** — Java Heap OOM | **系統層級** — Linux Kernel OOM Killer |
| 誰觸發的 | Dalvik/ART VM 拋出 `OutOfMemoryError` | Kernel `oom_reaper` 強制殺進程 |
| 原因 | App 載入太多/太大的 Bitmap | 系統整體 RAM 不足 |
| 症狀 | App crash 有 exception stack trace | App 直接消失，無 crash log |
| 解法 | 優化 Bitmap 管理、SoftReference、壓縮圖片 | 調 kernel 參數、改善 LMKD |

**結論：** 雖然都叫「OOM」，但發生在完全不同的層級。該文章的解法（Bitmap 優化）對本 Case 完全不適用。

---

### 5. Google AOSP — LMKD 官方文件

**來源：** [source.android.com/docs/core/perf/lmkd](https://source.android.com/docs/core/perf/lmkd)

**相關性：高**

LMKD 官方文件說明：
- LMKD 使用 kernel 的 `vmpressure` 事件或 PSI (Pressure Stall Information) 監控記憶體壓力
- 使用 memory cgroup 限制各進程的記憶體使用
- 根據 `oom_score_adj` 決定殺哪個進程

**與本 Case 的關係：** 本 Case 中 `lmkd --reinit` 在 crash 前被觸發，說明 LMKD 自身出了問題，需要重新初始化。這可能是 LMKD 保護機制失效的原因之一。

---

### 比對總結

| 文章 | 與本 Case 相同處 | 與本 Case 不同處 |
|------|----------------|----------------|
| Android 官方 | 確認殺前景 App = 看起來像 crash | 官方未提到 FUSE I/O 放大問題 |
| AndroidPerformance | kswapd 高負載、I/O 放大、死亡循環 | 該文聚焦卡頓，非 App 被殺 |
| learn-house | adj 優先順序機制吻合 | 解法 (persistent) 不適用第三方 App |
| 阿里雲 | 無 | 完全不同類型的 OOM |
| LMKD 官方 | vmpressure/PSI 機制 | 未提到 reinit 失效場景 |

**結論：** 線上有類似的系統層級分析，但**沒有完全一樣的場景**（USB 大量複製 + FUSE + dirty_ratio 過高 + LMKD reinit + 前景 App 被殺）。本 Case 的分析涵蓋了多個線上文章才能拼湊出的完整圖景。

---

*本文件為 Case 2 分析的一部分，搭配 `FilesByGoogle_Crash_分析報告.md` 閱讀。*
