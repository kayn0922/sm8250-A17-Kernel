# sm8250 A17 内核工程（elish / enuma / dagu，内置 SukiSU）

目标：为刷了 **HyperOS 4（OS4，Android 17）移植包** 的小米平板 5 Pro 系列，
构建一颗能启动 A17、内置 SukiSU（ReSukiSU）、并把 GPS 内核侧配置补到最全的可刷内核。

> 结论先行：**能构建，而且不用从零拼源码**——你提到的几个来源已经有一套「集大成」的树。
> 但 **GPS 大概率不是内核能修的**，请先做 `GPS_DIAGNOSIS.md` 里的分层诊断，再决定要不要刷内核。

---

## 1. 源码谱系（2026-11-10 用 GitHub API 逐个核实）

| 你提到的 | 实际仓库 | 默认分支 | 在这套方案里的角色 |
|---|---|---|---|
| `HuberyBro.ok` | `HuberyBrook/kernel_xiaomi_sm8250_mod` | `android14-lineage22-mod` | fork 自 yspbwx2010，A14/22 时期分支 |
| `yspbwx2021` | `yspbwx2010/kernel_xiaomi_sm8250_mod` | `lunar-release` | 早期 mod 树；贡献了 Actions 构建思路 |
| `UtsavBalar1231` | `UtsavBalar1231/kernel_xiaomi_sm8250` | `android14-stable` | CLO rebased，**小米私有驱动（触屏/相机/音频/Display/CNSS2）来源** |
| 小米 MiCode | `MiCode/Xiaomi_Kernel_OpenSource`（`elish-r-oss`，4.19.113） | — | 出厂源码，**Airoha/BCM4775 GPS 驱动来源** |

**集大成者**：`ymdzq/kernel_xiaomi_sm8250_mod` 分支 `android16-aptusitu`
（和本项目之前用的 TWRP 设备树是同一作者）。它的 README 与 `build.sh` 头部写明：
基于 `LineageOS/android_kernel_xiaomi_sm8250` 的 `lineage-23`，HyperOS/MIUI 所需代码与设备驱动
对照 `liyafe1997/kernel_xiaomi_sm8250_mod` 的提交记录摘取，源头正是 UtsavBalar1231 与 MiCode；
`build.sh` 第 3–6 行还直接致谢了 UtsavBalar1231、liyafe1997、yspbwx2010。

所以本工程**以 ymdzq 树为基线**，而不是把四个来源重新缝合——后者会产生大量冲突且没有收益。

---

## 2. 机型代号：先纠正一个容易致命的混淆

| 代号 | 机型 | GPS 硬件（已核对 DTS / defconfig） |
|---|---|---|
| `elish` | 小米平板 5 Pro **WiFi**（11"） | 外置 BCM4775/Airoha GPS 芯片；`elish-sm8250.dtsi` 有 `bcm4775` 节点 + `gps-ldo = <&tlmm 46 ...>` |
| `enuma` | 小米平板 5 Pro **5G** | **没有** `bcm4775` 节点；走 5G modem 的 GNSS（`CONFIG_ESOC*`、`CONFIG_ESOC_MDM_4x` + QRTR/QMI） |
| `dagu` | 小米平板 5 Pro **12.4"** | `dagu-sm8250.dtsi` 里 `bcm4775` 节点被整段注释掉 |

> 之前会话里把「elish = 12.4 寸」当作前提，那是错的：12.4 寸是 `dagu`。
> 三者的 defconfig 都开了 `CONFIG_AIROHA_GPS=y`、`CONFIG_QRTR*`、`CONFIG_QCOM_QMI_HELPERS`、
> `CONFIG_RPMSG_QCOM_GLINK_SMEM`，**但硬件与 DTS 不同**。刷错机型内核会黑屏 / 触控异常，
> GPS 表现也完全不同。

**必须先确认你手里那台到底是哪一个**（`adb shell getprop ro.product.device` 或看 fastboot 机型）。
本工程默认**并行编译 `elish` 与 `enuma` 两份**（`devices=elish+enuma`）；只需其中一台时把 `devices` 改成对应代号，需要 12.4" 时用 `elish+enuma+dagu`。

---

## 3. OS4 / ROM 侧的两个硬约束

1. **HyperOS / MIUI 必须刷 MIUI 版内核包。** ymdzq README 明确警告：AOSP 版使用 LineageOS 的
   Display/DRM 驱动，在 HyperOS/MIUI 上屏幕无法显示，「默认不受理这条反馈」。
   本工程 `target_system` 默认 `miui`，只产出 `Kernel_MIUI_*.zip`。
2. **内核 zip 不含 `dtbo.img`，也不要刷 dtbo。** 用原厂 dtbo 或 ROM 包自带的 dtbo。
   这条对 GPS 很关键：dtbo 里若丢了 `bcm4775` 节点，GPS 芯片根本没上电。

OS4 是 HyperOS 4（Android 17）从 Pad 8 Pro / Pad 6 系列移植过来的第三方包，
公开更新说明提到 HIDL→AIDL 架构迁移、SELinux 规则补丁、以及「Pad 5 Pro 12.4 的更新主要动内核」。

---

## 4. 「支持 A17」的准确含义

- 非 GKI 的 4.19 内核跑 A17 **没有硬性版本门槛**：XDA 上 web1n 的
  `LineageOS 24 (A17) for elish` 用的就是 4.19.325，那是 LOS 分支基线，不是 A17 强制要求。
- 已逐项核对 ymdzq 的 `enuma_defconfig`，A16/A17 framework 需要的内核能力**全都已开**：
  `CONFIG_BPF_SYSCALL`、`CONFIG_BPF_JIT`、`CONFIG_CGROUP_BPF`、`CONFIG_BPF_LSM`、`CONFIG_BPF_PRELOAD`、
  `CONFIG_ANDROID_BINDERFS`、`CONFIG_ANDROID_VENDOR_HOOKS`、`CONFIG_SECCOMP`、`CONFIG_PSI`，
  外加 5.10 BPF 回移（README 特性第 6 条）。
- 官方 `LineageOS/...sm8250` 的 `lineage-24.0`（4.19.325 + CIP 稳定补丁）相对
  `lineage-23.2` 领先 **2229 个提交 / 300 个文件**，绝大多数是上游 4.19 稳定版与 CVE 修复，
  **不是 A17 的启动前提**。后续若要「完整 A17 化」，可选择性 cherry-pick 安全补丁，
  但风险高、收益低，本工程不做。

所以本工程产出的是 **A17-ready**（能启动、内置 SukiSU、GPS 内核侧全开），
不是「LineageOS 官方 A17 内核」。

---

## 5. 内置 SukiSU：现成的，不用自己打补丁

- ymdzq 树用 **ReSukiSU**（SukiSU Ultra 的 fork，支持 KPM）+ **SuSFS**。
  SukiSU Ultra 官方明确支持非 GKI / 4.x–5.4 内核，Manager 覆盖 Android 10–17。
- `build.sh <device> ksu` 会：
  1. `curl .../ReSukiSU/main/kernel/setup.sh | bash` 挂进内核构建系统；
  2. 打 SuSFS inline-hook 补丁、集成 Baseband-guard；
  3. `CONFIG_KSU` / `KSU_SUSFS` / `KPM` / `KALLSYMS_ALL` 全开；
  4. 编译后用 `SukiSU_KernelPatch_patch` 修 Image；
  5. 打成 AnyKernel3 zip。
- 刷完装 **ReSukiSU Manager** APK 即可；`noksu` 版则留给 Magisk / APatch。

---

## 6. GPS：内核能修什么，不能修什么

| 层 | 内核能否修 | 本工程做的 |
|---|---|---|
| 内核配置 `AIROHA_GPS` / QRTR / QMI / GLINK / DIAG | ✅ | `apply_patches.sh` 幂等强制开启 |
| `dtb` 里的 `bcm4775` 节点（给 GPS 芯片上电） | ✅ | elish DTS 已带；dagu 可选恢复最小节点 |
| **dtbo** 被 ROM 换成别的机型 | ❌（zip 不刷 dtbo） | 只能改用原厂 dtbo |
| vendor GNSS HAL（`android.hardware.gnss*`、`libloc_api`）、`gps.conf`、GNSS 固件 | ❌ | 换/补 ROM 包或 vendor |
| HyperOS4 framework 请求不存在的 Qualcomm GNSS 扩展 / 私有定位守护进程 | ❌ | ROM 移植方修（同类问题在 HyperOS-AVD 项目里已修过） |
| 权限、省电策略、AGPS 数据 | ❌ | 设置里排查 |

**判断**：内核侧该开的都已经开了，所以「GPS 不可用」更可能出在 vendor/dtbo/framework 层。
刷本工程的内核包仍有价值（尤其 elish：自带正确 dtb 与 Airoha 驱动，
如果 ROM 的 dtbo 丢了 `bcm4775` 节点，有机会把 GPS 芯片重新上电），但**不是保证修复**。

---

## 7. 一键云编译

仓库：`https://github.com/kayn0922/sm8250-A17-Kernel`

网页操作：Actions → **Build A17 Kernel (SukiSU)** → Run workflow，参数：

| 输入 | 默认 | 说明 |
|---|---|---|
| `devices` | `elish+enuma` | **并行构建**：每个代号一个 job + 一个 Release；也可单选 `elish` / `enuma`，或 `elish+enuma+dagu` |
| `ksu` | `ksu` | `ksu`=ReSukiSU+SuSFS+KPM；`rksu`=RKSU；`noksu`=留给 Magisk/APatch |
| `target_system` | `miui` | **HyperOS4 必须 miui**；`aosp` 仅类原生 ROM；`both` 两个都编 |
| `stability_fixes` | `true` | 应用稳定性补丁；设 `false` 编一份未打补丁的 A/B 对照内核 |
| `gps_dts_fix` | `none` | `dagu-minimal-node` = 给 dagu 的 DTS 注入最小 `bcm4775` 节点（实验性，见下） |
| `wifi_share_fix` | `true` | 跳过 `esoc0` 的耦合 SSR 重启 + 应用 `enuma_elish_wifi_share.config`；设 `false` 编对照内核（见第 12 节） |

命令行（本机，REST API；默认直连，需要代理时设 `GH_PROXY`）：

```bash
GH_TOKEN=<token> python scripts/github_api.py publish
GH_TOKEN=<token> python scripts/github_api.py dispatch --devices elish+enuma --ksu ksu --system miui --stability true --wifi-share true
GH_TOKEN=<token> python scripts/github_api.py status
GH_TOKEN=<token> python scripts/github_api.py download --devices elish,enuma
```

> **刷错机型会黑屏 / 触控异常**：`elish` = Pad 5 Pro WiFi，`enuma` = 5G，`dagu` = 12.4"。
> Release tag 形如 `kernel-<run_id>-<device>`，每个设备各自的 `Kernel_MIUI_<device>_*.zip`。

workflow 直接浅克隆 ymdzq 内核源码 + ZyC-Clang 22，在 GitHub Actions 上编译，
产物以 Release 里的 `Kernel_MIUI_<device>_SukiSU_*_anykernel3_*.zip` 发布。约 1–3 小时。

---

## 8. 刷入、验证与回退（必读）

1. 备份：原机 `boot.img`（含当前内核）、`dtbo.img`、`persist`，以及 `/data`。
2. **确认机型代号**；不确定就别刷。
3. 在 TWRP / recovery 里刷 `Kernel_MIUI_*.zip`（AnyKernel3）；**不要**单独刷 dtbo，**不要** `fastboot flash boot` 覆盖。
4. 首次启动后装 ReSukiSU Manager，确认 root 可用；如黑屏，立即回退备份的 boot.img。
5. 按 `GPS_DIAGNOSIS.md` 逐层跑诊断，再决定是继续调内核还是换 ROM 包。
6. 风险：`gps_dts_fix=dagu-minimal-node` 会让内核操作 GPIO 46，若 dagu 上该 GPIO 另作他用可能引发副作用；默认关闭。

---

## 9. 文件清单

```
.github/workflows/build-a17-kernel.yml   云编译（devices 矩阵并行 / ksu / system / stability_fixes / gps_dts_fix）
scripts/apply_patches.sh                 A17 config 校验 + GPS 内核侧强制项 + 可选 DTS 补丁
scripts/apply_stability_fixes.py        键盘 panic / cgroup / pstore 稳定性补丁（幂等，--check 校验）
scripts/apply_wifi_share_fixes.py       esoc0 SSR 跳过 + config fragment 注入（幂等，--check 校验）
scripts/backport_patches.sh              vendor 化的 4.19 backport（build.sh 依赖）
scripts/github_api.py                   publish / dispatch / status / download
configs/enuma_elish_wifi_share.config   WiFi 共享场景 .config fragment（用户提供，原文）
patches/0001-soc-qcom-subsystem_restart-skip-esoc0.patch   SSR 源码补丁（用户提供，原文）
GPS_DIAGNOSIS.md                        GPS 分层诊断命令与修复分流
README.md                              本文件
```

## 10. 主要参考

- https://github.com/ymdzq/kernel_xiaomi_sm8250_mod/tree/android16-aptusitu
- https://github.com/LineageOS/android_kernel_xiaomi_sm8250/tree/lineage-24.0
- https://github.com/MiCode/Xiaomi_Kernel_OpenSource/tree/elish-r-oss
- https://github.com/UtsavBalar1231/kernel_xiaomi_sm8250
- https://github.com/yspbwx2010/kernel_xiaomi_sm8250_mod ・ https://github.com/HuberyBrook/kernel_xiaomi_sm8250_mod
- https://github.com/ReSukiSU/ReSukiSU ・ https://sukisu.org/
- XDA: `[ROM][UNOFFICIAL][A17][ELISH] LineageOS 24 for Xiaomi Pad 5 Pro WiFi`

---

## 11. 稳定性补丁（`stability_fixes=true`）

`scripts/apply_stability_fixes.py` 在 `apply_patches.sh` 之后运行，幂等、按结构匹配，
`--check` 只校验不写入；校验记录随 Release 发布为 `STABILITY_FIXES_<device>.txt`。
三处修复均已逐行对照 `ymdzq/kernel_xiaomi_sm8250_mod@android16-aptusitu` 源码确认：

| 文件 | 问题 | 修复 |
|---|---|---|
| `drivers/input/misc/xiaomi_keyboard/*` | `xiaomi_keyboard_remove()` 释放 `mdata`、销毁 `event_wq`，却**没有** `power_supply_unreg_notifier()`；回调里的 `if (mdata != NULL)` 恒真（`container_of` 不返回 NULL）。键盘复位后任意电源事件 → `__queue_work` 空指针 → `Kernel panic - Fatal exception` | 注销两个 notifier、先停用再销毁 workqueue、回调判空并加 `notifier_active` 状态位 |
| `arch/arm64/configs/<device>_defconfig` | 缺 `CONFIG_CGROUP_PIDS` / `CONFIG_CGROUP_DEVICE` → A17 `init: failed write pid to memcg` | 在 `CONFIG_CGROUP_BPF=y` 后强制开启 |
| `fs/pstore/ram.c` | `ramoops_memreserve()` 把 4M 全给 console+pmsg，`record_size=0`，pstore 永不落盘（无法留存 panic 证据） | 分配 `record_size` / `ftrace_size`，console 与 pmsg 各 1M |

**边界**：这些补丁只覆盖内核侧。诊断中已经确认的框架层软重启
（`KeyboardAuthHelper` → `com.xiaomi.devauth` → LSPosed/Thanox 篡改
`ActiveServices.bindServiceLocked` → `system_server` 崩溃）与 vendor/system 侧
VINTF HAL 缺失、SELinux 策略错配、`/vendor/odm/etc/setting.xml` EACCES、
qspmhal `renameat2` 崩溃循环等，**都不是重编内核能修的**。软重启仍需禁用
hook 系统服务的模块；完整修复应回退与本机 SKU 匹配的官方完整包。

刷入前务必备份 `boot.img` / `dtbo.img` / `persist` / `/data`，并确认设备真实解锁状态。

---

## 12. WiFi 共享掉线修复（`wifi_share_fix=true`，2026-11-13）

**现象**：enuma 硬件（SM8250 + 外置 SDX55M）刷 elish（WiFi-only）ROM 后，外置基带
因没有配套 EFS/校准数据，每约 13 秒 errfatal 一次
（`CRITICAL_DATA_CHECK_FAILED`）。每次 errfatal 都以 `RESET_SUBSYS_COUPLED`
（"RELATED"）调用 `subsystem_restart_dev()`，连带 power-cycle `esoc0` 与耦合的
wlan 子系统，冲掉 cnss IMS/COEX QMI 服务；在「通信共享 / EasyTether」的
STA + P2P 并发状态下，平板自己的 WiFi STA 会立刻被本地去认证
（`WLAN_REASON_DEAUTH_LEAVING`）。纯官方状态 `SDX55M=OFFLINE` 无此循环。

**运行态开关无效**（已验证）：`/sys/module/subsystem_restart/parameters/disable_restart_work`
写 1/2 仍打印 `Restart sequence requested for esoc0, restart_level = RELATED`；
`/sys/bus/msm_subsys/devices/subsys10/restart_level` 是只读的。所以必须编译期改。

| 输入 | 作用 |
|---|---|
| `patches/0001-soc-qcom-subsystem_restart-skip-esoc0.patch` | 在 `subsystem_restart_dev()` 的 `pr_info("Restart sequence requested ...")` 之后、`disable_restart_work` 检查之前，对 `name == "esoc0"` 直接 `return 0`。modem 保持上电、QMI_LOC 可供 GNSS，只掐掉反复重启 wlan/cnss/telephony 的循环 |
| `configs/enuma_elish_wifi_share.config` | 关 `CONFIG_PANIC_ON_SSR_NOTIF_TIMEOUT`、SSR 超时保持 20000ms、关 MHI 调试/噪声项，其余 ESOC/MHI/CNSS2/QRTR 保持开启 |

**实现上的四个必要修正**：

1. **补丁按结构匹配，不用 `git apply`**：原 patch 的 hunk 是 `@@ -1900,6 +1900,18 @@`，
   而 `android16-aptusitu` 分支的锚点实际在 `subsystem_restart.c:1239`，
   直接 `git apply` 必然失败。`apply_wifi_share_fixes.py` 用
   `pr_info(...)` + `if (disable_restart_work == DISABLE_SSR)` 双锚点定位插入。
2. **config fragment 注入 `build.sh` 的 `SET_CONFIG()` 尾部**：`SET_CONFIG()` 在
   `make <device>_defconfig` 之后、编译之前用 `scripts/config --file out/.config`
   改**最终** `.config`。只改 defconfig 不够 —— 上一版构建就出现过
   defconfig 已加 `CONFIG_CGROUP_PIDS/DEVICE`，但刷入后 `/proc/config.gz` 仍是
   `not set`。脚本会解析 fragment 生成 `scripts/config` 参数，不是硬编码。
3. **修正符号大小写**：fragment 写 `CONFIG_ESOC_MDM_4X`，上游 Kconfig 与
   `enuma_defconfig` 实际是 `CONFIG_ESOC_MDM_4x`（小写 x）。仓库保留输入原文，
   生成命令时映射为 `ESOC_MDM_4x` 并在 CI 日志打印提示。
4. **按设备区分**：`ESOC*` 驱动族只对 `enuma` 强制开启；`elish` 是 WiFi-only、
   DTS 里没有 `esoc0` 节点，强开只会编入无用驱动，因此 elish 只应用
   `PANIC_ON_SSR_NOTIF_TIMEOUT` / MHI 降噪等通用项。源码补丁对两者都打
   （elish 上不会触发 `name == "esoc0"`，无副作用）。

**CI 校验产物**（随 Release 发布）：
`WIFI_SHARE_<device>.txt`（apply/check 全过程 + 编译后 `out/.config` 实际值）、
`CONFIG_<device>.txt`（编译完成后的完整 `.config`）。流水线会断言
`CONFIG_PANIC_ON_SSR_NOTIF_TIMEOUT=y` **没有**出现在最终 `.config` 里，
否则 job 直接失败，避免再次产出「补丁打了但没生效」的包。

**边界**：这只处理内核侧 SSR 循环。framework 层的键盘鉴权崩溃
（需 LSPosed 的 KBAuthFix 模块）、VINTF 缺 HAL、`com.android.phone`
缺 `ExtTelephonyManager` 的 crash-loop 都还在，与本次改动无关。
