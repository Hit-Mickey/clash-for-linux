# shellcheck disable=SC2148
# shellcheck disable=SC1091
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
cd "$PROJECT_DIR" || exit 1

. script/common.sh >&/dev/null
. script/clashctl.sh >&/dev/null

_is_root || _error_quit "需要 root 或 sudo 权限执行"

# 无论服务当前是否存在或能否停止，都继续清理其余安装痕迹。
# clash 是旧版项目可能留下的服务名，保留兼容清理。
for service in mihomo clash; do
    systemctl disable --now "$service" >/dev/null 2>&1 || systemctl stop "$service" >/dev/null 2>&1
    rm -f -- "/etc/systemd/system/${service}.service"
    rm -f -- "/etc/systemd/system/multi-user.target.wants/${service}.service"
done
systemctl daemon-reload >/dev/null 2>&1
systemctl reset-failed mihomo clash >/dev/null 2>&1

# 清除安装过程中设置的桌面代理。sudo 安装时需要操作原用户的 dconf。
if command -v gsettings >/dev/null 2>&1; then
    user_uid=$(id -u "$CLASH_USER" 2>/dev/null)
    if [ "$CLASH_USER" = root ]; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_uid}/bus" \
            gsettings set org.gnome.system.proxy mode 'none' >/dev/null 2>&1
    elif [ -n "$user_uid" ]; then
        sudo -u "$CLASH_USER" env \
            XDG_RUNTIME_DIR="/run/user/${user_uid}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_uid}/bus" \
            gsettings set org.gnome.system.proxy mode 'none' >/dev/null 2>&1
    fi
fi
_unset_system_proxy

[ "$CLASH_GITHUB_PROXY" = '/opt/clash/github-proxy' ] && rm -f -- "$CLASH_GITHUB_PROXY"
[ "$CLASH_BASE_DIR" = '/opt/clash' ] && rm -rf -- "$CLASH_BASE_DIR"
[ "$RESOURCES_BIN_DIR" = './resources/bin' ] && rm -rf -- "$RESOURCES_BIN_DIR"
rm -f -- /var/proxy
find /run/user -maxdepth 2 -type f -name 'clash-for-linux.env' -delete 2>/dev/null
[ -n "$CLASH_CRON_TAB" ] && [ -f "$CLASH_CRON_TAB" ] &&
    sed -i '/clashupdate/d' "$CLASH_CRON_TAB"
_set_rc unset

_okcat '✨' '已完整卸载'
_quit
