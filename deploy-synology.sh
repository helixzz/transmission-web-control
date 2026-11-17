#!/bin/bash
#
# deploy-synology.sh — 群晖 DSM 7 Transmission Web Control (v1.7.1-zhCN) & 专属出口绑定守护工具
#
# 用法（在群晖 SSH 中执行）：
#   sudo bash deploy-synology.sh deploy      # 安装/更新中文 WebUI + 绑定专属 IP (172.16.33.19) + 关闭 UPnP 报错 + 注册自愈守护
#   sudo bash deploy-synology.sh setup-net   # 仅配置/刷新专属 IP、settings.json 绑定并平滑重载 Transmission
#   sudo bash deploy-synology.sh status      # 查看当前 Web 目录、版本、网络绑定与快照状态
#   sudo bash deploy-synology.sh restore-hook # 供 service_prestart 与 rc.d 自动调用的自愈钩子
#   sudo bash deploy-synology.sh rollback    # 回滚 WebUI 到最近一次快照备份
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PERSIST_DIR="/volume2/@appdata/transmission/twc-zhcn"
ARCHIVE_NAME="transmission-web-control-zhcn.tar.gz"
WEB_DIR=""
BACKUP_ROOT=""

# NAS Transmission 专属源 IP（配合 VyOS 策略路由优先走 pppoe2）
BT_IFACE="bond0"
BT_IPV4="172.16.33.19"
BT_IPV4_CIDR="172.16.33.19/24"
# pppoe2 (CU-2000M) 当前在 eth1 下发的 IPv6 PD 子网标识，若变化则自动匹配任意 2408: 全局 EUI-64 地址
BT_IPV6_PREF_HINT="2408:820c:8f8d:2ca0:"
SETTINGS_JSON="/volume2/@appdata/transmission/settings.json"
PID_FILE="/volume2/@appdata/transmission/transmission.pid"
LOG_FILE="/volume2/@appdata/transmission/transmission.log"

c_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
c_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
c_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
die()      { c_red "ERROR: $*"; exit 1; }

require_root() {
	[ "$(id -u)" -eq 0 ] || die "请使用 sudo 运行此脚本：sudo bash $0 ${1:-deploy}"
}

detect_web_dir() {
	local pkg_target=""
	if [ -L "/var/packages/transmission/target" ]; then
		pkg_target="$(readlink -f /var/packages/transmission/target)"
	fi
	local candidates=(
		"${pkg_target:+$pkg_target/share/transmission/public_html}"
		"${pkg_target:+$pkg_target/share/transmission/web}"
		"/var/packages/transmission/target/share/transmission/public_html"
		"/var/packages/transmission/target/share/transmission/web"
		"/volume2/@appstore/transmission/share/transmission/public_html"
		"/volume1/@appstore/transmission/share/transmission/public_html"
	)
	for d in "${candidates[@]}"; do
		[ -n "$d" ] || continue
		if [ -d "$d" ] && [ -f "$d/index.html" ]; then
			WEB_DIR="$(readlink -f "$d")"
			BACKUP_ROOT="$(dirname "$WEB_DIR")"
			return 0
		fi
	done
	return 1
}

detect_persist_dir() {
	if [ -d "/var/packages/transmission/var" ]; then
		local var_dir
		var_dir="$(readlink -f /var/packages/transmission/var)"
		PERSIST_DIR="$var_dir/twc-zhcn"
		SETTINGS_JSON="$var_dir/settings.json"
		PID_FILE="$var_dir/transmission.pid"
		LOG_FILE="$var_dir/transmission.log"
	elif [ -d "/volume2/@appdata/transmission" ]; then
		PERSIST_DIR="/volume2/@appdata/transmission/twc-zhcn"
	elif [ -d "/volume1/@appdata/transmission" ]; then
		PERSIST_DIR="/volume1/@appdata/transmission/twc-zhcn"
		SETTINGS_JSON="/volume1/@appdata/transmission/settings.json"
		PID_FILE="/volume1/@appdata/transmission/transmission.pid"
		LOG_FILE="/volume1/@appdata/transmission/transmission.log"
	fi
}

fix_permissions() {
	local target="$1"
	if id sc-transmission >/dev/null 2>&1; then
		chown -R sc-transmission:synocommunity "$target" 2>/dev/null || chown -R sc-transmission "$target"
	fi
	find "$target" -type d -exec chmod 755 {} \;
	find "$target" -type f -exec chmod 644 {} \;
}

ensure_bt_network_and_settings() {
	local reload_mode="${1:-reload}" # reload or prestart
	detect_persist_dir

	# 1. 确保 bond0 上挂载了辅助 IPv4 172.16.33.19/24（排在主 IP 之后作为 secondary）
	if ip link show "$BT_IFACE" >/dev/null 2>&1; then
		if ! ip -4 addr show dev "$BT_IFACE" | grep -q "inet ${BT_IPV4}/"; then
			ip addr add "$BT_IPV4_CIDR" brd 172.16.33.255 dev "$BT_IFACE" 2>/dev/null || true
			c_green "  ✓ 已在 $BT_IFACE 上挂载 Transmission 专属辅助 IP: $BT_IPV4_CIDR"
		fi
	fi

	# 2. 探测 pppoe2 对应的公网 IPv6 地址（优先匹配 2ca0 前缀，若 ISP 重编号则自动匹配 bond0 上的首个全局 2408: 地址）
	local bt_ipv6=""
	bt_ipv6=$(ip -6 -o addr show dev "$BT_IFACE" scope global 2>/dev/null | awk '!/deprecated/ && !/temporary/ {split($4,a,"/"); print a[1]}' | grep "^${BT_IPV6_PREF_HINT}" | head -n1 || true)
	if [ -z "$bt_ipv6" ]; then
		bt_ipv6=$(ip -6 -o addr show dev "$BT_IFACE" scope global 2>/dev/null | awk '!/deprecated/ && !/temporary/ && $4 ~ /^2408:/ {split($4,a,"/"); print a[1]}' | head -n1 || true)
	fi
	[ -z "$bt_ipv6" ] && bt_ipv6="::"

	# 3. 检查并更新 settings.json（bind-address-ipv4, bind-address-ipv6, port-forwarding-enabled=false）
	if [ -f "$SETTINGS_JSON" ] && command -v jq >/dev/null 2>&1; then
		local cur_v4 cur_v6 cur_pf
		cur_v4=$(jq -r '."bind-address-ipv4" // ""' "$SETTINGS_JSON" 2>/dev/null || true)
		cur_v6=$(jq -r '."bind-address-ipv6" // ""' "$SETTINGS_JSON" 2>/dev/null || true)
		cur_pf=$(jq -r '."port-forwarding-enabled"' "$SETTINGS_JSON" 2>/dev/null || true)

		if [ "$cur_v4" != "$BT_IPV4" ] || [ "$cur_v6" != "$bt_ipv6" ] || [ "$cur_pf" != "false" ]; then
			cp -a "$SETTINGS_JSON" "${SETTINGS_JSON}.bak-twc" 2>/dev/null || true
			local tmp_json="${SETTINGS_JSON}.tmp.$$"
			if jq --arg v4 "$BT_IPV4" --arg v6 "$bt_ipv6" \
				'."bind-address-ipv4" = $v4 | ."bind-address-ipv6" = $v6 | ."port-forwarding-enabled" = false' \
				"$SETTINGS_JSON" > "$tmp_json"; then
				mv "$tmp_json" "$SETTINGS_JSON"
				if id sc-transmission >/dev/null 2>&1; then
					chown sc-transmission:synocommunity "$SETTINGS_JSON" 2>/dev/null || true
				fi
				chmod 664 "$SETTINGS_JSON" 2>/dev/null || true
				c_green "  ✓ 已更新 settings.json: bind-address-ipv4=$BT_IPV4, bind-address-ipv6=$bt_ipv6, port-forwarding-enabled=false"

				# 若 transmission-daemon 正在运行，发送 SIGHUP 让其立即重载 settings.json（不会覆盖刚修改的文件）
				if [ "$reload_mode" = "reload" ] && [ -f "$PID_FILE" ]; then
					local pid
					pid=$(cat "$PID_FILE" 2>/dev/null || true)
					if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
						kill -HUP "$pid" 2>/dev/null || true
						c_green "  ✓ 已向 transmission-daemon (PID $pid) 发送 SIGHUP 平滑重载绑定配置"
					fi
				fi
			else
				rm -f "$tmp_json"
			fi
		fi
	fi

	# 4. 如果 transmission.log 因历史 UPnP 报错膨胀超过 10MB，保留最后 1000 行截断瘦身
	if [ -f "$LOG_FILE" ]; then
		local log_size
		log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
		if [ "$log_size" -gt 10485760 ]; then
			local tmp_log="${LOG_FILE}.tail.$$"
			tail -n 1000 "$LOG_FILE" > "$tmp_log" 2>/dev/null && cat "$tmp_log" > "$LOG_FILE" && rm -f "$tmp_log"
			c_green "  ✓ 已清理膨胀的 transmission.log ($((log_size / 1048576)) MB -> 保留最近 1000 行)"
		fi
	fi
}

install_upgrade_guard() {
	detect_persist_dir
	mkdir -p "$PERSIST_DIR"
	if [ -f "$SCRIPT_DIR/$ARCHIVE_NAME" ] && [ "$(realpath "$SCRIPT_DIR/$ARCHIVE_NAME")" != "$(realpath "$PERSIST_DIR/$ARCHIVE_NAME" 2>/dev/null || true)" ]; then
		cp -f "$SCRIPT_DIR/$ARCHIVE_NAME" "$PERSIST_DIR/$ARCHIVE_NAME"
	fi
	if [ "$(realpath "$0")" != "$(realpath "$PERSIST_DIR/deploy-synology.sh" 2>/dev/null || true)" ]; then
		cp -f "$0" "$PERSIST_DIR/deploy-synology.sh"
		chmod 755 "$PERSIST_DIR/deploy-synology.sh"
	fi

	# 1. Hook into /var/packages/transmission/scripts/service-setup (service_prestart)
	local svc_setup="/var/packages/transmission/scripts/service-setup"
	if [ -f "$svc_setup" ] && ! grep -q "twc-zhcn/deploy-synology.sh" "$svc_setup"; then
		cat >> "$svc_setup" <<EOF

# Auto-restore Transmission Web Control (zhCN) & BT IP binding on service start / package upgrade
service_prestart ()
{
    if [ -x "$PERSIST_DIR/deploy-synology.sh" ]; then
        "$PERSIST_DIR/deploy-synology.sh" restore-hook >/dev/null 2>&1 || true
    fi
}
EOF
		c_green "  ✓ 已注入 service_prestart 钩子 ($svc_setup)"
	fi

	# 2. Boot-time / upgrade-resistant hook in /usr/local/etc/rc.d/
	local rcd_dir="/usr/local/etc/rc.d"
	mkdir -p "$rcd_dir"
	local rcd_script="$rcd_dir/S99transmission-web-control.sh"
	cat > "$rcd_script" <<EOF
#!/bin/sh
case "\$1" in
    start|"")
        if [ -x "$PERSIST_DIR/deploy-synology.sh" ]; then
            "$PERSIST_DIR/deploy-synology.sh" restore-hook >/dev/null 2>&1 &
        fi
        ;;
esac
exit 0
EOF
	chmod 755 "$rcd_script"
	c_green "  ✓ 已配置开机/自愈脚本 ($rcd_script)"
}

cmd_deploy() {
	detect_web_dir || die "未找到群晖 Transmission Web 目录"
	detect_persist_dir

	local tarball=""
	if [ -f "$SCRIPT_DIR/$ARCHIVE_NAME" ]; then
		tarball="$SCRIPT_DIR/$ARCHIVE_NAME"
	elif [ -f "$PERSIST_DIR/$ARCHIVE_NAME" ]; then
		tarball="$PERSIST_DIR/$ARCHIVE_NAME"
	else
		die "未找到安装包 $ARCHIVE_NAME，请确保它与脚本在同一目录"
	fi

	echo "目标 Web 目录 : $WEB_DIR"
	echo "持久化守护目录: $PERSIST_DIR"

	# Only replace WebUI if not already on v1.7.1-zhCN or if forced
	if [ ! -f "$WEB_DIR/tr-web-control/script/min/rpc-compat.min.js" ] || [ "${FORCE_WEBUI:-0}" = "1" ]; then
		c_yellow "1/4 备份当前 Web 目录..."
		local stamp backup
		stamp="$(date +%Y%m%d-%H%M%S)"
		backup="${WEB_DIR}.bak-${stamp}"
		cp -a "$WEB_DIR" "$backup" || die "备份失败，已中止操作"
		c_green "  ✓ 已备份至: $backup"

		c_yellow "2/4 解压并安装 Transmission Web Control (v1.7.1-zhCN)..."
		local stage="${WEB_DIR}.stage-${stamp}"
		rm -rf "$stage"
		mkdir -p "$stage"
		cp -a "$WEB_DIR"/. "$stage"/
		if [ ! -f "$stage/index.original.html" ] && [ -f "$stage/index.html" ] && ! grep -q "tr-web-control" "$stage/index.html"; then
			cp -a "$stage/index.html" "$stage/index.original.html"
		fi
		tar -xzf "$tarball" -C "$stage" || { rm -rf "$stage"; die "解压失败，未修改原目录"; }
		[ -f "$stage/index.html" ] && [ -f "$stage/tr-web-control/script/min/rpc-compat.min.js" ] || {
			rm -rf "$stage"
			die "安装包校验不完整，未修改原目录"
		}

		c_yellow "3/4 设置权限并原子切换目录..."
		fix_permissions "$stage"
		local old_tmp="${WEB_DIR}.old-${stamp}"
		mv "$WEB_DIR" "$old_tmp"
		if mv "$stage" "$WEB_DIR"; then
			rm -rf "$old_tmp"
			c_green "  ✓ WebUI 文件已更新并设置 sc-transmission:synocommunity 权限"
		else
			mv "$old_tmp" "$WEB_DIR"
			rm -rf "$stage"
			die "目录切换失败，已自动恢复原状"
		fi
	else
		c_green "1~3/4 WebUI (v1.7.1-zhCN) 已就绪，跳过重复解压"
	fi

	c_yellow "4/4 配置专属源 IP ($BT_IPV4)、关闭 UPnP 报错并更新持久化守护..."
	install_upgrade_guard
	ensure_bt_network_and_settings "reload"

	echo
	c_green "============================================================"
	c_green "Transmission Web Control & 专属出口绑定配置完成！"
	c_green "  - 专属 IPv4 绑定 : $BT_IPV4 (VyOS 策略路由优先走 pppoe2)"
	c_green "  - 专属 IPv6 绑定 : $(jq -r '."bind-address-ipv6"' "$SETTINGS_JSON" 2>/dev/null || echo '::')"
	c_green "  - UPnP 刷屏报错  : 已关闭 (port-forwarding-enabled = false)"
	c_green "============================================================"
}

cmd_restore_hook() {
	detect_web_dir || return 0
	detect_persist_dir
	# 始终确保 bond0 辅助 IP 与 settings.json 绑定生效
	ensure_bt_network_and_settings "prestart"
	# 若套件升级覆盖了 WebUI，则自动从持久化目录恢复
	if [ ! -f "$WEB_DIR/tr-web-control/script/min/rpc-compat.min.js" ] && [ -f "$PERSIST_DIR/$ARCHIVE_NAME" ]; then
		cmd_deploy
	fi
}

cmd_status() {
	detect_persist_dir
	echo "== Web 目录 =="
	if detect_web_dir; then
		c_green "  $WEB_DIR"
	else
		c_red "  未找到"
		return 1
	fi

	echo
	echo "== 当前版本 =="
	local sysjs="$WEB_DIR/tr-web-control/script/min/system.min.js"
	if [ -f "$sysjs" ]; then
		local ver upd
		ver=$(grep -o 'version:"[^"]*"' "$sysjs" | head -1 | cut -d'"' -f2)
		upd=$(grep -o 'codeupdate:"[^"]*"' "$sysjs" | head -1 | cut -d'"' -f2)
		c_green "  Transmission Web Control : ${ver:-unknown} (${upd:-unknown})"
	else
		c_yellow "  当前为 Transmission 官方原版 WebUI（未安装 TWC）"
	fi

	if [ -x "/var/packages/transmission/target/bin/transmission-daemon" ]; then
		echo "  Transmission Daemon      : $(/var/packages/transmission/target/bin/transmission-daemon -V 2>&1)"
	fi

	echo
	echo "== 网络与出口绑定状态 =="
	echo "  bond0 IPv4 列表          : $(ip -4 -o addr show dev "$BT_IFACE" 2>/dev/null | awk '{print $4}' | paste -sd', ' -)"
	if [ -r "$SETTINGS_JSON" ]; then
		echo "  bind-address-ipv4        : $(jq -r '."bind-address-ipv4"' "$SETTINGS_JSON" 2>/dev/null)"
		echo "  bind-address-ipv6        : $(jq -r '."bind-address-ipv6"' "$SETTINGS_JSON" 2>/dev/null)"
		echo "  port-forwarding-enabled  : $(jq -r '."port-forwarding-enabled"' "$SETTINGS_JSON" 2>/dev/null)"
	fi
}

cmd_rollback() {
	detect_web_dir || die "未找到 Web 目录"
	local latest=""
	for d in "${BACKUP_ROOT}"/$(basename "$WEB_DIR").bak-*; do
		[ -d "$d" ] || continue
		if [ -z "$latest" ] || [ "$d" \> "$latest" ]; then
			latest="$d"
		fi
	done
	[ -n "$latest" ] || die "未找到任何快照备份"
	echo "正在恢复快照: $latest -> $WEB_DIR"
	rm -rf "$WEB_DIR"
	cp -a "$latest" "$WEB_DIR" || die "恢复失败"
	fix_permissions "$WEB_DIR"
	c_green "✓ 已成功回滚至: $latest"
}

case "${1:-deploy}" in
	deploy)       require_root "$@"; cmd_deploy ;;
	setup-net)    require_root "$@"; ensure_bt_network_and_settings "reload"; install_upgrade_guard ;;
	restore-hook) require_root "$@"; cmd_restore_hook ;;
	status)       cmd_status ;;
	rollback)     require_root "$@"; cmd_rollback ;;
	*)
		echo "用法: sudo bash $0 {deploy|setup-net|status|rollback|restore-hook}"
		exit 1
		;;
esac
