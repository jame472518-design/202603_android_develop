# Android OOM ADJ 優先級對照表

數值越低，優先級越高，越不容易被 OOM Killer 殺掉。

| ADJ 等級 | 優先權 | 行程類型 |
|---------|--------|---------|
| NATIVE_ADJ | -1000 | 由 init 處理程序 fork 出來的 native 處理程序，並不受 system 管控 |
| SYSTEM_ADJ | -900 | 僅指 system_server 處理程序 |
| PERSISTENT_PROC_ADJ | -800 | 系統 persistent 處理程序，在 AndroidManifest.xml 中申明 |
| PERSISTENT_SERVICE_ADJ | -700 | 關聯著 system_server 或 persistent 的處理程序 |
| **FOREGROUND_APP_ADJ** | **0** | **前台處理程序。正在展示的 APP，存在互動介面** |
| VISIBLE_APP_ADJ | 100 | 可見處理程序 |
| PERCEPTIBLE_APP_ADJ | 200 | 可感知處理程序。比如後台音樂播放，過 startForeground 設定 |
| BACKUP_APP_ADJ | 300 | 備份處理程序 |
| HEAVY_WEIGHT_APP_ADJ | 400 | 後台的重量級程序。system/rootdir/init.rc 檔案中設定 |
| SERVICE_ADJ | 500 | 服務處理程序（Service process） |
| HOME_APP_ADJ | 600 | Home 處理程序 |
| PREVIOUS_APP_ADJ | 700 | 上一個處理程序 |
| SERVICE_B_ADJ | 800 | B List 中的 Service |
| CACHED_APP_MIN_ADJ | 900 | 不可見處理程序的 adj 最小值 |
| CACHED_APP_MAX_ADJ | 906 | 不可見處理程序的 adj 最大值 |

## 與本 Case 的關係

- Files by Google **使用中** → `oom_score_adj = 0` (FOREGROUND_APP_ADJ) → 最後才被殺
- Files by Google **在背景** → `oom_score_adj = 905` (接近 CACHED_APP_MAX_ADJ) → 最先被殺

來源：[learn-house.idv.tw — Android LowMemoryKiller](https://learn-house.idv.tw/?p=3998)
