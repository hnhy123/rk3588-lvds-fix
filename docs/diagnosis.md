# 诊断记录：RK3588 LVDS 间歇闪屏

记录一次完整的定位过程，包括走过的弯路。命令均可在同型号机器上复现。

## 测试环境

| 项 | 值 |
|---|---|
| 机型 | Really TVI2340R（RK3588 直播机），`/proc/device-tree/model` |
| 系统 | Armbian 26.11.0-trunk（Ubuntu 26.04 resolute） |
| 内核 | `7.3.5-edge-rockchip64` |
| DTB | `/boot/dtb/rockchip/rk3588-really.dtb`，213085 字节 |
| 面板 | LVDS 1920x1080，经 LT9211 从 DSI 转换 |
| 启动参数 | `console=ttyS2,1500000 console=tty1 consoleblank=0 loglevel=7 fbcon=rotate:3` |

## 题目：为什么没有日志

先说结论，因为它决定了排查方向。三个观测点同时缺失：

1. **DSI2 驱动不注册中断**
   设备树 `/dsi@fde30000/interrupts` 声明了 GIC SPI 168，但：
   ```bash
   grep -iE 'dsi|mipi' /proc/interrupts     # 空
   ```
   链路异常不会产生任何内核事件。

2. **LT9211 是无状态哑桥**
   驱动只在 probe/上电时写一遍寄存器，不轮询、不检测锁定状态。

3. **面板供电是裸 GPIO**
   ```bash
   grep lvds /sys/kernel/debug/gpio
   # gpio-14 ( |regulator-lvds-pwr-e) out hi
   ```
   只要 GPIO 保持高，regulator 框架就认为面板正常。

所以 `dmesg` 干净 ≠ 软件正常，只是没人看得见。

## 逐项排除

| 怀疑对象 | 手段 | 结果 |
|---|---|---|
| 背光 PWM 频闪 | 手机相机对屏拍摄；`/sys/class/backlight/backlight/actual_brightness` 0.1 s 采样 | 无横条纹；亮度全程不变（仅开机恢复一次 154）→ 排除 |
| GNOME 调光 / 熄屏 | 同上 + `dpms` 0.1 s 采样 | 全程 `On` → 排除 |
| 合成器 modeset | `echo 0x04 > /sys/module/drm/parameters/debug` 后 `dmesg -w` | 闪屏期间 modeset = **0** → 排除 |
| 加速度计自动旋转 | `journalctl _SYSTEMD_USER_UNIT=really-auto-rotate` | 仅开机触发 1 次（`orientation=right-up stable=4`）→ 排除 |
| DDR/GPU 调频 | `/sys/class/devfreq/*` | 只有 GPU 一个 devfreq，与负载无关 → 排除 |
| 面板供电使能掉电 | 20 Hz 轮询 `gpio-14` 状态 | 0 次跌落 → 排除 |
| LT9211 复位/掉线 | 20 Hz `i2ctransfer` 块读寄存器 0x10-0x27 | 0 次 NAK，内容稳定 → 排除 |
| VOP 时序错配 | `/sys/kernel/debug/dri/1/state` | 2200×1125 @148.5 MHz，标准 1080p60 → 排除 |
| 帧缓冲/PCIe/IOMMU | `dmesg | grep -iE 'iommu.*fault|underrun'` | 无 → 排除 |

闪屏发生时背光仍亮、屏幕"发灰无图像"——这是 LCD **失去扫描信号** 的典型外观（不是合成器画了黑帧）。结合上表，故障必然在 DRM 之下的 DSI→LT9211→LVDS 段。

## 关键命令

```bash
# 面板与 CRTC 实际状态
cat /sys/class/drm/card1-LVDS-1/status
grep -E 'mode: "' /sys/kernel/debug/dri/1/state

# VOP 像素时钟（注意：显示用 dri/1，card0 是 NPU 的 rocket 驱动）
awk '/dclk_vop3[ ]/{print $5}' /sys/kernel/debug/clk/clk_summary

# LT9211 寄存器（i2c-4, 0x2d）
i2cdump -y -f 4 0x2d
i2ctransfer -f -y 4 w1@0x2d 0x10 r24@0x2d

# 面板供电 GPIO
cat /sys/kernel/debug/gpio

# 打开 DRM 模式设置日志
echo 0x04 > /sys/module/drm/parameters/debug
```

## 时序实验记录

面板时序来自 `/panel-lvds/panel-timing`（DTB）：

```
clock-frequency = 148562464
hactive 1920  hfront 88  hsync 44  hback 148   → htotal 2200
vactive 1080  vfront 4   vsync 5   vback 36    → vtotal 1125
```

| pclk | htotal | vtotal | 刷新率 | 结果 |
|---|---|---|---|---|
| 148.5625 MHz | 2200 | 1125 | 60.0 | 原厂值，**间歇闪屏** |
| 123.75 MHz（PLL 取整 118.8） | 2200 | 1125 | 48.0 | **不闪**，但非整数 50 |
| 118.8 MHz | **2112** | 1125 | 50.0 | **整屏黑屏（背光在）** |
| 132 MHz | 2200 | **1200** | 50.0 | **不闪，显示正常** ← 采用 |

第三行是想"保持低时钟又凑整数 50Hz"的尝试：hfront 88→32、hback 148→116，算术完全正确，但面板不接受缩短的水平消隐。

**结论：水平时序不可改，只能调 `clock-frequency` 和垂直消隐。**

## 为什么 132 MHz

RK3588 的 VOP 像素时钟来自 PLL 整数分频，实测可得序列包含 `1188/9 = 132 MHz`。

要让刷新率是整数 50，需 `pclk = 2200 × vtotal × 50`：

- `vtotal = 1125` → pclk = 123.75 MHz（PLL 取不到）
- `vtotal = 1200` → pclk = **132 MHz**（精确可取）✓

所以选 "132 MHz + 垂直消隐加长"。垂直消隐变长对面板无害（只是多等几行），水平时序保持原厂不变。

## 复现验证

```bash
# 打补丁后重启，确认实际生效
fdtget -t x /boot/dtb/rockchip/rk3588-really.dtb /panel-lvds/panel-timing clock-frequency
# 期望：7de2900

awk '/dclk_vop3[ ]/{print $5}' /sys/kernel/debug/clk/clk_summary
# 期望：132000000

grep -E 'mode: "' /sys/kernel/debug/dri/1/state
# 期望：mode: "1920x1080": 50 132000 1920 2008 2052 2200 1080 1084 1089 1200
```
