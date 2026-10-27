# shellcheck disable=SC2148
# shellcheck disable=SC2155

_has_gsettings_proxy_schema() {
    command -v gsettings >/dev/null 2>&1 &&
        gsettings list-schemas 2>/dev/null | grep -qx 'org.gnome.system.proxy'
}

_set_system_proxy() {
    local mixed_port auth bind_addr
    # 每次从运行配置读取，避免依赖当前 Shell 中是否执行过 clashon。
    mixed_port=$(sudo "$BIN_YQ" -r '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME") || {
        _failcat '无法读取运行配置中的代理端口'
        return 1
    }
    [[ "$mixed_port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$mixed_port" -le 65535 ] || {
        _failcat "运行配置中的 mixed-port 无效：${mixed_port:-未配置}（应为 1–65535）"
        return 1
    }

    auth=$(sudo "$BIN_YQ" '.authentication[0] // ""' "$CLASH_CONFIG_RUNTIME") || {
        _failcat '无法读取运行配置中的代理认证信息'
        return 1
    }
    [ -n "$auth" ] && auth=$auth@

    bind_addr=$(sudo "$BIN_YQ" '.bind-address // ""' "$CLASH_CONFIG_RUNTIME") || {
        _failcat '无法读取运行配置中的代理地址'
        return 1
    }
    case $bind_addr in "" | "*" | "0.0.0.0") bind_addr=127.0.0.1 ;; esac
    local http_proxy_addr="http://${auth}${bind_addr}:${mixed_port}"
    local socks_proxy_addr="socks5h://${auth}${bind_addr}:${mixed_port}"
    
    # 为当前终端环境设置变量
    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy
    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy
    export no_proxy="localhost,127.0.0.1,::1,192.168.0.0/16,172.16.0.0/12,10.0.0.0/8"
    export NO_PROXY=$no_proxy

    # 设置 GNOME 桌面系统代理（如果有）
    if _has_gsettings_proxy_schema; then
        [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
        echo "🖥️ 检测到桌面环境，正在设置系统 GUI 代理..."
        
        if ! {
            gsettings set org.gnome.system.proxy ignore-hosts "['localhost', '127.*', '192.168.*', '10.*', '172.16.*', '172.17.*', '172.18.*', '172.19.*', '172.20.*', '172.21.*', '172.22.*', '172.23.*', '172.24.*', '172.25.*', '172.26.*', '172.27.*', '172.28.*', '172.29.*', '172.30.*', '172.31.*', '<local>']" &&

                gsettings set org.gnome.system.proxy.http host "$bind_addr" &&
                gsettings set org.gnome.system.proxy.http port "$mixed_port" &&

                gsettings set org.gnome.system.proxy.https host "$bind_addr" &&
                gsettings set org.gnome.system.proxy.https port "$mixed_port" &&

                gsettings set org.gnome.system.proxy.socks host "$bind_addr" &&
                gsettings set org.gnome.system.proxy.socks port "$mixed_port" &&

                gsettings set org.gnome.system.proxy mode 'manual'
        }; then
            _failcat '设置桌面系统代理失败'
            return 1
        fi
    fi
    return 0
}

_unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
    if _has_gsettings_proxy_schema; then
        [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
        gsettings set org.gnome.system.proxy mode 'none'
    fi
}

function clashon() {
    _get_proxy_port
    systemctl is-active "$BIN_KERNEL_NAME" >&/dev/null || {
        sudo systemctl start "$BIN_KERNEL_NAME" >/dev/null || {
            _failcat '启动失败: 执行 clashstatus 查看日志'
            return 1
        }
    }
    if clashproxy status >/dev/null; then
        _set_system_proxy || return 1
    fi
    _okcat '已开启代理环境'
}

watch_proxy() {
    # 新开交互式shell，且无代理变量时
    [ -z "$http_proxy" ] && [[ $- == *i* ]] && {
        # root用户自动开启代理环境（普通用户会触发sudo验证密码导致卡住）
        _is_root && clashon
    }
}

function clashoff() {
    sudo systemctl stop "$BIN_KERNEL_NAME" && _okcat '已关闭代理环境' ||
        _failcat '关闭失败: 执行 "clashstatus" 查看日志' || return 1
    _unset_system_proxy
}

clashrestart() {
    sudo systemctl restart "$BIN_KERNEL_NAME" >/dev/null || {
        _failcat '重启失败: 执行 "clashstatus" 查看日志'
        return 1
    }
}

function clashproxy() {
    case "$1" in
    on)
        systemctl is-active "$BIN_KERNEL_NAME" >&/dev/null || {
            _failcat '代理程序未运行，请执行 clashon 开启代理环境'
            return 1
        }
        sudo "$BIN_YQ" -i '.system-proxy.enable = true' "$CLASH_CONFIG_MIXIN" || {
            _failcat '无法保存系统代理配置'
            return 1
        }
        _set_system_proxy || return 1
        _okcat '已开启系统代理'
        ;;
    off)
        sudo "$BIN_YQ" -i '.system-proxy.enable = false' "$CLASH_CONFIG_MIXIN"
        _unset_system_proxy
        _okcat '已关闭系统代理'
        ;;
    status)
        local system_proxy_status=$(sudo "$BIN_YQ" '.system-proxy.enable' "$CLASH_CONFIG_MIXIN" 2>/dev/null)
        [ "$system_proxy_status" = "false" ] && {
            _failcat "系统代理：关闭"
            return 1
        }
        _okcat "系统代理：开启
http_proxy： $http_proxy
socks_proxy：$all_proxy"
        ;;
    *)
        cat <<EOF
用法: clashproxy [on|off|status]
    on      开启系统代理
    off     关闭系统代理
    status  查看系统代理状态
EOF
        ;;
    esac
}

function clashstatus() {
    sudo systemctl status "$BIN_KERNEL_NAME" "$@"
}

_show_clashui() {
    _get_ui_port
    # 公网ip
    # ifconfig.me
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --location --max-time 2 $query_url)
    local public_address="http://${public_ip:-公网}:${EXT_PORT}/ui"

    local local_ip=$EXT_IP
    local local_address="http://${local_ip}:${EXT_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$EXT_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}

_get_current_ui() {
    local ui
    ui=$(sudo "$BIN_YQ" -r '."external-ui" // ""' "$CLASH_CONFIG_MIXIN" 2>/dev/null)
    case "$ui" in
    metacubexd | zashboard) printf '%s\n' "$ui" ;;
    *)
        _failcat "当前 external-ui 配置不受支持：${ui:-未配置}"
        return 1
        ;;
    esac
}

_install_ui_release() {
    local target_ui=$1
    local tmp_dir release_json archive_file extract_dir ui_index ui_dir
    local latest_version latest_normalized current_version current_normalized
    local asset_url asset_digest expected_sha256
    local current_dir new_dir old_dir

    _set_ui_metadata "$target_ui" || {
        _failcat "不支持的 Web 控制面板：$target_ui"
        return 1
    }
    current_dir="${CLASH_BASE_DIR}/${target_ui}"
    new_dir="${current_dir}.new"
    old_dir="${current_dir}.old"

    tmp_dir=$(mktemp -d /tmp/clash-ui.XXXXXX) || {
        _failcat '无法创建面板升级临时目录'
        return 1
    }
    release_json="${tmp_dir}/release.json"
    archive_file="${tmp_dir}/${target_ui}.${UI_ARCHIVE_EXTENSION}"
    extract_dir="${tmp_dir}/ui"

    _okcat '⏳' "正在获取最新 $target_ui 稳定版..."
    _download_install_asset "$release_json" "$UI_RELEASE_API" json '' || {
        rm -rf -- "$tmp_dir"
        _failcat "无法获取 $target_ui 稳定版信息，面板未修改"
        return 1
    }

    latest_version=$(sudo "$BIN_YQ" -r '.tag_name // ""' "$release_json")
    asset_url=$(sudo "$BIN_YQ" -r ".assets[] | select(.name == \"$UI_ASSET_NAME\") | .browser_download_url" \
        "$release_json" | head -n 1)
    asset_digest=$(sudo "$BIN_YQ" -r ".assets[] | select(.name == \"$UI_ASSET_NAME\") | .digest // \"\"" \
        "$release_json" | head -n 1)
    expected_sha256=${asset_digest#sha256:}
    [ -n "$latest_version" ] && [ -n "$asset_url" ] || {
        rm -rf -- "$tmp_dir"
        _failcat '最新稳定版信息不完整，当前面板未修改'
        return 1
    }

    current_version=$(cat "${current_dir}/.version" 2>/dev/null)
    latest_normalized=${latest_version#v}
    latest_normalized=${latest_normalized#V}
    current_normalized=${current_version#v}
    current_normalized=${current_normalized#V}
    if [ -n "$current_normalized" ] &&
        [ "$(printf '%s\n' "$latest_normalized" "$current_normalized" | sort -V | tail -n 1)" = "$current_normalized" ]; then
        rm -rf -- "$tmp_dir"
        _okcat "$target_ui 已是最新稳定版：$current_version"
        return 0
    fi

    _okcat '⏳' "正在下载 $target_ui：$latest_version"
    _download_install_asset "$archive_file" "$asset_url" "$UI_ASSET_TYPE" "$expected_sha256" || {
        rm -rf -- "$tmp_dir"
        _failcat "$target_ui 下载失败，面板未修改"
        return 1
    }
    mkdir -p "$extract_dir"
    case "$UI_ARCHIVE_TYPE" in
    tar.gz) tar -xzf "$archive_file" -C "$extract_dir" ;;
    zip) unzip -oq "$archive_file" -d "$extract_dir" ;;
    *) false ;;
    esac || {
        rm -rf -- "$tmp_dir"
        _failcat "$target_ui 解压失败，面板未修改"
        return 1
    }
    ui_index=$(find "$extract_dir" -type f -name index.html | head -n 1)
    [ -n "$ui_index" ] || {
        rm -rf -- "$tmp_dir"
        _failcat '压缩包中未找到 index.html，当前面板未修改'
        return 1
    }
    ui_dir=$(dirname "$ui_index")

    sudo rm -rf -- "$new_dir" "$old_dir"
    sudo /bin/cp -rf "$ui_dir" "$new_dir" &&
        printf '%s\n' "$latest_version" | sudo tee "${new_dir}/.version" >/dev/null &&
        sudo test -f "${new_dir}/index.html" || {
        sudo rm -rf -- "$new_dir"
        rm -rf -- "$tmp_dir"
        _failcat '新面板准备失败，当前面板未修改'
        return 1
    }
    if [ -d "$current_dir" ]; then
        sudo /bin/mv "$current_dir" "$old_dir" || {
            sudo rm -rf -- "$new_dir"
            rm -rf -- "$tmp_dir"
            _failcat '无法备份当前面板'
            return 1
        }
    fi
    sudo /bin/mv "$new_dir" "$current_dir" || {
        [ ! -d "$old_dir" ] || sudo /bin/mv "$old_dir" "$current_dir"
        sudo rm -rf -- "$new_dir"
        rm -rf -- "$tmp_dir"
        _failcat '面板替换失败，已恢复原面板'
        return 1
    }

    sudo rm -rf -- "$old_dir"
    rm -rf -- "$tmp_dir"
    _okcat '✅' "$target_ui 已准备为稳定版 $latest_version"
}

_upgrade_clashui() {
    local current_ui
    current_ui=$(_get_current_ui) || return 1
    _install_ui_release "$current_ui" || return 1
    _okcat '请在浏览器中强制刷新页面'
}

_change_clashui() {
    local current_ui selected_ui choice

    current_ui=$(_get_current_ui) || return 1
    printf '%s\n' "当前 Web 控制面板：$current_ui"
    printf '%s\n' '当前支持的面板：'
    printf '%s\n' '  1. metacubexd'
    printf '%s\n' '  2. zashboard'
    printf '请选择面板 [1/2]：'
    read -r choice
    case "$choice" in
    1) selected_ui=metacubexd ;;
    2) selected_ui=zashboard ;;
    *)
        _failcat '无效选择，请输入 1 或 2'
        return 1
        ;;
    esac

    if [ "$selected_ui" = "$current_ui" ]; then
        _okcat "所选面板与当前面板相同，将升级 $current_ui"
        _install_ui_release "$current_ui" || return 1
        _okcat '请在浏览器中强制刷新页面'
        return 0
    fi

    _install_ui_release "$selected_ui" || return 1
    sudo "$BIN_YQ" -i ".\"external-ui\" = \"$selected_ui\"" "$CLASH_CONFIG_MIXIN" || {
        _failcat '无法写入面板配置'
        return 1
    }
    _merge_config && clashrestart || {
        _failcat '面板切换失败，正在恢复原配置'
        sudo "$BIN_YQ" -i ".\"external-ui\" = \"$current_ui\"" "$CLASH_CONFIG_MIXIN"
        _merge_config >/dev/null 2>&1
        clashrestart >/dev/null 2>&1
        return 1
    }
    _okcat "Web 控制面板已从 $current_ui 切换为 $selected_ui"
}

function clashui() {
    case "$1" in
    "") _show_clashui ;;
    upgrade) _upgrade_clashui ;;
    change) _change_clashui ;;
    *)
        _failcat '用法：clashui [upgrade|change]'
        return 1
        ;;
    esac
}

function ghproxy() {
    local proxies tmp_file

    case "$1" in
    "")
        proxies=$(_get_github_proxies)
        if [ -z "$proxies" ]; then
            _okcat 'GitHub 下载：官方链接'
        else
            _okcat 'GitHub 加速地址（按顺序尝试）：'
            printf '%s\n' "$proxies" | sed 's/^/  /'
        fi
        ;;
    -e | --edit)
        sudo touch "$CLASH_GITHUB_PROXY" || {
            _failcat '无法创建 GitHub 加速配置文件'
            return 1
        }
        sudo vim "$CLASH_GITHUB_PROXY" || return 1
        tmp_file=$(mktemp) || return 1
        _normalize_github_proxies <"$CLASH_GITHUB_PROXY" >"$tmp_file"
        sudo /usr/bin/install -m 0644 "$tmp_file" "$CLASH_GITHUB_PROXY" || {
            rm -f -- "$tmp_file"
            _failcat '无法保存 GitHub 加速配置'
            return 1
        }
        rm -f -- "$tmp_file"
        _okcat 'GitHub 加速配置已更新'
        ghproxy
        ;;
    *)
        _failcat '用法：ghproxy [-e]'
        return 1
        ;;
    esac
}

_merge_config() {
    local backup merged
    local has_backup=false
    backup=$(mktemp /tmp/clash-runtime.XXXXXX) || {
        _failcat "无法创建运行配置备份"
        return 1
    }
    merged=$(mktemp /tmp/clash-merged.XXXXXX) || {
        /bin/rm -f "$backup"
        _failcat "无法创建配置合并临时文件"
        return 1
    }
    [ -f "$CLASH_CONFIG_RUNTIME" ] && {
        sudo /bin/cp -f "$CLASH_CONFIG_RUNTIME" "$backup" || {
            /bin/rm -f "$backup" "$merged"
            _failcat "运行配置备份失败"
            return 1
        }
        has_backup=true
    }
    sudo "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$CLASH_CONFIG_MIXIN" "$CLASH_CONFIG_RAW" "$CLASH_CONFIG_MIXIN" >"$merged" || {
        /bin/rm -f "$backup" "$merged"
        _failcat "配置合并失败"
        return 1
    }
    sudo tee "$CLASH_CONFIG_RUNTIME" <"$merged" >&/dev/null || {
        if [ "$has_backup" = true ]; then
            sudo /bin/cp -f "$backup" "$CLASH_CONFIG_RUNTIME"
        else
            sudo /bin/rm -f "$CLASH_CONFIG_RUNTIME"
        fi
        /bin/rm -f "$backup" "$merged"
        _failcat "运行配置写入失败"
        return 1
    }
    _valid_config "$CLASH_CONFIG_RUNTIME" || {
        if [ "$has_backup" = true ]; then
            sudo /bin/cp -f "$backup" "$CLASH_CONFIG_RUNTIME"
        else
            sudo /bin/rm -f "$CLASH_CONFIG_RUNTIME"
        fi
        /bin/rm -f "$backup" "$merged"
        _failcat "验证失败：请检查 Mixin 配置"
        return 1
    }
    /bin/rm -f "$backup" "$merged"
}

function clashsecret() {
    case "$#" in
    0)
        _okcat "当前密钥：$(sudo "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME")"
        ;;
    1)
        sudo "$BIN_YQ" -i ".secret = \"$1\"" "$CLASH_CONFIG_MIXIN" || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config && clashrestart || return 1
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    local tun_status=$(sudo "$BIN_YQ" '.tun.enable' "${CLASH_CONFIG_RUNTIME}")
    # shellcheck disable=SC2015
    [ "$tun_status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    sudo "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
    _merge_config && clashrestart && _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    sudo "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config && clashrestart || return 1
    sleep 0.5s
    sudo journalctl -u "$BIN_KERNEL_NAME" --since "1 min ago" | grep -E -m1 'unsupported kernel version|Start TUN listening error' && {
        _tunoff >&/dev/null
        _error_quit '不支持的内核版本'
    }
    _okcat "Tun 模式已开启"
}

function clashtun() {
    case "$1" in
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _tunstatus
        ;;
    esac
}

function clashupdate() {
    local url=$(cat "$CLASH_CONFIG_URL")
    local is_auto

    case "$1" in
    auto)
        is_auto=true
        [ -n "$2" ] && url=$2
        ;;
    log)
        sudo tail "${CLASH_UPDATE_LOG}" 2>/dev/null || _failcat "暂无更新日志"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接：使用 ${CLASH_CONFIG_RAW} 进行更新..."
        url="file://$CLASH_CONFIG_RAW"
    }

    # 如果是自动更新模式，则设置定时任务
    [ "$is_auto" = true ] && {
        sudo grep -qs 'clashupdate' "$CLASH_CRON_TAB" || echo "0 0 */1 * * $_SHELL -i -c 'clashupdate $url'" | sudo tee -a "$CLASH_CRON_TAB" >&/dev/null
        _okcat "已设置定时更新订阅" && return 0
    }

    _okcat '👌' "正在下载：原配置已备份..."
    sudo cat "$CLASH_CONFIG_RAW" | sudo tee "$CLASH_CONFIG_RAW_BAK" >&/dev/null

    _rollback() {
        _failcat '🍂' "$1"
        sudo cat "$CLASH_CONFIG_RAW_BAK" | sudo tee "$CLASH_CONFIG_RAW" >&/dev/null
        _merge_config >/dev/null 2>&1
        [ "$2" = restart ] && clashrestart >/dev/null 2>&1
        _failcat '❌' "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" 2>&1 | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
        _error_quit
    }

    _download_config "$CLASH_CONFIG_RAW" "$url" || _rollback "下载失败：已回滚配置"
    _valid_config "$CLASH_CONFIG_RAW" || _rollback "转换失败：已回滚配置，转换日志：$BIN_SUBCONVERTER_LOG"

    _merge_config && clashrestart && _okcat '🍃' '订阅更新成功' || _rollback "配置应用失败：已回滚配置" restart
    echo "$url" | sudo tee "$CLASH_CONFIG_URL" >&/dev/null
    _okcat '✅' "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新成功：$url" | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
}

function clashmixin() {
    case "$1" in
    -e)
        sudo vim "$CLASH_CONFIG_MIXIN" && {
            _merge_config && clashrestart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less -f "$CLASH_CONFIG_RUNTIME"
        ;;
    *)
        less -f "$CLASH_CONFIG_MIXIN"
        ;;
    esac
}

# 在子 Shell 中完成替换与清理，避免修改调用者的 trap。
_renew_clash_scripts() (
    local tmp_dir='' stage_dir='' lock_dir='' file fish_file=''
    local update_started=false fish_changed=false committed=false

    _cleanup_renew() {
        local exit_code=$? keep_stage=false
        if [ "$update_started" = true ] && [ "$committed" = false ]; then
            if sudo test -d "${stage_dir}/previous"; then
                if { ! sudo test -e "$CLASH_SCRIPT_DIR" ||
                    sudo /bin/mv "$CLASH_SCRIPT_DIR" "${stage_dir}/failed"; } &&
                    sudo /bin/mv "${stage_dir}/previous" "$CLASH_SCRIPT_DIR"; then
                    :
                else
                    keep_stage=true
                    _failcat "脚本恢复失败，备份保留在：${stage_dir}/previous"
                fi
            fi
            if [ "$fish_changed" = true ]; then
                sudo /bin/cp -p "${stage_dir}/fish.previous" "$fish_file" || {
                    keep_stage=true
                    _failcat "Fish 配置恢复失败，备份保留在：${stage_dir}/fish.previous"
                }
            fi
        fi
        [ -z "$stage_dir" ] || [ "$keep_stage" = true ] || sudo /bin/rm -rf -- "$stage_dir"
        [ -z "$lock_dir" ] || sudo rmdir -- "$lock_dir"
        [ -z "$tmp_dir" ] || rm -rf -- "$tmp_dir"
        return "$exit_code"
    }
    trap _cleanup_renew EXIT

    tmp_dir=$(mktemp -d /tmp/clash-renew.XXXXXX) || {
        _failcat '无法创建脚本更新临时目录'
        return 1
    }
    _okcat '正在下载最新管理脚本...'
    _download_install_asset "${tmp_dir}/scripts.tar.gz" "$URL_CLASH_SCRIPTS_ARCHIVE" tar.gz '' || {
        _failcat '管理脚本下载失败，现有脚本未修改'
        return 1
    }
    # 仅取出管理脚本，三份文件均来自同一个归档。
    for file in common.sh clashctl.sh clashctl.fish; do
        tar -xOf "${tmp_dir}/scripts.tar.gz" "clash-for-linux-master/script/${file}" >"${tmp_dir}/${file}" &&
            [ -s "${tmp_dir}/${file}" ] || {
            _failcat "更新归档缺少有效脚本：$file"
            return 1
        }
    done
    for file in common.sh clashctl.sh; do
        bash -n "${tmp_dir}/${file}" || {
            _failcat "脚本语法检查失败：$file"
            return 1
        }
        if command -v zsh >/dev/null 2>&1; then
            zsh -n "${tmp_dir}/${file}" || {
                _failcat "Zsh 语法检查失败：$file"
                return 1
            }
        fi
    done
    grep -Eq '^(function[[:space:]]+)?clashrenew[[:space:]]*\(\)' "${tmp_dir}/clashctl.sh" || {
        _failcat '下载的脚本缺少 clashrenew 更新入口，请确认仓库已发布新版'
        return 1
    }
    if command -v fish >/dev/null 2>&1; then
        fish -n "${tmp_dir}/clashctl.fish" || {
            _failcat 'Fish 脚本语法检查失败'
            return 1
        }
    fi

    sudo mkdir "${CLASH_BASE_DIR}/.renew.lock" || {
        _failcat '无法取得脚本更新锁，请检查权限或是否已有更新正在进行'
        return 1
    }
    lock_dir="${CLASH_BASE_DIR}/.renew.lock"
    stage_dir=$(sudo mktemp -d "${CLASH_BASE_DIR}/.renew.XXXXXX") &&
        sudo mkdir -m 0755 "${stage_dir}/new" || {
        _failcat '无法准备脚本更新目录'
        return 1
    }
    for file in common.sh clashctl.sh clashctl.fish; do
        sudo /usr/bin/install -m 0644 "${tmp_dir}/${file}" "${stage_dir}/new/${file}" || {
            _failcat "无法准备新脚本：$file"
            return 1
        }
    done
    if [ -n "$SHELL_RC_FISH" ] && [ -f "$SHELL_RC_FISH" ]; then
        fish_file=$SHELL_RC_FISH
        sudo /bin/cp -p "$fish_file" "${stage_dir}/fish.previous" || {
            _failcat '无法备份 Fish 配置，现有脚本未修改'
            return 1
        }
    fi

    update_started=true
    sudo /bin/mv "$CLASH_SCRIPT_DIR" "${stage_dir}/previous" &&
        sudo /bin/mv "${stage_dir}/new" "$CLASH_SCRIPT_DIR" || {
        _failcat '替换管理脚本失败，正在恢复原脚本'
        return 1
    }
    if [ -n "$fish_file" ]; then
        fish_changed=true
        sudo /bin/cp "${CLASH_SCRIPT_DIR}/clashctl.fish" "$fish_file" || {
            _failcat '更新 Fish 配置失败，正在恢复原文件'
            return 1
        }
    fi
    committed=true
)

function clashrenew() {
    case "$1" in
    -h | --help)
        printf '%s\n' '用法：clashrenew（或 clashctl renew）' \
            '同步本项目 master 分支的管理脚本，保留配置、内核和控制面板。'
        return 0
        ;;
    "") ;;
    *)
        _failcat '用法：clashrenew（或 clashctl renew）'
        return 1
        ;;
    esac

    _renew_clash_scripts || return 1
    . "$CLASH_SCRIPT_DIR/common.sh" && . "$CLASH_SCRIPT_DIR/clashctl.sh" || {
        _failcat '脚本已更新，但当前终端加载失败，请重新打开终端'
        return 1
    }
    _okcat '管理脚本已更新并重新加载；其他已打开的终端请重新打开后使用'
}

function clashupgrade() {
    local arch asset_pattern fallback_pattern
    local tmp_dir release_json asset_url asset_name asset_digest expected_sha256
    local release_version current_version current_version_output local_is_alpha
    local archive_file kernel_file backup_file

    case "$1" in
    -h | --help)
        cat <<EOF

- 升级到最新稳定版
  clashupgrade

EOF
        return 0
        ;;
    "" | release) ;;
    *)
        _failcat '仅支持升级到最新稳定版：clashupgrade'
        return 1
        ;;
    esac

    case "$(uname -m)" in
    x86_64 | amd64)
        asset_pattern='mihomo-linux-amd64-compatible-.*\.gz$'
        fallback_pattern='mihomo-linux-amd64-.*\.gz$'
        ;;
    i386 | i486 | i586 | i686)
        asset_pattern='mihomo-linux-386-.*\.gz$'
        ;;
    aarch64 | arm64)
        asset_pattern='mihomo-linux-arm64-.*\.gz$'
        ;;
    armv7*)
        asset_pattern='mihomo-linux-armv7-.*\.gz$'
        ;;
    armv6*)
        asset_pattern='mihomo-linux-armv6-.*\.gz$'
        ;;
    armv*)
        asset_pattern='mihomo-linux-armv5-.*\.gz$'
        ;;
    *)
        _failcat "暂不支持当前架构：$(uname -m)"
        return 1
        ;;
    esac

    tmp_dir=$(mktemp -d) || {
        _failcat "无法创建内核升级临时目录"
        return 1
    }
    release_json="${tmp_dir}/release.json"
    archive_file="${tmp_dir}/mihomo.gz"
    kernel_file="${tmp_dir}/mihomo"
    backup_file="${BIN_MIHOMO}.bak"

    _okcat '获取 Mihomo 最新稳定版信息...'
    _download_install_asset "$release_json" "$URL_MIHOMO_RELEASE_API" json '' || {
        rm -rf "$tmp_dir"
        _failcat "无法获取 GitHub Release 信息"
        return 1
    }

    release_version=$(sudo "$BIN_YQ" -r '.tag_name // ""' "$release_json" |
        grep -Eo '[vV]?[0-9]+(\.[0-9]+){1,3}' | head -n 1 | sed 's/^[vV]//')

    asset_url=$(sudo "$BIN_YQ" -r '.assets[].browser_download_url' "$release_json" |
        grep -E -m 1 "/${asset_pattern}")
    [ -z "$asset_url" ] && [ -n "$fallback_pattern" ] && {
        asset_url=$(sudo "$BIN_YQ" -r '.assets[].browser_download_url' "$release_json" |
            grep -E -m 1 "/${fallback_pattern}")
    }
    [ -n "$asset_url" ] || {
        rm -rf "$tmp_dir"
        _failcat "未找到适用于 $(uname -m) 的 Mihomo 内核"
        return 1
    }

    [ -z "$release_version" ] &&
        release_version=$(printf '%s\n' "$asset_url" |
            grep -Eo '[vV]?[0-9]+(\.[0-9]+){1,3}' | head -n 1 | sed 's/^[vV]//')
    current_version_output=$(timeout 5 sudo "$BIN_MIHOMO" -v 2>/dev/null)
    current_version=$(printf '%s\n' "$current_version_output" |
        grep -Eo '[vV]?[0-9]+(\.[0-9]+){1,3}' | head -n 1 | sed 's/^[vV]//')
    local_is_alpha=false
    printf '%s\n' "$current_version_output" | grep -iqE 'alpha|prerelease' && local_is_alpha=true

    if [ -n "$release_version" ] && [ -n "$current_version" ] &&
        [ "$local_is_alpha" = false ] &&
        [ "$(printf '%s\n' "$release_version" "$current_version" | sort -V | tail -n 1)" = "$current_version" ]; then
        rm -rf "$tmp_dir"
        _okcat "当前 Mihomo 已是最新稳定版：v$current_version"
        return 0
    fi

    asset_name=$(basename "$asset_url")
    asset_digest=$(sudo "$BIN_YQ" -r ".assets[] | select(.name == \"$asset_name\") | .digest // \"\"" "$release_json")
    expected_sha256=${asset_digest#sha256:}

    _okcat "下载内核：$asset_name"
    _download_install_asset "$archive_file" "$asset_url" gzip "$expected_sha256" || {
        rm -rf "$tmp_dir"
        _failcat 'Mihomo 下载失败'
        return 1
    }

    gzip -dc "$archive_file" >"$kernel_file" && rm -f "$archive_file" || {
        rm -rf "$tmp_dir"
        _failcat "Mihomo 内核解压失败"
        return 1
    }
    sudo chmod +x "$kernel_file" || {
        rm -rf "$tmp_dir"
        _failcat "无法为 Mihomo 内核设置执行权限"
        return 1
    }

    sudo /usr/bin/install -m 0755 "$kernel_file" "${BIN_MIHOMO}.new" &&
        sudo chmod +x "${BIN_MIHOMO}.new" &&
        sudo "${BIN_MIHOMO}.new" -v >/dev/null 2>&1 &&
        sudo /bin/cp -f "$BIN_MIHOMO" "$backup_file" &&
        sudo /bin/mv -f "${BIN_MIHOMO}.new" "$BIN_MIHOMO" || {
        sudo /bin/rm -f "${BIN_MIHOMO}.new" "$backup_file"
        rm -rf "$tmp_dir"
        _failcat "替换 Mihomo 内核失败，原内核未被修改"
        return 1
    }

    _okcat "重启 Mihomo（Clash 内核）服务..."
    sudo systemctl restart mihomo && sleep 1 && sudo systemctl is-active --quiet mihomo || {
        _failcat "新内核启动失败，正在恢复旧内核..."
        sudo /bin/cp -f "$backup_file" "$BIN_MIHOMO"
        sudo chmod +x "$BIN_MIHOMO"
        sudo systemctl restart mihomo
        sudo /bin/rm -f "$backup_file"
        rm -rf "$tmp_dir"
        return 1
    }

    sudo /bin/rm -f "$backup_file"
    rm -rf "$tmp_dir"
    _okcat "Mihomo 内核已升级到最新稳定版，服务已重启"
}

function clashctl() {
    case "$1" in
    on)
        clashon
        ;;
    off)
        clashoff
        ;;
    restart)
        clashrestart
        ;;
    ui)
        shift
        clashui "$@"
        ;;
    ghproxy)
        shift
        ghproxy "$@"
        ;;
    status)
        shift
        clashstatus "$@"
        ;;
    proxy)
        shift
        clashproxy "$@"
        ;;
    tun)
        shift
        clashtun "$@"
        ;;
    mixin)
        shift
        clashmixin "$@"
        ;;
    secret)
        shift
        clashsecret "$@"
        ;;
    update)
        shift
        clashupdate "$@"
        ;;
    upgrade)
        shift
        clashupgrade "$@"
        ;;
    renew)
        shift
        clashrenew "$@"
        ;;
    *)
        shift
        clashhelp "$@"
        ;;
    esac
}

clashhelp() {
    cat <<EOF
    
Usage:
    clashctl COMMAND  [OPTION]

Commands:
    on                      开启代理
    off                     关闭代理
    restart                 重启 Mihomo 服务
    proxy    [on|off|status] 系统代理
    ui       [upgrade|change] 面板地址/更新/切换面板
    ghproxy  [-e]           查看/编辑 GitHub 加速地址
    status                  内核状况
    tun      [on|off]       Tun 模式
    mixin    [-e|-r]        Mixin 配置
    secret   [SECRET]       Web 密钥
    update   [URL|auto|log] 更新订阅
    upgrade                 升级稳定版内核
    renew                   更新本项目管理脚本

EOF
}
