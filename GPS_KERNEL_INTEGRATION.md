# GPS 修复方案能否集成进内核 · 结论与内核编译条件

**一句话结论：不能整体搬进内核。** v4 的 GPS 修复约 95% 是 Android 用户态适配
（属性注入、vendor 文件 overlay、拉起 HAL/RIL 守护进程、sepolicy、深色模式自愈、
闪光灯特征覆盖）。内核只参与一件与它有关的事：提供并管理外置 X55 modem 的
ESOC/QRTR/QMI/MHI/CNSS2 栈，并在 modem 反复 SSR 时不把整块 wlan/cnss/telephony
一起重启。这两件事已经由本仓库的 `apply_patches.sh` + SSR 补丁覆盖。

设备现状（2026-11-13 实测）：
- 硬件 = **enuma**（5G，GPS 走 modem 内 GNSS）；ROM/kernel 身份 = **elish**（WiFi 版）。
- 运行内核 = `4.19.325-cip127-st11-aptusitu-perf+`（与 builder 的
  `ymdzq/android16-aptusitu` 同源），Android 17。
- 注意：本次读数 `vendor.peripheral.SDX55M.state = OFFLINE`，即 X55 此刻没上线——
  刷新内核前先确认 KernelSU 模块 v4.4 仍启用、无 `disable`/`no_modem` 且
  `mdm_helper` 在跑（早期某次重启后模块可能没重跑）。GPS 内核侧全开也不解决
  用户态没把 modem 拉起来的情况。

---

## 1. v4 模块动作 → 内核 / 用户态 拆分表

| 模块动作（post-fs-data.sh / service.sh） | 层 | 能否进内核 |
|---|---|---|
| `resetprop ro.baseband mdm` / `ro.boot.baseband mdm` | 用户态属性 | ❌ 必须留模块 |
| `resetprop ro.radio.noril` / `ro.product.vendor.device` 等 | 用户态属性 | ❌ 必须留模块 |
| overlay `/vendor/etc` `/vendor/bin/hw` `/vendor/lib64`（QTI GNSS HAL） | 用户态文件 overlay | ❌ 必须留模块 |
| `start vendor.mdm_helper`（拉起 esoc0） | 用户态守护进程 | ❌ 必须留模块 |
| `start vendor.qcrild`（RIL） | 用户态守护进程 | ❌ 必须留模块 |
| 直接 `nohup ...android.hardware.gnss@2.1-service-qti &` | 用户态 HAL 进程 | ❌ 必须留模块 |
| `ksud sepolicy patch`（sepolicy.rule） | 用户态 sepolicy | ❌ 必须留模块 |
| `darkmode_heal.sh`（uiMode 往返） | 用户态 | ❌ 必须留模块 |
| `fix_flashlight`：overlay `elish.xml` 把 `support_android_flashlight=true→false` | 用户态文件 overlay | ❌ 必须留模块 |
| **ESOC/QRTR/QMI/MHI/CNSS2 栈编译进内核** | 内核 | ✅ 本次已加强制 |
| **esoc0 解耦：modem 仍自愈重启救 GPS，但不再连带重启 wlan/cnss/telephony** | 内核 | ✅ `0001` 补丁已接入 |

> 关键点：就算把上面两行内核项全做了，**modem 真正上电仍然靠 `ro.baseband=mdm`
> + `mdm_helper` 这个用户态触发链**。单靠内核无法把 X55 拉起来，所以模块不能删。

---

## 2. 内核侧到底改了什么（本次交付）

1. **`scripts/apply_patches.sh` 增强**
   - 在 `want` 字典里新增并强制 `CONFIG_ESOC*`、`CONFIG_MHI_BUS`、`CONFIG_MHI_QCOM`、
     `CONFIG_MHI_NETDEV`、`CONFIG_QRTR_MHI`、`CONFIG_MSM_SUBSYSTEM_RESTART`、
     `CONFIG_MSM_PIL*`、`CONFIG_CNSS2*`。
   - 这一步专治「enuma 硬件 + elish ROM」这台机器：elish_defconfig 是 WiFi 版，
     默认不含这些，换内核后 modem/GNSS 传输栈可能缺失；强制后无论选哪个 device 都齐全。
   - 新增一步：构建时 `git apply`（失败回退 `patch -p1 --fuzz=3`）应用
     `patches/0001-soc-qcom-subsystem_restart-decouple-esoc0.patch`。
   - 验证行新增打印 ESOC/MHI/CNSS2，构建日志一眼可查。

2. **`patches/0001-soc-qcom-subsystem_restart-decouple-esoc0.patch`**
   - 在 `subsys_register()` 里把 `esoc0`（X55 modem）的 `restart_order` 置空，使其从
     耦合（RELATED）重启组里摘出来。**esoc0 仍能单独重启** —— X55 fault 后照常自愈、
     QMI_LOC/GNSS 通道恢复（GPS 能收星）；但重启不再牵连 wlan/cnss，WiFi 与 通信共享 不受影响。
   - 这是「连共享断 WiFi / P2P GO 协商失败」与「modem SSR 抖动拖死 QMI 导致 GPS 收不到星」
     两件事的共同内核根因修复。**注意**：早先一版补丁是 `return 0` 直接禁止 esoc0 重启，
     结果 X55 一旦 fault 就永久卡死、QMI 全死、GPS 收不到星 —— 已废弃，本版改为解耦而非禁重启。

3. **`enuma_gps_kernel.config`**：独立 .config 片段（不走 builder 时 `merge_config` 用）。

---

## 3. 内核编译条件 / 命令

### 用本 builder（推荐，已含上述全部改动）
GitHub Actions 触发参数：
| 输入 | 取值 | 说明 |
|---|---|---|
| `device` | **`enuma`** | 必须是 enuma：硬件是 enuma，且只有 enuma_defconfig 默认带 modem 栈；即便 ROM 是 elish 也选 enuma（apply_patches.sh 已强制补齐）。**不要选 elish**，否则 elish 的 WiFi-only 内核可能丢 modem/GNSS 传输栈。 |
| `ksu` | `ksu` | ReSukiSU + SuSFS + KPM（或 `rksu` / `noksu`）。 |
| `target_system` | **`miui`** | HyperOS/MIUI 必须 miui，aosp 会黑屏。 |
| `gps_dts_fix` | `none` | enuma 走 modem GNSS，不需要 `bcm4775` 节点；该选项只给 dagu 用。 |

本地（走代理 + REST API）：
```bash
GH_TOKEN=<token> python scripts/github_api.py dispatch --device enuma --ksu ksu --system miui
GH_TOKEN=<token> python scripts/github_api.py status
GH_TOKEN=<token> python scripts/github_api.py download   # 取回 Kernel_MIUI_enuma_*_anykernel3_*.zip
```

### 不用 builder、自己编（4.19 树，已 checkout ymdzq/android16-aptusitu）
```bash
# 先合入 GPS 内核条件
ARCH=arm64 scripts/kconfig/merge_config.sh \
    arch/arm64/configs/enuma_defconfig enuma_gps_kernel.config
# 再打 SSR 补丁（若 apply_patches.sh 没跑）
git apply patches/0001-soc-qcom-subsystem_restart-decouple-esoc0.patch   # 失败按补丁头注释手动锚定
# 工具链：ZyC-Clang 22（builder 同款），ARCH=arm64
make -j$(nproc) Image.gz dtb
```
产物为 `Image.gz` + `sm8250-enuma.dtb`，用 AnyKernel3 打成可刷 zip（builder 已自动处理）。

---

## 4. 刷入 / 验证 / 回退（必读）

1. **备份**：原机 `boot.img`（含当前内核）、`dtbo.img`、`persist`、`/data`。
2. 在 TWRP/recovery 刷 `Kernel_MIUI_enuma_*.zip`（AnyKernel3）；**不要**单独刷 dtbo，
   **不要** `fastboot flash boot` 覆盖 dtbo。保留原厂/ROM 自带 dtbo。
3. 首次启动装 ReSukiSU Manager，确认 root 可用。
4. **GPS 验证**（内核只是保证栈在，GPS 仍靠模块把 modem 拉起）：
   - `dmesg | grep -iE 'qrtr|glink|esoc|mhi|modem|subsys'` 应见到 esoc0 / MHI 起来；
   - `getprop vendor.peripheral.SDX55M.state` 应为 **ONLINE**（模块生效时）；
   - `ps -A | grep gnss@2.1-service-qti` 应有进程；
   - `dumpsys location` 见 `GNSS Hardware Model Name: qcom` 且能收星。
5. **WiFi/共享验证**（解耦补丁效果）：`dmesg` 仍可见 `Shutting down esoc0 / Powering up esoc0`
   （esoc0 单独重启 = 正常自愈，说明 GPS 通道能恢复），但**不再有成串把 wlan 一起重启**；
   连上通信共享后 `settings get secure celluar_shared_state` 为 1 且 `wlan0` 仍保有 IP、
   P2P GO 能正常协商（不再是"连接失败"）；`SDX55M=ONLINE`、qti HAL 存活、`dumpsys location`
   的 `sv status messages processed` > 0（真正收星）。
6. **回退**：黑屏/起不来 → 刷回备份的 `boot.img` 即可，内核改动随 boot 一起回滚；
   模块侧回退见 v4 的 `disable` / 删 `fix_*` marker 机制。

---

## 5. 边界（务必告诉接手编译的任务）

- **GPS 修复不能单靠内核**：属性、vendor overlay、HAL/RIL 守护进程、sepolicy、
  darkmode 自愈、闪光灯特征覆盖都必须在 KernelSU 模块里。内核只保证 modem/GNSS
  传输栈存在 + modem SSR 不拖垮系统。
- **光改 .config 修不了 SSR**：运行时 sysfs（`disable_restart_work`、`subsysN/restart_level`）
  已实测只读/无效，必须打 `0001` 补丁重编。
- **根治需补 enuma 原厂 X55 modem EFS**，那要动分区，超出「不碰分区、可回滚」约束；
  本方案只是解耦：esoc0 仍会每隔 ~13 秒因 errfatal 单独重启（自愈），但 wlan 不再被牵连、
  GPS 通道随重启恢复。
- `0001` 补丁的 hunk 行号在不同 4.19 msm 分支会有偏移；`git apply` 若拒，按补丁头
  注释用 `grep -n "restart_level = %s" drivers/soc/qcom/subsystem_restart.c` 手动锚定
  插 3 行，或已由 `patch -p1 --fuzz=3` 容错兜底。
