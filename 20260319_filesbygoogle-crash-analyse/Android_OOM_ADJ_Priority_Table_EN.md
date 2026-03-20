# Android OOM ADJ Priority Table

Lower value = higher priority = less likely to be killed by OOM Killer.

| ADJ Level | Priority | Process Type |
|-----------|----------|-------------|
| NATIVE_ADJ | -1000 | Native process forked by init, not managed by system |
| SYSTEM_ADJ | -900 | system_server process only |
| PERSISTENT_PROC_ADJ | -800 | System persistent process, declared in AndroidManifest.xml |
| PERSISTENT_SERVICE_ADJ | -700 | Process associated with system_server or persistent process |
| **FOREGROUND_APP_ADJ** | **0** | **Foreground process. Currently displayed app with user interaction** |
| VISIBLE_APP_ADJ | 100 | Visible process |
| PERCEPTIBLE_APP_ADJ | 200 | Perceptible process. e.g. background music playback via startForeground |
| BACKUP_APP_ADJ | 300 | Backup process |
| HEAVY_WEIGHT_APP_ADJ | 400 | Heavy-weight background process. Configured in system/rootdir/init.rc |
| SERVICE_ADJ | 500 | Service process |
| HOME_APP_ADJ | 600 | Home (Launcher) process |
| PREVIOUS_APP_ADJ | 700 | Previous app process |
| SERVICE_B_ADJ | 800 | B-list Service |
| CACHED_APP_MIN_ADJ | 900 | Minimum adj for invisible (cached) processes |
| CACHED_APP_MAX_ADJ | 906 | Maximum adj for invisible (cached) processes |

## Relevance to This Case

- Files by Google **in use** → `oom_score_adj = 0` (FOREGROUND_APP_ADJ) → killed last
- Files by Google **in background** → `oom_score_adj = 905` (near CACHED_APP_MAX_ADJ) → killed first

Source: [learn-house.idv.tw — Android LowMemoryKiller](https://learn-house.idv.tw/?p=3998)
