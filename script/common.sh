# shellcheck disable=SC2148
# shellcheck disable=SC2034
# shellcheck disable=SC2155
[ -n "$BASH_VERSION" ] && set +o noglob
[ -n "$ZSH_VERSION" ] && setopt glob no_nomatch

# 最小化系统可能没有 sudo；root 直接执行时保持现有调用方式可用。
if [ "$(id -u)" -eq 0 ] && ! command -v sudo >/dev/null 2>&1; then
    sudo() { "$@"; }
fi

URL_MIHOMO_RELEASE_API='https://api.github.com/repos/MetaCubeX/mihomo/releases/latest'
URL_METACUBEXD='https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip'
URL_COUNTRY_MMDB='https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb'

SCRIPT_BASE_DIR='./script'
SCRIPT_FISH="${SCRIPT_BASE_DIR}/clashctl.fish"

RESOURCES_BASE_DIR='./resources'
RESOURCES_BIN_DIR="${RESOURCES_BASE_DIR}/bin"
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"

ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_SUBCONVERTER=$(find "$ZIP_BASE_DIR" -maxdepth 1 -type f -name 'subconverter*.tar.gz' | sort | head -n 1)
FALLBACK_UI="${ZIP_BASE_DIR}/metacubexd-gh-pages.zip"
FALLBACK_COUNTRY_MMDB="${RESOURCES_BASE_DIR}/Country.mmdb"
ZIP_MIHOMO=''
ZIP_YQ=''
ZIP_UI=''
COUNTRY_MMDB=''
INSTALL_TMP_DIR=''

CLASH_BASE_DIR='/opt/clash'
CLASH_SCRIPT_DIR="${CLASH_BASE_DIR}/$(basename $SCRIPT_BASE_DIR)"
CLASH_CONFIG_URL="${CLASH_BASE_DIR}/url"
CLASH_CONFIG_RAW="${CLASH_BASE_DIR}/$(basename $RESOURCES_CONFIG)"
CLASH_CONFIG_RAW_BAK="${CLASH_CONFIG_RAW}.bak"
CLASH_CONFIG_MIXIN="${CLASH_BASE_DIR}/$(basename $RESOURCES_CONFIG_MIXIN)"
CLASH_CONFIG_RUNTIME="${CLASH_BASE_DIR}/runtime.yaml"
CLASH_UPDATE_LOG="${CLASH_BASE_DIR}/clashupdate.log"

_set_var() {
    local user=$USER
    local user_home=$HOME
    [ -n "$SUDO_USER" ] && {
        user=$SUDO_USER
        user_home=$(awk -F: -v user="$SUDO_USER" '$1==user{print $6}' /etc/passwd)
    }
    CLASH_USER=$user
    CLASH_USER_HOME=$user_home

    [ -n "$BASH_VERSION" ] && {
        _SHELL=bash
    }
    [ -n "$ZSH_VERSION" ] && {
        _SHELL=zsh
    }
    [ -n "$fish_version" ] && {
        _SHELL=fish
    }

    # rc文件路径
    command -v bash >&/dev/null && {
        SHELL_RC_BASH="${user_home}/.bashrc"
    }
    command -v zsh >&/dev/null && {
        SHELL_RC_ZSH="${user_home}/.zshrc"
    }
    command -v fish >&/dev/null && {
        SHELL_RC_FISH="${user_home}/.config/fish/conf.d/clashctl.fish"
    }

    # 定时任务路径
    local os_info=$(cat /etc/os-release)
    echo "$os_info" | grep -iqsE "rhel|centos|openEuler|Rocky|AlmaLinux" && CLASH_CRON_TAB="/var/spool/cron/$user"
    echo "$os_info" | grep -iqsE "debian|ubuntu" && CLASH_CRON_TAB="/var/spool/cron/crontabs/$user"
    return 0
}
_set_var

_run_as_clash_user() {
    if [ "$CLASH_USER" = root ]; then
        "$@"
    else
        sudo -u "$CLASH_USER" -- "$@"
    fi
}

# shellcheck disable=SC2120
_set_bin() {
    local bin_base_dir="${CLASH_BASE_DIR}/bin"
    [ -n "$1" ] && bin_base_dir=$1
    BIN_MIHOMO="${bin_base_dir}/mihomo"
    BIN_YQ="${bin_base_dir}/yq"
    BIN_SUBCONVERTER_DIR="${bin_base_dir}/subconverter"
    BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
    BIN_SUBCONVERTER_PORT="25500"
    BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
    BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

    BIN_KERNEL=$BIN_MIHOMO
    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
}
_set_bin

_set_rc() {
    local rc_file
    local source_line="source $CLASH_SCRIPT_DIR/common.sh && source $CLASH_SCRIPT_DIR/clashctl.sh"

    [ "$1" = "unset" ] && {
        for rc_file in "${CLASH_USER_HOME}/.bashrc" "${CLASH_USER_HOME}/.zshrc"; do
            [ -n "$rc_file" ] && [ -f "$rc_file" ] &&
                _run_as_clash_user sed -i "\|$CLASH_SCRIPT_DIR|d" "$rc_file"
        done
        _run_as_clash_user rm -f -- "${CLASH_USER_HOME}/.config/fish/conf.d/clashctl.fish"
        return 0
    }

    for rc_file in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ -n "$rc_file" ] || continue
        grep -Fqx "$source_line" "$rc_file" 2>/dev/null ||
            _run_as_clash_user sh -c 'printf "%s\n" "$1" >>"$2"' sh "$source_line" "$rc_file"
    done
    if [ -n "$SHELL_RC_FISH" ]; then
        _run_as_clash_user mkdir -p "$(dirname "$SHELL_RC_FISH")"
        _run_as_clash_user /usr/bin/install "$SCRIPT_FISH" "$SHELL_RC_FISH"
    fi
    return 0
}

function _get_kernel() {
    ZIP_KERNEL=$ZIP_MIHOMO
    BIN_KERNEL=$BIN_MIHOMO
    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
    _okcat "安装内核：$BIN_KERNEL_NAME"
}

_validate_install_asset() {
    local file=$1
    local type=$2
    local expected_sha256=$3

    [ -s "$file" ] || return 1
    case "$type" in
    gzip) gzip -t "$file" >/dev/null 2>&1 || return 1 ;;
    tar.gz) tar -tzf "$file" >/dev/null 2>&1 || return 1 ;;
    zip)
        unzip -tqq "$file" >/dev/null 2>&1 &&
            unzip -l "$file" 2>/dev/null | grep -q '/index.html$' || return 1
        ;;
    mmdb)
        [ "$(wc -c <"$file")" -gt 100000 ] && grep -aq 'MaxMind.com' "$file" || return 1
        ;;
    json) grep -q '"browser_download_url"' "$file" || return 1 ;;
    esac

    [ -z "$expected_sha256" ] ||
        printf '%s  %s\n' "$expected_sha256" "$file" | sha256sum -c - >/dev/null 2>&1
}

_download_install_asset() {
    local dest=$1
    local url=$2
    local type=$3
    local expected_sha256=$4
    local download_url

    for download_url in \
        "$url" \
        "https://hubproxy-speedtest.mingqian.online/${url}" \
        "https://gh-proxy.org/${url}" \
        "https://gh-proxy.com/${url}" \
        "https://ghfast.top/${url}" \
        "https://ghproxy.net/${url}"; do
        rm -f "${dest}.part"
        curl \
            --silent \
            --show-error \
            --fail \
            --location \
            --connect-timeout 10 \
            --max-time 300 \
            --output "${dest}.part" \
            "$download_url" || continue
        _validate_install_asset "${dest}.part" "$type" "$expected_sha256" || continue
        mv -f "${dest}.part" "$dest"
        return 0
    done
    rm -f "${dest}.part"
    return 1
}

_fallback_install_asset() {
    local label=$1
    local fallback=$2
    local type=$3

    _validate_install_asset "$fallback" "$type" '' || {
        _failcat "$label 下载失败，且 resources 中没有可用的回退资源：$fallback"
        return 1
    }
    _failcat "$label 下载失败，使用 resources 中的离线资源"
    printf '%s\n' "$fallback"
}

_prepare_install_resources() {
    local machine_arch mihomo_arch yq_arch mihomo_pattern
    local release_json asset_url asset_name asset_digest expected_sha256 fallback

    machine_arch=$(uname -m)
    case "$machine_arch" in
    x86_64 | amd64)
        mihomo_arch='amd64-compatible'
        yq_arch='amd64'
        ;;
    i386 | i486 | i586 | i686)
        mihomo_arch='386'
        yq_arch='386'
        ;;
    aarch64 | arm64)
        mihomo_arch='arm64'
        yq_arch='arm64'
        ;;
    armv7*)
        mihomo_arch='armv7'
        yq_arch='arm'
        ;;
    armv6*)
        mihomo_arch='armv6'
        yq_arch='arm'
        ;;
    armv*)
        mihomo_arch='armv5'
        yq_arch='arm'
        ;;
    *)
        _failcat "暂不支持当前架构：$machine_arch"
        return 1
        ;;
    esac

    INSTALL_TMP_DIR=$(mktemp -d /tmp/clash-install.XXXXXX) || return 1
    release_json="${INSTALL_TMP_DIR}/mihomo-release.json"

    _okcat '⏳' '正在获取最新 Mihomo 版本...'
    if _download_install_asset "$release_json" "$URL_MIHOMO_RELEASE_API" json ''; then
        mihomo_pattern="mihomo-linux-${mihomo_arch}-.*\\.gz"
        asset_url=$(grep -Eo 'https://github.com/MetaCubeX/mihomo/releases/download/[^" ]+' "$release_json" |
            grep -E "/${mihomo_pattern}$" | head -n 1)
        asset_name=$(basename "$asset_url")
        asset_digest=$(awk -v name="$asset_name" '
            index($0, "\"name\": \"" name "\"") { found=1 }
            found && match($0, /"digest": "sha256:[0-9a-fA-F]+"/) {
                value=substr($0, RSTART, RLENGTH)
                sub(/^.*sha256:/, "", value)
                sub(/"$/, "", value)
                print value
                exit
            }
        ' "$release_json")
        expected_sha256=$asset_digest
    fi
    if [ -n "$asset_url" ] && _download_install_asset "${INSTALL_TMP_DIR}/mihomo.gz" "$asset_url" gzip "$expected_sha256"; then
        ZIP_MIHOMO="${INSTALL_TMP_DIR}/mihomo.gz"
        _okcat '✅' "已下载最新 Mihomo：$asset_name"
    else
        fallback=$(find "$ZIP_BASE_DIR" -maxdepth 1 -type f -name "mihomo-linux-${mihomo_arch}-*.gz" | sort -V | tail -n 1)
        [ -n "$fallback" ] || fallback=$(find "$ZIP_BASE_DIR" -maxdepth 1 -type f -name "mihomo-linux-${mihomo_arch%%-*}-*.gz" | sort -V | tail -n 1)
        ZIP_MIHOMO=$(_fallback_install_asset 'Mihomo' "$fallback" gzip) || return 1
    fi

    _okcat '⏳' '正在下载最新 yq...'
    if _download_install_asset "${INSTALL_TMP_DIR}/yq.tar.gz" \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}.tar.gz" tar.gz ''; then
        ZIP_YQ="${INSTALL_TMP_DIR}/yq.tar.gz"
        _okcat '✅' '已下载最新 yq'
    else
        fallback=$(find "$ZIP_BASE_DIR" -maxdepth 1 -type f -name "yq_linux_${yq_arch}.tar.gz" | sort -V | tail -n 1)
        ZIP_YQ=$(_fallback_install_asset 'yq' "$fallback" tar.gz) || return 1
    fi

    _okcat '⏳' '正在下载最新 metacubexd...'
    if _download_install_asset "${INSTALL_TMP_DIR}/metacubexd.zip" "$URL_METACUBEXD" zip ''; then
        ZIP_UI="${INSTALL_TMP_DIR}/metacubexd.zip"
        _okcat '✅' '已下载最新 metacubexd'
    else
        ZIP_UI=$(_fallback_install_asset 'metacubexd' "$FALLBACK_UI" zip) || return 1
    fi

    _okcat '⏳' '正在下载最新 Country.mmdb...'
    if _download_install_asset "${INSTALL_TMP_DIR}/Country.mmdb" "$URL_COUNTRY_MMDB" mmdb ''; then
        COUNTRY_MMDB="${INSTALL_TMP_DIR}/Country.mmdb"
        _okcat '✅' '已下载最新 Country.mmdb'
    else
        COUNTRY_MMDB=$(_fallback_install_asset 'Country.mmdb' "$FALLBACK_COUNTRY_MMDB" mmdb) || return 1
    fi
}

_get_random_port() {
    local randomPort=$(shuf -i 1024-65535 -n 1)
    ! _is_bind "$randomPort" && { echo "$randomPort" && return; }
    _get_random_port
}

function _get_proxy_port() {
    MIXED_PORT=$(sudo "$BIN_YQ" '.mixed-port' $CLASH_CONFIG_RUNTIME)

    _is_already_in_use "$MIXED_PORT" "$BIN_KERNEL_NAME" && {
        local newPort=$(_get_random_port)
        local msg="端口占用：${MIXED_PORT} 🎲 随机分配：$newPort"
        sudo "$BIN_YQ" -i ".mixed-port = $newPort" $CLASH_CONFIG_RUNTIME
        MIXED_PORT=$newPort
        _failcat '🎯' "$msg"
    }
}

function _get_ui_port() {
    local ext_addr=$(sudo "$BIN_YQ" '.external-controller // ""' $CLASH_CONFIG_RUNTIME)
    local ext_ip=${ext_addr%%:*}
    EXT_IP=$ext_ip
    EXT_PORT=${ext_addr##*:}
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    [ "$ext_ip" = '0.0.0.0' ] && EXT_IP=$(hostname -I | awk '{print $1}')
    _is_already_in_use "$EXT_PORT" "$BIN_KERNEL_NAME" && {
        local newPort=$(_get_random_port)
        local msg="端口占用：${EXT_PORT} 🎲 随机分配：$newPort"
        sudo "$BIN_YQ" -i ".external-controller = \"$ext_ip:$newPort\"" $CLASH_CONFIG_RUNTIME
        EXT_PORT=$newPort
        _failcat '🎯' "$msg"
    }
}

_get_color() {
    local hex="${1#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    printf "\e[38;2;%d;%d;%dm" "$r" "$g" "$b"
}
_get_color_msg() {
    local color=$(_get_color "$1")
    local msg=$2
    local reset="\033[0m"
    printf "%b%s%b\n" "$color" "$msg" "$reset"
}

_get_random_val() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 6
}

function _okcat() {
    local color=#c8d6e5
    local emoji=😼
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" && return 0
}

function _failcat() {
    local color=#fd79a8
    local emoji=😾
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" >&2 && return 1
}

function _quit() {
    local user=root
    [ -n "$SUDO_USER" ] && user=$SUDO_USER
    _cleanup_install_tmp
    [ "$user" = root ] && exec "$_SHELL" -i
    exec sudo -u "$user" -- "$_SHELL" -i
}

function _error_quit() {
    [ $# -gt 0 ] && {
        local color=#f92f60
        local emoji=📢
        [ $# -gt 1 ] && emoji=$1 && shift
        local msg="${emoji} $1"
        _get_color_msg "$color" "$msg"
    }
    _cleanup_install_tmp
    exec $_SHELL -i
}

_cleanup_install_tmp() {
    case "$INSTALL_TMP_DIR" in
    /tmp/clash-install.*)
        [ -d "$INSTALL_TMP_DIR" ] && rm -rf -- "$INSTALL_TMP_DIR"
        ;;
    esac
    INSTALL_TMP_DIR=''
}

_is_bind() {
    local port=$1
    { sudo ss -lnptu || sudo netstat -lnptu; } | grep ":${port}\b"
}

_is_already_in_use() {
    local port=$1
    local progress=$2
    _is_bind "$port" | grep -qs -v "$progress"
}

function _is_root() {
    [ "$(whoami)" = "root" ]
}

function _valid_env() {
    local required_command missing_commands=''
    _is_root || _error_quit "需要 root 或 sudo 权限执行"
    [ "$(ps -p 1 -o comm=)" != "systemd" ] && _error_quit "系统不具备 systemd"
    for required_command in curl gzip tar unzip sha256sum awk grep sed find sort head mktemp shuf systemctl; do
        command -v "$required_command" >/dev/null 2>&1 ||
            missing_commands="${missing_commands} ${required_command}"
    done
    [ -z "$missing_commands" ] || _error_quit "缺少必要命令：${missing_commands# }"
    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 ||
        _error_quit '缺少必要命令：ss 或 netstat'
}

function _valid_config() {
    [ -e "$1" ] && [ "$(wc -l <"$1")" -gt 1 ] && {
        local cmd msg
        cmd="sudo $BIN_KERNEL -d $(dirname "$1") -f $1 -t"
        msg=$(eval "$cmd") || {
            eval "$cmd"
            echo "$msg" | grep -qs "unsupport proxy type" && {
                local prefix="检测到订阅中包含不受支持的代理协议"
                _error_quit "${prefix}, 请检查并升级内核版本"
            }
        }
    }
}

_download_raw_config() {
    local dest=$1
    local url=$2
    local agent='clash-verge/v2.0.4'
    sudo curl \
        --silent \
        --show-error \
        --insecure \
        --location \
        --max-time 30 \
        --retry 1 \
        --user-agent "$agent" \
        --output "$dest" \
        "$url" ||
        sudo wget \
            --no-verbose \
            --no-check-certificate \
            --timeout 30 \
            --tries 1 \
            --user-agent "$agent" \
            --output-document "$dest" \
            "$url"
}
_download_convert_config() {
    local dest=$1
    local url=$2
    _start_convert
    local convert_url=$(
        target='clash'
        base_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
        curl \
            --get \
            --silent \
            --location \
            --output /dev/null \
            --data-urlencode "target=$target" \
            --data-urlencode "url=$url" \
            --write-out '%{url_effective}' \
            "$base_url"
    )
    _download_raw_config "$dest" "$convert_url"
    _stop_convert
}
function _download_config() {
    local dest=$1
    local url=$2
    [ "${url:0:4}" = 'file' ] && return 0
    _download_raw_config "$dest" "$url" || return 1
    _okcat '🍃' '下载成功：内核验证配置...'
    _valid_config "$dest" || {
        _failcat '🍂' "验证失败：尝试订阅转换..."
        _download_convert_config "$dest" "$url" || _failcat '🍂' "转换失败：请检查日志：$BIN_SUBCONVERTER_LOG"
    }
}

_start_convert() {
    _is_already_in_use $BIN_SUBCONVERTER_PORT 'subconverter' && {
        local newPort=$(_get_random_port)
        _failcat '🎯' "端口占用：$BIN_SUBCONVERTER_PORT 🎲 随机分配：$newPort"
        [ ! -e "$BIN_SUBCONVERTER_CONFIG" ] && {
            sudo /bin/cp -f "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
        }
        sudo "$BIN_YQ" -i ".server.port = $newPort" "$BIN_SUBCONVERTER_CONFIG"
        BIN_SUBCONVERTER_PORT=$newPort
    }
    local start=$(date +%s)
    # 子shell运行，屏蔽kill时的输出
    (sudo "$BIN_SUBCONVERTER" 2>&1 | sudo tee "$BIN_SUBCONVERTER_LOG" >/dev/null &)
    while ! _is_bind "$BIN_SUBCONVERTER_PORT" >&/dev/null; do
        sleep 1s
        local now=$(date +%s)
        [ $((now - start)) -gt 1 ] && _error_quit "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"
    done
}
_stop_convert() {
    sudo pkill -9 -f "$BIN_SUBCONVERTER" >&/dev/null
}
