#!/bin/bash
#
# deploy-synology.sh — 群晖 DSM 7 Transmission Web Control (v1.7.1-zhCN) 部署与升级守护工具
#
# 用法（在群晖 SSH 中执行）：
#   sudo bash deploy-synology.sh deploy      # 备份官方UI、安装中文增强版、并注册套件升级自动恢复钩子
#   sudo bash deploy-synology.sh status      # 查看当前 Web 目录、版本、备份与守护状态
#   sudo bash deploy-synology.sh restore-hook # 仅检查并在套件升级后静默恢复中文 WebUI（供自动守护调用）
#   sudo bash deploy-synology.sh rollback    # 回滚到最近一次快照备份
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PERSIST_DIR="/volume2/@appdata/transmission/twc-zhcn"
ARCHIVE_NAME="transmission-web-control-zhcn.tar.gz"
WEB_DIR=""
BACKUP_ROOT=""

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
		PERSIST_DIR="$(readlink -f /var/packages/transmission/var)/twc-zhcn"
	elif [ -d "/volume2/@appdata/transmission" ]; then
		PERSIST_DIR="/volume2/@appdata/transmission/twc-zhcn"
	elif [ -d "/volume1/@appdata/transmission" ]; then
		PERSIST_DIR="/volume1/@appdata/transmission/twc-zhcn"
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

# Auto-restore Transmission Web Control (zhCN) on service start / package upgrade
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
	# Preserve official Transmission 4.x WebUI files & save index.html as index.original.html
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

	c_yellow "4/4 安装持久化备份与套件升级自动恢复守护..."
	install_upgrade_guard

	echo
	c_green "============================================================"
	c_green "Transmission Web Control (v1.7.1-zhCN) 安装完成！"
	c_green "请打开 http://172.16.33.11:9091/transmission/web/ 并按 Ctrl+F5 强制刷新。"
	c_green "如需回滚官方界面，可运行: sudo bash $PERSIST_DIR/deploy-synology.sh rollback"
	c_green "============================================================"
}

cmd_restore_hook() {
	detect_web_dir || return 0
	detect_persist_dir
	# If tr-web-control is already present, just ensure service_prestart hook is intact
	if [ -f "$WEB_DIR/tr-web-control/script/min/rpc-compat.min.js" ]; then
		return 0
	fi
	# Official package upgrade wiped tr-web-control -> restore from persistent tarball
	if [ -f "$PERSIST_DIR/$ARCHIVE_NAME" ]; then
		cmd_deploy
	fi
}

cmd_status() {
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
	echo "== 备份快照 =="
	local found=0
	for d in "${BACKUP_ROOT}"/$(basename "$WEB_DIR").bak-*; do
		[ -d "$d" ] || continue
		found=1
		printf "  %s  (%s)\n" "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
	done
	[ "$found" -eq 0 ] && echo "  (暂无快照)"
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
	restore-hook) require_root "$@"; cmd_restore_hook ;;
	status)       cmd_status ;;
	rollback)     require_root "$@"; cmd_rollback ;;
	*)
		echo "用法: sudo bash $0 {deploy|status|rollback|restore-hook}"
		exit 1
		;;
esac
