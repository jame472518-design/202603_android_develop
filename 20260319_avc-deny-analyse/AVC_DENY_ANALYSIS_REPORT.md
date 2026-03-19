# AVC Deny 分析报告

**日期:** 2026-03-19
**平台:** T70 (AQ3A.250924.001)
**分析机台:** 5台 (Penny, WWANLog A/B/C, Frank)

---

## 1. 总览

| 机台 | AVC deny 总数 | SELinux 模式 | 备注 |
|------|-------------|-------------|------|
| Penny (60081) | 1,323 | **permissive=1** | nosim + kernel modem restart 测试 |
| Penny (80008) | 2,277 | **permissive=1** | nosim + kernel modem restart 测试 |
| WWANLog A | 400 | **permissive=0 (enforcing)** | Radio log |
| WWANLog B | 267 | **permissive=0 (enforcing)** | AP log |
| WWANLog C | 234 | **permissive=0 (enforcing)** | BSP log |
| Frank (logcat) | 221 | **permissive=0 (enforcing)** | Daily userbuild |
| Frank (logcat_radio) | 483 | **permissive=0 (enforcing)** | Daily userbuild |

**关键发现:** Penny 机台运行在 **permissive 模式** (只记录不阻止)，其余 4 台运行在 **enforcing 模式** (会实际阻止操作)。

---

## 2. 严重度分类

### 🔴 Critical — Enforcing 模式下被阻止，可能导致功能异常

#### 2.1 `hal_camera_default` 大量读取 property 被拒 (仅 Penny, permissive)
- **现象:** `hal_camera_default` 尝试 `{open getattr map}` 读取 **390 种** system property 文件
- **Root Cause:** Camera HAL 进程执行 `__system_property_foreach` 或类似全量属性扫描，但 SELinux policy 未授权 `hal_camera_default` 读取这些 property 文件
- **影响:** 在 Penny 上因 permissive 模式未被阻止；若切到 enforcing **Camera 可能无法正常工作**
- **修复:** 需要在 `hal_camera_default.te` 中添加 `get_prop` 宏或精确授权

#### 2.2 `radio` 进程 set property 被拒
```
radio -> vendor_ctl_rild_prop [property_service] {set}  — 5台机器
radio -> ctl_restart_prop [property_service] {set}       — 4台机器
```
- **Root Cause:** Radio (RIL) 进程尝试 set `vendor.ctl.rild` 和 `ctl.restart` 属性但未授权
- **影响:** 在 enforcing 模式下 **modem restart 流程可能失败**，这与 Penny 的 "kernel modem restart" 测试场景直接相关
- **修复:** `radio.te` 添加 `set_prop(radio, vendor_ctl_rild_prop)` 和 `set_prop(radio, ctl_restart_prop)`

#### 2.3 `vendor_init` 多个 property set 被拒
```
vendor_init -> build_prop [property_service] {set}            — ro.adb.secure
vendor_init -> default_prop [property_service] {set}          — persist.backup.ntpServer, persist.demo.hdmirotationlock
vendor_init -> vendor_mm_parser_prop [property_service] {set} — vendor.mm.enable.qcom_parser
vendor_init -> usb_prop [property_service] {set}
vendor_init -> persist_debug_prop [file] {read}
vendor_init -> vendor_ipa_dev [file] {create write open}
```
- **Root Cause:** vendor init.rc 中的 property 设置和设备节点创建缺少对应的 SELinux 规则
- **影响:** 开机初始化阶段部分配置无法生效

#### 2.4 `netd` 写入 system_file 被拒
```
netd -> system_file [dir] {add_name}
netd -> system_file [file] {create}
```
- **Root Cause:** `netd` 试图在 `/system` 分区下创建 `xtables.lock` 文件
- **影响:** iptables 操作可能失败，**影响网络功能**

#### 2.5 `secure_element` 写入 system_data_file 被拒
```
secure_element -> system_data_file [dir] {add_name remove_name}
secure_element -> system_data_file [file] {create write open rename unlink}
```
- **Root Cause:** SecureElement 服务的 HeapTaskDaemon 创建临时文件时使用了未授权的 label
- **影响:** NFC SecureElement 功能可能异常

---

### 🟡 Medium — 跨所有机器共现，影响子系统

#### 2.6 `system_server` 读取 vendor property 被拒 (最高频)
```
system_server -> vendor_default_prop [file] {read}  — 出现 ~460 次，所有6台机器
system_server -> camera2_extensions_prop [file] {read}
system_server -> vendor_wfd_sys_debug_prop [file] {read}
system_server -> vendor_hal_perf2_service [service_manager] {find}
system_server -> system_server [capability] {sys_module}
```
- **Root Cause:** system_server 查询 vendor property 时缺少 `get_prop` 权限
- **影响:** 部分 vendor 功能特性查询失败，性能调优 (perf2) 不可用

#### 2.7 `vendor_hal_perf2_service` 大量 find 被拒
```
lmkd -> vendor_hal_perf2_service [service_manager] {find}
surfaceflinger -> vendor_hal_perf2_service [service_manager] {find}
system_server -> vendor_hal_perf2_service [service_manager] {find}
vendor_perfservice -> vendor_hal_perf2_service [service_manager] {find}
vendor_wlc_app -> vendor_hal_perf2_service [service_manager] {find}
```
- **Root Cause:** Qualcomm perf2 HAL 服务的 service_manager label 未被授权给多个 client
- **影响:** 性能调优 boost 功能不可用

#### 2.8 NFC 相关
```
nfc -> vendor_nfc_vendor_data_file [dir] {search}
nfc -> vendor_nfc_vendor_data_file [file] {read open}
nfc -> default_android_service [service_manager] {find}  — vendor.nxp.emvco
hal_nfc_default -> vendor_nfc_vendor_data_file [dir] {search}
```
- **Root Cause:** NFC HAL 和 NFC service 缺少对 vendor NFC 数据目录的访问权限
- **影响:** NFC/EMVCo 功能可能不正常

#### 2.9 `surfaceflinger` / `bootanim` 访问 vendor HAL
```
surfaceflinger -> vendor_sys_gpp_prop [file] {read open getattr map}
surfaceflinger -> vendor_hal_qspmhal_default [binder] {call}
bootanim -> vendor_sys_gpp_prop [file] {read open getattr map}
bootanim -> vendor_hal_qspmhal_default [binder] {call}
```
- **Root Cause:** Display 通路调用 vendor QSPM HAL 缺少 binder 权限
- **影响:** 显示相关的 vendor 扩展功能可能异常

---

### 🟢 Low — 开机/工具类，影响有限

| Source | Target | Action | 说明 |
|--------|--------|--------|------|
| `linkerconfig` | `linkerconfig` | `capability {kill}` | 开机 linker namespace 配置 |
| `fsck` | `fsck` | `capability {kill}` | 文件系统检查 |
| `vdc` | `vdc` | `capability {kill}` | Volume daemon |
| `e2fs` | `e2fs` | `capability {kill}` | ext4 工具 |
| `init` | `debugfs_tracing_debug` | `dir {mounton}` | Trace 挂载 |
| `hal_bootctl_default` | `gsi_metadata_file` | `dir {search}` | GSI 检查 |
| `gmscore_app` | `adbd_prop`/`system_adbd_prop` | `file {read}` | GMS 读取 adb 属性 |
| `dex2oat` | `privapp_data_file`/`system_data_file` | `dir {search}` | 编译优化时搜索目录 |
| `shell` | `kernel` | `system {syslog_read}` | 调试用 |
| `su` | `bt_firmware_file`/`firmware_file` | `filesystem {getattr}` | su 权限 |

---

## 3. Root Cause 分析

### 核心问题：SELinux Policy 未跟上 Vendor HAL/Service 的更新

1. **Qualcomm vendor HAL 新增服务未配套 policy:**
   - `vendor_hal_perf2_service` (性能调优)
   - `vendor_hal_qspmhal_default` (QSPM 显示)
   - `vendor_nfc_vendor_data_file` (NFC 数据)
   这些是 Qualcomm BSP 带来的新组件，需要在 `device/<vendor>/<device>/sepolicy/` 中添加对应规则

2. **hal_camera_default 权限过窄:**
   Camera HAL 执行全量 property 扫描（可能是 Qualcomm camera lib 的行为），但 SELinux policy 只授予了少量 property 读取权限。需要添加 `get_prop(hal_camera_default, ...)` 或使用 `vendor_property_type` macro

3. **radio/vendor_init property 规则缺失:**
   RIL 相关的 property 控制（modem restart）未在 policy 中定义

4. **Penny 机台使用 permissive 模式掩盖了问题:**
   Penny 的 3,600 条 deny 全部是 `permissive=1`，意味着操作实际被允许了。一旦切换到 enforcing 将有大量功能中断

---

## 4. 建议修复方案

### 优先级 P0 — 立即修复 (影响核心功能)

```bash
# 1. radio.te — 修复 modem restart
allow radio vendor_ctl_rild_prop:property_service { set };
allow radio ctl_restart_prop:property_service { set };

# 2. vendor_init.te — 修复开机初始化
set_prop(vendor_init, vendor_mm_parser_prop)
set_prop(vendor_init, default_prop)  # persist.backup.ntpServer
allow vendor_init vendor_ipa_dev:file { create write open };

# 3. netd.te — 修复网络
allow netd system_file:dir { add_name };
allow netd system_file:file { create };
# 或重新标记 xtables.lock 的路径
```

### 优先级 P1 — 尽快修复 (影响子系统)

```bash
# 4. system_server.te
get_prop(system_server, vendor_default_prop)
get_prop(system_server, camera2_extensions_prop)
allow system_server vendor_hal_perf2_service:service_manager { find };

# 5. vendor_hal_perf2 clients
allow lmkd vendor_hal_perf2_service:service_manager { find };
allow surfaceflinger vendor_hal_perf2_service:service_manager { find };

# 6. NFC
allow nfc vendor_nfc_vendor_data_file:dir { search };
allow nfc vendor_nfc_vendor_data_file:file { read open };
allow hal_nfc_default vendor_nfc_vendor_data_file:dir { search };

# 7. Display HAL
allow surfaceflinger vendor_hal_qspmhal_default:binder { call };
allow bootanim vendor_hal_qspmhal_default:binder { call };
```

### 优先级 P2 — 后续清理

```bash
# 8. hal_camera_default — 需要评估是否真的需要读取所有 property
#    方案A: 授权必要的 property (推荐)
#    方案B: 修复 camera HAL 代码，避免全量扫描

# 9. capability {kill} — linkerconfig, fsck, vdc, e2fs
allow linkerconfig linkerconfig:capability { kill };
allow fsck fsck:capability { kill };
allow vdc vdc:capability { kill };
```

---

## 5. 验证方法

```bash
# 1. 收集 deny log
adb shell dmesg | grep "avc:  denied"
adb logcat -b all | grep "avc:  denied"

# 2. 使用 audit2allow 生成 policy
adb shell dmesg | audit2allow -p policy

# 3. 编译并刷入 sepolicy 后验证
adb shell getenforce  # 确认 Enforcing
adb shell dmesg | grep -c "avc:  denied"  # 应该为 0 或大幅减少
```

---

## 6. 总结

**五台机器共出现 ~5,205 条 AVC deny，涉及 ~40 个 source domain、~450 个独立规则。**

最关键的问题是：
1. **hal_camera_default** 全量扫描 property (390 条规则) — 需要 camera HAL 团队配合
2. **radio/modem restart** property 设置被拒 — 直接影响 modem restart 功能
3. **vendor_hal_perf2_service** 被 5 个 client 查找失败 — 性能调优功能失效
4. **NFC** 数据目录访问被拒 — NFC 功能异常

建议按 P0 > P1 > P2 的优先级逐步修复 sepolicy 规则。
