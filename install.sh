# shellcheck disable=SC2148
# shellcheck disable=SC1091
. script/common.sh >&/dev/null
. script/clashctl.sh >&/dev/null

_valid_env

[ -d "$CLASH_BASE_DIR" ] && _error_quit "请先执行卸载脚本,以清除安装路径：$CLASH_BASE_DIR"

_configure_github_proxies || _error_quit 'GitHub 下载方式配置失败'
_configure_ui || _error_quit 'Web 控制面板配置失败'
trap _cleanup_install_tmp EXIT
_prepare_install_resources || _error_quit '安装资源准备失败'
_get_kernel

[ "$RESOURCES_BIN_DIR" = './resources/bin' ] || _error_quit '安装资源目录异常'
rm -rf -- "$RESOURCES_BIN_DIR"
mkdir -p "$RESOURCES_BIN_DIR" || _error_quit '无法创建安装资源目录'
_validate_install_asset "$ZIP_SUBCONVERTER" tar.gz '' || _error_quit 'subconverter 离线资源无效'
/usr/bin/install -Dm 0755 <(gzip -dc "$ZIP_KERNEL") "${RESOURCES_BIN_DIR}/$BIN_KERNEL_NAME" ||
    _error_quit 'Mihomo 解压失败'
tar -xzf "$ZIP_SUBCONVERTER" -C "$RESOURCES_BIN_DIR" || _error_quit 'subconverter 解压失败'
tar -xzf "$ZIP_YQ" -C "$RESOURCES_BIN_DIR" || _error_quit 'yq 解压失败'
yq_extracted=$(find "$RESOURCES_BIN_DIR" -maxdepth 1 -type f -name 'yq_linux_*' | head -n 1)
[ -n "$yq_extracted" ] || _error_quit 'yq 压缩包中未找到可执行文件'
/usr/bin/install -m 0755 "$yq_extracted" "${RESOURCES_BIN_DIR}/yq" || _error_quit 'yq 安装失败'
rm -f -- "$yq_extracted"

_set_bin "$RESOURCES_BIN_DIR"
"$BIN_MIHOMO" -v >/dev/null 2>&1 || _error_quit 'Mihomo 可执行文件验证失败'
"$BIN_YQ" --version >/dev/null 2>&1 || _error_quit 'yq 可执行文件验证失败'
[ -x "$BIN_SUBCONVERTER" ] || _error_quit 'subconverter 可执行文件验证失败'
url=""
_valid_config "$RESOURCES_CONFIG" || {
    # 检查变量 url 是否为空
    if [ -z "$url" ]; then
        echo -n "$(_okcat '✈️ ' '未检测到预配 URL，请输入订阅：')"
        read -r url
    else
        echo "$(_okcat '✅ ' '检测到预配 URL，自动跳过输入。')"
    fi
    _okcat '⏳' '正在下载...'
    _download_config "$RESOURCES_CONFIG" "$url" || _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG 后重新安装"
    _valid_config "$RESOURCES_CONFIG" || _error_quit "配置无效，请检查配置：$RESOURCES_CONFIG，转换日志：$BIN_SUBCONVERTER_LOG"
}
_okcat '✅' '配置可用'
mkdir "$CLASH_BASE_DIR" || _error_quit "无法创建安装目录：$CLASH_BASE_DIR"
printf '%s\n' "$url" >"$CLASH_CONFIG_URL" || _error_quit '无法保存订阅地址'
_save_github_proxies || _error_quit '无法保存 GitHub 加速地址配置'

/bin/cp -rf "$SCRIPT_BASE_DIR" "$CLASH_BASE_DIR" || _error_quit '脚本文件安装失败'
/bin/cp -rf "$RESOURCES_BIN_DIR" "${CLASH_BASE_DIR}/bin" || _error_quit '程序文件安装失败'
/usr/bin/install -m 0644 "$RESOURCES_CONFIG" "$CLASH_CONFIG_RAW" || _error_quit '订阅配置安装失败'
/usr/bin/install -m 0644 "$RESOURCES_CONFIG_MIXIN" "$CLASH_CONFIG_MIXIN" || _error_quit 'Mixin 配置安装失败'
/usr/bin/install -m 0644 "$COUNTRY_MMDB" "${CLASH_BASE_DIR}/Country.mmdb" ||
    _error_quit 'Country.mmdb 安装失败'
ui_extract_dir="${INSTALL_TMP_DIR}/ui"
mkdir -p "$ui_extract_dir"
case "$UI_ARCHIVE_TYPE" in
tar.gz) tar -xzf "$ZIP_UI" -C "$ui_extract_dir" ;;
zip) unzip -oq "$ZIP_UI" -d "$ui_extract_dir" ;;
*) _error_quit "$UI_NAME 压缩包类型无效" ;;
esac
ui_index=$(find "$ui_extract_dir" -type f -name index.html | head -n 1)
[ -n "$ui_index" ] || _error_quit "$UI_NAME 压缩包中未找到 index.html"
/bin/cp -rf "$(dirname "$ui_index")" "${CLASH_BASE_DIR}/${UI_NAME}" ||
    _error_quit "$UI_NAME 安装失败"
[ -z "$UI_VERSION" ] ||
    printf '%s\n' "$UI_VERSION" >"${CLASH_BASE_DIR}/${UI_NAME}/.version"

_set_rc || _error_quit 'Shell 配置安装失败'
_set_bin
secret=$(_get_random_val)
sudo "$BIN_YQ" -i ".secret = \"$secret\" | .\"external-ui\" = \"$UI_NAME\"" "$CLASH_CONFIG_MIXIN" || {
    _failcat "初始密钥或面板配置写入失败"
    exit 1
}
_merge_config || exit 1
cat <<EOF >"/etc/systemd/system/${BIN_KERNEL_NAME}.service"
[Unit]
Description=$BIN_KERNEL_NAME Daemon, A[nother] Clash Kernel.

[Service]
Type=simple
Restart=always
ExecStart=${BIN_KERNEL} -d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME}

[Install]
WantedBy=multi-user.target
EOF
[ $? -eq 0 ] || _error_quit 'systemd 服务文件写入失败'

systemctl daemon-reload || {
    _failcat "systemd 配置加载失败"
    exit 1
}
# systemctl enable "$BIN_KERNEL_NAME" >&/dev/null || _failcat '💥' "设置自启失败" && _okcat '🚀' "已设置开机自启"
systemctl start "$BIN_KERNEL_NAME" || {
    _failcat '启动失败: 执行 "clashstatus" 查看日志'
    exit 1
}
systemctl is-active --quiet "$BIN_KERNEL_NAME" || {
    _failcat '启动失败: 执行 "clashstatus" 查看日志'
    exit 1
}

clashui
clashsecret
clashctl
# shellcheck disable=SC2016
[ "$SUDO_USER" != 'root' ] && _okcat '请执行 clashon 开启代理环境'
_okcat '🎉' 'enjoy 🎉'
_quit
