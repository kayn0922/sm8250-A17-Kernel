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
本工程默认按你消息里写的 `enuma` 编译；若实际是 `elish` 或 `dagu`，改 workflow 的 `device` 输入重编即可。

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
| `device` | `enuma` | `elish` / `enuma` / `dagu`（按**实际硬件**选） |
| `ksu` | `ksu` | `ksu`=ReSukiSU+SuSFS+KPM；`rksu`=RKSU；`noksu`=留给 Magisk/APatch |
| `target_system` | `miui` | **HyperOS4 必须 miui**；`aosp` 仅类原生 ROM；`both` 两个都编 |
| `gps_dts_fix` | `none` | `dagu-minimal-node` = 给 dagu 的 DTS 注入最小 `bcm4775` 节点（实验性，见下） |

命令行（本机，走 10808 代理 + REST API）：

```bash
GH_TOKEN=<token> python scripts/github_api.py publish     # 建仓并上传工程
GH_TOKEN=<token> python scripts/github_api.py dispatch --device enuma --ksu ksu --system miui
GH_TOKEN=<token> python scripts/github_api.py status
GH_TOKEN=<token> python scripts/github_api.py download    # 取回 Kernel_MIUI_*.zip
```

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

## 8.1 拔线 + 熄屏重启修复（unplug_suspend_guard）

症状：拔掉充电线并且屏幕熄屏进入深睡时，设备会在数十秒内静默重启。
根因在内核充电 / 电量计驱动的 suspend 路径（拔线后 `dual_fuel_gauge` 仍报
约 1661mA 充电电流、`smblib_suspend_on_debug_battery` 返回 -EINVAL，随后
suspend/resume 竞态导致 SoC 复位）。

修复：内核模块 `patches/unplug_suspend_guard.c`，在 USB 拔线期间持有内核
`suspend wakelock`（wakeup_source），阻止设备深睡，直到重新插线才释放。
效果等同于此前验证有效的用户态 wakelock 守护进程，但运行在内核态、无用户态
依赖。该模块**不修改任何充电 / PD / 电量计驱动**，不影响充电与其他功能。

- 由 `scripts/apply_patches.sh` 自动拷贝到 `drivers/misc/`、加入 Makefile/Kconfig，
  并在 defconfig 中强制 `CONFIG_UNPLUG_SUSPEND_GUARD=y`（内置编译进内核）。
- 运行时可用模块参数临时关闭：
  `echo 0 > /sys/module/unplug_suspend_guard/parameters/hold_while_unplugged`。
- 刷入新内核并确认不再重启后，可卸载之前的用户态守护进程
  （设备上 `/data/adb/usbplug_wl/uninstall.sh`）。
- 编译参数 `device` 必须和当前在跑的内核一致（本机为 enuma 硬件跑 elish ROM，选 `enuma`）。

---

## 9. 文件清单

```
.github/workflows/build-a17-kernel.yml   云编译（参数化 device/ksu/system/gps_dts_fix）
scripts/apply_patches.sh                 A17 config 校验 + GPS 内核侧强制项 + unplug_suspend_guard 接入
patches/unplug_suspend_guard.c           拔线期间持 suspend wakelock，修复拔线+熄屏重启（独立内核模块）
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
