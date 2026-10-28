# shellcheck shell=dash
# shellcheck disable=SC3043 # busybox ash has `local`; podkop's own script relies on it
# shellcheck disable=SC2016 # single-quoted jq filters use jq's own $vars, not the shell's
# podkop-sub: proxy links and the names in them - no state of ours, no podkop

# podkop cannot build a vmess outbound, so vmess:// lines are skipped, not supported
SUPPORTED_SCHEMES='vless ss trojan hy2 hysteria2 socks socks4 socks5'

sub_id() { printf '%s' "$1" | md5sum | cut -c1-12; }

# stdin -> stdout: pass a link list through, base64-decode anything else
decode_body() {
    local body b64 out
    body=$(cat)
    case "$(printf '%s' "$body" | head -c 200)" in
        *://*)
            printf '%s\n' "$body"
            return 0
            ;;
    esac
    b64=$(printf '%s' "$body" | tr -d ' \t\r\n' | tr '_-' '/+')
    case "$b64" in '' | *[!A-Za-z0-9+/=]*) return 0 ;; esac
    case $((${#b64} % 4)) in
        1) return 0 ;;
        2) b64="$b64==" ;;
        3) b64="$b64=" ;;
    esac
    out=$(printf '%s' "$b64" | base64 -d 2> /dev/null) || return 0
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

# podkop 0.7.24 aborts on an xhttp link unless sing-box reports it can decode the link itself
can_decode_link() { sing-box version 2> /dev/null | grep -Eq '^Features:.*[ ,]tools\.decode-link(,|$)'; }

# stdin -> stdout: only lines that start with a scheme podkop can build an outbound from
filter_links() {
    local xhttp='^(vless|trojan)://[^#]*[?&]type=(xhttp|splithttp)(&|#|$)'
    can_decode_link && xhttp='^$'
    tr -d '\r' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
        grep -E "^($(echo "$SUPPORTED_SCHEMES" | tr ' ' '|'))://" |
        grep -Ev "$xhttp"
    return 0
}

# an address in the log stays recognisable without naming the endpoint: 92.5.7.206 -> 92.x.x.206
mask_host() {
    local h="$1" port='' a b c d
    # an IPv6 holds colons of its own: keep the first and last group, bracketed form included
    case "$h" in
        *:*:*)
            h=${1#[}
            port=''
            case "$h" in *']:'*) port=":${h##*]:}"; h=${h%%]:*} ;; esac
            h=${h%]}
            printf '%s:x:%s%s' "${h%%:*}" "${h##*:}" "$port"
            return 0
            ;;
        *:*)
            port=":${h##*:}"
            h=${h%:*}
            ;;
    esac
    # an IPv4 keeps its first and last octet, which is enough to tell two providers apart
    IFS=. read -r a b c d <<EOF
$h
EOF
    case "$a.$b.$c.$d" in
        *[!0-9.]* | .*) ;;
        *)
            [ -n "$d" ] && {
                printf '%s.x.x.%s%s' "$a" "$d" "$port"
                return 0
            }
            ;;
    esac
    # a name keeps its first and last label; two labels have no middle to hide
    case "$h" in
        *.*.*) printf '%s.x.%s%s' "${h%%.*}" "${h##*.}" "$port" ;;
        *) printf '%s%s' "$h" "$port" ;;
    esac
}

# a provider's label reaches the log as it is; a name that is only an address gets masked
safe_name() {
    case "$1" in
        '' | *[!0-9A-Za-z.:_-]*) printf '%s' "$1" ;;
        *.*) mask_host "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

link_hostport() {
    local r
    r=${1#*://}
    r=${r%%#*}
    r=${r%%\?*}
    r=${r#*@}
    r=${r%%/*}
    printf '%s' "$r"
}

# podkop splits link lists with word splitting, so a literal space in #name breaks it
sanitize_link() {
    case "$1" in
        *'#'*)
            printf '%s#%s\n' "${1%%#*}" \
                "$(printf '%s' "${1#*#}" | sed 's/ /%20/g; s/\t/%09/g')"
            ;;
        *) printf '%s#%s\n' "$1" "$(link_hostport "$1")" ;;
    esac
}

link_name() {
    case "$1" in
        *'#'*) ;;
        *)
            link_hostport "$1"
            return 0
            ;;
    esac
    # %XX -> \xXX -> raw byte, so multi-byte UTF-8 names survive
    printf '%b' "$(printf '%s' "${1#*#}" | sed 's/\\/\\\\/g; s/%/\\x/g')"
}

parse_subscription() {
    local l
    decode_body | filter_links | while IFS= read -r l; do
        sanitize_link "$l"
    done | awk '!seen[$0]++'
}

# one uci list item per line: a node name may hold spaces and must never word-split
append_line() { printf '%s\n' "$1" >> "$2"; }

# the names a subscription currently offers, one per line, in the cached list's order
sub_names() {
    local l
    [ -s "$CACHE_DIR/$1.lst" ] || return 0
    # link_name prints no newline of its own: every other caller reads it through $( )
    while IFS= read -r l; do
        link_name "$l"
        printf '\n'
    done < "$CACHE_DIR/$1.lst"
}

# <cached list> <chosen names> - nothing chosen means all, nothing matching means the first node
pick_links() {
    local lst="$1" want="$2" l hit=0
    if [ ! -s "$want" ]; then
        cat "$lst"
        return 0
    fi
    while IFS= read -r l; do
        grep -Fxq "$(link_name "$l")" "$want" || continue
        printf '%s\n' "$l"
        hit=1
    done < "$lst"
    [ "$hit" = 1 ] || head -n 1 "$lst"
}

# ui_field <header line> <key> - one number out of subscription-userinfo
ui_field() { printf '%s' "$1" | sed -n "s/.*[ ;:]$2=\([0-9][0-9]*\).*/\1/p"; }
