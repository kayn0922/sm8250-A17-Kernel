# GPS 不可用 · 分层诊断清单（OS4 / Android 17 移植 ROM）

**先诊断，再刷内核。** 内核侧该开的开关（`CONFIG_AIROHA_GPS`、`CONFIG_QRTR*`、`CONFIG_QMI_HELPERS`、
`CONFIG_RPMSG_QCOM_GLINK_SMEM`、`CONFIG_QCOM_GLINK`、`CONFIG_DIAG_CHAR`）在 ymdzq 树里本来就是开的，
所以盲目换内核大概率修不好 GPS。按下面顺序 10 分钟就能定位到是哪一层断了。

---

## 前置：确认机型与 ROM

```bash
adb shell getprop ro.product.device          # elish / enuma / dagu / 移植包改过的假值
adb shell getprop ro.build.version.release   # 17
adb shell getprop ro.boot.vendor.* 2>/dev/null | head
fastboot getvar product                       # 硬件真实代号，最可信
```

若 `getprop` 与 fastboot 结果不一致（移植包常改 ro.product.device），**以 fastboot 为准**，
并据此选内核的 `device` 参数。

---

## 第 1 层：内核驱动有没有起来

```bash
adb shell ls -l /dev/airoha_gps /dev/gnss* /dev/ttyHS* /dev/ttyMSM* 2>&1
adb shell dmesg | grep -iE 'airoha|bcm4775|gps|gnss|loc_|qrtr|qmi|glink'
adb shell cat /proc/config.gz | zgrep -E 'AIROHA_GPS|QRTR|QMI_HELPERS|GLINK_SMEM|DIAG_CHAR'
adb shell getprop | grep -iE 'gps|gnss|location|radio|qcom'
```

判读：

- `elish` 正常应有 `/dev/airoha_gps`（驱动 `drivers/airoha/airoha_gps_driver.c` 创建的字符设备），
  dmesg 里能看到 `bcm4775` / `airoha_gps` 的 probe 信息。
- **没有该节点 / dmesg 无 bcm4775** → DTS 里 `bcm4775` 节点没进当前生效的设备树，
  通常是 **dtbo 被 ROM 换成了别的机型**。这一层内核**有机会**修：
  刷本工程带正确 dtb 的 `Kernel_MIUI_elish_*.zip`（elish 的 DTS 里节点是存在的），
  或者把原厂 dtbo 刷回去。
- `enuma` 没有 `/dev/airoha_gps` 是**正常的**（走 modem GNSS，不看这个节点），
  要改看 QRTR / modem subsystem 是否起来：`adb shell dmesg | grep -iE 'qrtr|glink|subsys|modem|pil'`。

> 驱动逻辑：probe 时只从 `of_node` 读 `gps-ldo` 这一个 GPIO 并拉它给 GPS 芯片上电，
> pinctrl 那几个属性是可省的。所以最小可用节点就是
> `compatible = "bcm4775"; gps-ldo = <&tlmm 46 GPIO_ACTIVE_LOW>;`。

---

## 第 2 层：dtbo / 设备树

```bash
adb shell ls -l /dev/block/by-name/dtbo*
adb shell cat /proc/cmdline | tr ' ' '\n' | grep -i dtbo
# 有 root 后可以把 dtbo 拷出来反编译比对 bcm4775 节点
adb shell 'dd if=/dev/block/by-name/dtbo of=/sdcard/dtbo.img' && adb pull /sdcard/dtbo.img
```

判读：移植包自带的 `dtbo.img` 若来自 Pad 8 Pro / Pad 6 系列，里面不会有
`bcm4775` / `gps-ldo` 节点，GPS 芯片不上电 → 一颗卫星都搜不到。
**这类问题换内核解决不了**（内核 zip 不刷 dtbo），必须换回原厂 dtbo 或让 ROM 作者补节点。

---

## 第 3 层：vendor GNSS HAL / 配置 / 固件（最常见）

```bash
adb shell lshal | grep -i gnss
adb shell ls -l /vendor/lib64/hw/android.hardware.gnss* /vendor/lib64/libloc_api* 2>&1
adb shell ls -l /vendor/etc/gnss/ /vendor/etc/gps.conf /vendor/etc/izat.conf 2>&1
adb shell ls -l /vendor/firmware/ | grep -iE 'gnss|gps|modem|bcm|airoha'
adb shell ps -A | grep -iE 'gnss|loc_|izat|xtwifi|millet|slim'
adb logcat -b all -d | grep -iE 'gnss|gps|loc_api|izat|xtwifi|millet|qcom.*loc|Gnss' | head -80
adb shell dumpsys location
```

判读与分流：

| 现象 | 结论 | 修法 |
|---|---|---|
| `lshal` 无 `android.hardware.gnss@*` / `logcat` 报 HAL not found | **vendor 里没有 GNSS HAL**（OS4 移植包来自无外置 GPS / 用高通集成 GNSS 的新机） | 换带正确 vendor 的移植包，或补入本机型的 GNSS HAL + 依赖库；**内核修不了** |
| HAL 存在但反复崩溃、报 `Qualcomm GNSS extension` / `IGnss` 失败 | framework 请求移植机型的私有扩展，本机 vendor 没有 | ROM 移植方修（HyperOS-AVD 项目 r4 就修过「定位服务请求不存在的 Qualcomm GNSS 扩展时崩溃」这一类问题） |
| `gps.conf` / `izat.conf` / GNSS 固件缺失 | 定位参数与辅助数据不完整 | 从原厂包提取 `/vendor/etc/gnss/*`、`/vendor/firmware` 补齐 |
| HAL 正常、`dumpsys location` 显示 GNSS 引擎 running 但 0 颗星 | 天线/AGPS/时间同步或芯片供电（回到第 1 层） | 清空 AGPS 数据、室外测试、检查 `gps-ldo` |
| 只有「网络定位」有结果、卫星定位无 | GNSS 引擎未启动 | 同上按 HAL 排查 |

---

## 第 4 层：framework / 权限 / Root 干扰

```bash
adb shell dumpsys location | head -60
adb shell cmd location get-location-enabled
adb shell settings get secure location_mode
adb shell getenforce                      # 应为 Enforcing
```

- HyperOS 4 做了 HIDL→AIDL 迁移；若移植没把 GNSS HAL 一并迁到 AIDL，A17 framework
  可能压根连不上老 HIDL 服务。这属于 ROM 层，刷内核无效。
- 若刚刷了 SukiSU / SuSFS 模块或 Magisk 模块，先全部禁用再测；
  SELinux 必须 `Enforcing`，`Permissive` 会引发系统服务异常（含定位）。

---

## 结论速查

| 你的观测 | 最可能的层 | 换本工程内核是否有用 |
|---|---|---|
| 无 `/dev/airoha_gps`、dmesg 无 bcm4775（elish） | dtbo / DTS 节点 | **有用**（刷带正确 dtb 的 elish MIUI 内核包，或恢复原厂 dtbo） |
| 节点在、`lshal` 无 GNSS HAL | vendor | 没用，要换/补 ROM 包 |
| HAL 崩溃报 Qualcomm 扩展 | framework/vendor | 没用，要 ROM 作者修 |
| enuma 上完全无 GNSS 服务 | vendor modem 固件/属性 | 基本没用（内核 QRTR/ESOC 已全开） |
| 有卫星数但不定位 | AGPS / 配置 / 天线 | 没用 |

**建议顺序**：先跑第 1、3 层的命令把日志存下来 → 确认机型 → 再决定是刷内核、刷原厂 dtbo，
还是直接换一个 vendor 完整的 OS4 包。刷内核前务必备份 `boot.img` 与 `dtbo.img`。
