set fn_arr \
clashui \
clashstatus \
clashrestart \
clashsecret \
clashtun \
clashmixin \
clashupdate \
clashupgrade \
ghproxy \
clashhelp

set -gx fish_version $FISH_VERSION

for fn in $fn_arr
    eval "
    function $fn
        bash -i -c '$fn \"\$@\"' -- \$argv
    end
    "
end


function clashctl
    if test -z "$argv"
        clashhelp
        return
    end


    set suffix $argv[1]
    set argv $argv[2..-1]

    switch $suffix
        case on
            clashon $argv
        case off
            clashoff $argv
        case '*'
            clash"$suffix" $argv
    end
end

function _clash_sync_proxy_env
    # NUL 分隔的数据只作为变量值读取，认证信息不会被当作 Shell 代码执行。
    set -l proxy_values (bash -c '
        source /opt/clash/script/common.sh && source /opt/clash/script/clashctl.sh || exit 1
        _sync_proxy_env quiet || exit 1
        if [ "$_CLASH_PROXY_STATE" = on ]; then
            printf "%s\0" on "$http_proxy" "$all_proxy" "$no_proxy"
        else
            printf "%s\0" off
        fi
    ' 2>/dev/null | string split0)
    if test (count $proxy_values) -eq 4; and test "$proxy_values[1]" = on
        set -gx http_proxy "$proxy_values[2]"
        set -gx https_proxy "$proxy_values[2]"
        set -gx HTTP_PROXY "$proxy_values[2]"
        set -gx HTTPS_PROXY "$proxy_values[2]"
        set -gx all_proxy "$proxy_values[3]"
        set -gx ALL_PROXY "$proxy_values[3]"
        set -gx no_proxy "$proxy_values[4]"
        set -gx NO_PROXY "$proxy_values[4]"
    else if test (count $proxy_values) -eq 1; and test "$proxy_values[1]" = off
        for proxy_var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
            set -e $proxy_var
        end
    else
        return 1
    end
    return 0
end

function _clash_proxy_prompt --on-event fish_prompt
    set -l previous_status $status
    _clash_sync_proxy_env
    return $previous_status
end

function _clash_proxy_preexec --on-event fish_preexec
    set -l previous_status $status
    _clash_sync_proxy_env
    return $previous_status
end

function clashon
    bash -i -c 'clashon'
    set -l command_status $status
    _clash_sync_proxy_env
    return $command_status
end

function clashoff
    bash -i -c 'clashoff'
    set -l command_status $status
    _clash_sync_proxy_env
    return $command_status
end

function clashproxy
    bash -i -c 'clashproxy "$@"' -- $argv
    set -l command_status $status
    _clash_sync_proxy_env
    return $command_status
end

function clashrenew
    bash -i -c 'clashrenew "$@"' -- $argv; or return 1
    source "$HOME/.config/fish/conf.d/clashctl.fish"
end
