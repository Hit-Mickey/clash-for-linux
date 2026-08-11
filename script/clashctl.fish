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

function clashon
    set -l proxy_env_file "/run/user/"(id -u)"/clash-for-linux.env"
    bash -i -c 'clashon || exit 1
umask 077
cat >"$1" <<EOF
export http_proxy=$http_proxy
export https_proxy=$http_proxy
export HTTP_PROXY=$http_proxy
export HTTPS_PROXY=$http_proxy

export all_proxy=$all_proxy
export ALL_PROXY=$all_proxy

export no_proxy=$no_proxy
export NO_PROXY=$no_proxy
EOF' -- "$proxy_env_file"; or return 1

    source "$proxy_env_file"
    rm -f "$proxy_env_file"
end

function clashoff
    bash -i -c 'clashoff'

    set -e \
    http_proxy \
    https_proxy \
    HTTP_PROXY \
    HTTPS_PROXY \
    all_proxy \
    ALL_PROXY \
    no_proxy \
    NO_PROXY
end
