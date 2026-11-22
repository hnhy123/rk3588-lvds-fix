#!/bin/bash
# ============================================================================
#  really-lvds-fix.sh  —  Really TVI2340R / TVI2340R (RK3588 直播机) 间歇闪屏修复
#  v2  2026-11-19
# ============================================================================
#  症状：屏幕间歇性整屏“发灰发亮但无图像”，背光仍亮；dmesg/日志无任何错误。
#
#  原理：面板链路是 VOP2 → DSI2 → LT9211 桥(i2c 0x2d) → LVDS 屏。
#        原厂 148.5625 MHz 像素时钟(1920x1080@60) 下，DSI/LT9211→LVDS 这一段
#        锁定余量不足，会周期性失锁，表现为瞬间丢图像。
#        降低像素时钟即可消除。
#
#  两个档位（--profile）：
#    50 （默认，实测通过）pclk 132 MHz  + vtotal 1200 → 精确 50.0000 Hz
#                        水平时序完全保持原厂值，只加垂直消隐
#    48 （备用，实测通过）pclk 118.8 MHz + vtotal 1125 → 精确 48.0000 Hz
#                        更保守，链路速率更低；若 50 档仍闪屏可退到这一档
#
#  用法：
#    sudo ./really-lvds-fix.sh                 打补丁（默认 50 档），之后手动重启
#    sudo ./really-lvds-fix.sh --reboot        打补丁并立即重启
#    sudo ./really-lvds-fix.sh --profile 48    用 48 档
#    sudo ./really-lvds-fix.sh --check         只看当前状态，不改动
#    sudo ./really-lvds-fix.sh --restore       用最近一次备份还原（回原厂 60Hz）
#    sudo ./really-lvds-fix.sh --hold          打补丁并 apt-mark hold，防升级覆盖
#    sudo ./really-lvds-fix.sh --dtb FILE      手动指定 dtb 路径
#
#  注意：仅对存在 /panel-lvds/panel-timing 的同型号机器有效。
#        升级 linux-dtb-edge-rockchip64 包会覆盖 dtb，使补丁失效（用 --hold 规避）。
# ============================================================================

set -u

NODE=/panel-lvds/panel-timing
PROP_CLK=clock-frequency
PROP_VBK=vback-porch

ORIG_CLK_HEX=8d9ee20        # 148562464 Hz = 60Hz（原厂）
ORIG_VBK_HEX=24             # 36 行（原厂）

P50_CLK_HEX=7de2900         # 132000000 Hz → 2200x1200 = 50.0000 Hz
P50_VBK_HEX=6f              # 111 行（+75 行垂直消隐）
P48_CLK_HEX=7604670         # 请求 123750000，PLL 取整为 118.8MHz → 48.0000 Hz
P48_VBK_HEX=24              # 与原厂一致

DTB_PKG=linux-dtb-edge-rockchip64

PROFILE=50
DO_REBOOT=0
DO_RESTORE=0
DO_CHECK=0
DO_HOLD=0
DTB=""
FORCE=0

info()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; }
die()   { err "$*"; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--reboot)  DO_REBOOT=1 ;;
		--restore) DO_RESTORE=1 ;;
		--check)   DO_CHECK=1 ;;
		--hold)    DO_HOLD=1 ;;
		--force)   FORCE=1 ;;
		--dtb)     shift; DTB="${1:-}" ;;
		--profile) shift; PROFILE="${1:-}" ;;
		-h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
		*) die "未知参数: $1（--help 查看用法）" ;;
	esac
	shift
done

case "$PROFILE" in
	50) NEW_CLK_HEX=$P50_CLK_HEX; NEW_VBK_HEX=$P50_VBK_HEX; EXP_REFRESH="50.0000" ;;
	48) NEW_CLK_HEX=$P48_CLK_HEX; NEW_VBK_HEX=$P48_VBK_HEX; EXP_REFRESH="48.0000" ;;
	*)  die "--profile 只支持 50 或 48" ;;
esac

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo $0）"

# ---------- 定位 dtb ----------
if [ -z "$DTB" ]; then
	if [ -r /boot/armbianEnv.txt ]; then
		FDTFILE=$(sed -n 's/^fdtfile=//p' /boot/armbianEnv.txt | head -1)
		[ -n "$FDTFILE" ] && [ -e "/boot/dtb/$FDTFILE" ] && DTB="/boot/dtb/$FDTFILE"
	fi
fi
if [ -z "$DTB" ]; then
	DTB=$(ls /boot/dtb/rockchip/rk3588-really*.dtb 2>/dev/null | head -1)
fi
[ -n "$DTB" ] && [ -f "$DTB" ] || die "找不到 dtb 文件，请用 --dtb 指定"

info "dtb: $DTB"

for t in fdtget fdtput; do
	command -v "$t" >/dev/null 2>&1 || die "缺少 $t（apt install device-tree-compiler）"
done

# ---------- 读取 / 判定 ----------
read_prop() { fdtget -t x "$DTB" "$NODE" "$1" 2>/dev/null | tr -d ' \n'; }

CUR_CLK=$(read_prop "$PROP_CLK")
CUR_VBK=$(read_prop "$PROP_VBK")
[ -n "$CUR_CLK" ] || die "该 dtb 里没有 $NODE/$PROP_CLK —— 不是这款面板，不要用这个补丁"

classify() {
	case "$1" in
		"$ORIG_CLK_HEX") echo "原厂 60Hz（会间歇闪屏）" ;;
		"$P50_CLK_HEX")  echo "50 档（132MHz，精确 50Hz）" ;;
		"$P48_CLK_HEX")  echo "48 档（118.8MHz，精确 48Hz）" ;;
		*)               echo "未知值（既非原厂也非已知档位）" ;;
	esac
}

show_state() {
	local mode dpms st d
	info "当前 pixel clock: 0x$CUR_CLK   vback-porch: 0x$CUR_VBK"
	info "状态: $(classify "$CUR_CLK")"
	st=$(cat /sys/class/drm/card1-LVDS-1/status 2>/dev/null)
	dpms=$(cat /sys/class/drm/card1-LVDS-1/dpms 2>/dev/null)
	[ -n "${st:-}" ] && info "面板: ${st}  DPMS: ${dpms:-?}"
	mode=$(grep -m1 -E 'mode: "[0-9]+x[0-9]+":' /sys/kernel/debug/dri/1/state 2>/dev/null)
	if [ -n "$mode" ]; then
		info "运行模式: $(echo "$mode" | sed 's/^\s*mode: //')"
	else
		warn "面板当前未点亮（DPMS ${dpms:-?}），刷新率需亮屏后再看"
	fi
	if [ -r /sys/kernel/debug/clk/clk_summary ]; then
		d=$(awk '/dclk_vop3[ ]/{print $5; exit}' /sys/kernel/debug/clk/clk_summary 2>/dev/null)
		[ -n "${d:-}" ] && info "VOP 像素时钟 dclk_vop3: ${d} Hz"
	fi
}

if [ "$DO_CHECK" = 1 ]; then
	show_state
	exit 0
fi

# ---------- 还原 ----------
if [ "$DO_RESTORE" = 1 ]; then
	BAK=$(ls -t "$DTB".bak.* "$DTB".bak 2>/dev/null | head -1)
	[ -n "$BAK" ] || die "找不到备份文件（$DTB.bak*）"
	info "还原自: $BAK"
	cp -a "$BAK" "$DTB" || die "还原失败"
	sync
	CUR_CLK=$(read_prop "$PROP_CLK")
	info "还原后 pixel clock: 0x$CUR_CLK（应为原厂 0x$ORIG_CLK_HEX）"
	if [ "$DO_REBOOT" = 1 ]; then info "重启中…"; reboot; else info "请重启生效: reboot"; fi
	exit 0
fi

# ---------- 打补丁 ----------
if [ "$CUR_CLK" = "$NEW_CLK_HEX" ] && { [ "$CUR_VBK" = "$NEW_VBK_HEX" ] || [ "$NEW_VBK_HEX" = "$ORIG_VBK_HEX" ]; }; then
	info "已经是 --profile $PROFILE 的状态，无需重复打补丁"
	show_state
	[ "$DO_REBOOT" = 1 ] && { info "重启中…"; reboot; }
	exit 0
fi

CUR_KIND=$(classify "$CUR_CLK")
if [ "$CUR_CLK" != "$ORIG_CLK_HEX" ] && [ "$CUR_CLK" != "$P50_CLK_HEX" ] && [ "$CUR_CLK" != "$P48_CLK_HEX" ] && [ "$FORCE" != 1 ]; then
	warn "当前值是 0x$CUR_CLK，不认识（$CUR_KIND）"
	warn "这份 dtb 与补丁针对的不完全一致。确认要改请加 --force"
	exit 2
fi

STAMP=$(date +%Y%m%d-%H%M%S)
BAK="$DTB.bak.$STAMP"
cp -a "$DTB" "$BAK" || die "备份失败，已中止"
cp -a "$DTB" "$DTB.bak" 2>/dev/null || true
info "已备份: $BAK"

fdtput -t x "$DTB" "$NODE" "$PROP_CLK" "$NEW_CLK_HEX" || die "写入 pixel clock 失败"
fdtput -t x "$DTB" "$NODE" "$PROP_VBK" "$NEW_VBK_HEX" || die "写入 vback-porch 失败"
sync

GOT_CLK=$(read_prop "$PROP_CLK")
GOT_VBK=$(read_prop "$PROP_VBK")
[ "$GOT_CLK" = "$NEW_CLK_HEX" ] || die "校验失败：pixel clock 读回 0x$GOT_CLK"
[ "$GOT_VBK" = "$NEW_VBK_HEX" ] || die "校验失败：vback-porch 读回 0x$GOT_VBK"
info "--profile $PROFILE 写入成功：pixel clock 0x$ORIG_CLK_HEX → 0x$NEW_CLK_HEX，vback 0x$ORIG_VBK_HEX → 0x$NEW_VBK_HEX"
info "预期刷新率：$EXP_REFRESH Hz"
[ "$(stat -c%s "$DTB")" = "$(stat -c%s "$BAK")" ] && info "文件大小未变，其余节点完整" \
	|| warn "文件大小有变化，请留意"

if [ "$DO_HOLD" = 1 ]; then
	apt-mark hold "$DTB_PKG" >/dev/null 2>&1 && info "已 hold $DTB_PKG（升级不会覆盖 dtb）" \
		|| warn "apt-mark hold 失败，请手动执行: apt-mark hold $DTB_PKG"
fi

echo
info "回滚方法："
echo "    sudo $0 --restore --reboot"
echo
if [ "$DO_REBOOT" = 1 ]; then
	info "3 秒后重启…"
	sleep 3
	reboot
else
	warn "需要重启生效: reboot"
	warn "重启后可用 '$0 --check' 确认刷新率"
fi
