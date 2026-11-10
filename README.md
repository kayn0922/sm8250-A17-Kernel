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

命令行（本机，REST API；默认直连，需要代理时设 `GH_PROXY`）：

```bash
GH_TOKEN=<token> python scripts/github_api.py publish
GH_TOKEN=<token> python scripts/github_api.py dispatch --devices elish+enuma --ksu ksu --system miui --stability true
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
scripts/backport_patches.sh              vendor 化的 4.19 backport（build.sh 依赖）
scripts/github_api.py                   publish / dispatch / status / download
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
