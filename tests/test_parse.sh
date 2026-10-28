#!/bin/sh
# shellcheck shell=dash
# L1: the pure parser functions, sourced straight out of the link module.
set -u
. tests/lib.sh

# shellcheck source=luci-app-podkop-sub/root/usr/share/podkop-sub/lib/link.sh
. luci-app-podkop-sub/root/usr/share/podkop-sub/lib/link.sh

# --- sub_id

id=$(sub_id "https://panel.example.net/sub/token")
assert_eq "12" "${#id}" "sub_id is 12 characters"
assert_eq "$id" "$(sub_id "https://panel.example.net/sub/token")" "sub_id is stable"

# --- parse_subscription

plain=$(parse_subscription < tests/fixtures/plain.txt)
assert_eq "3" "$(printf '%s\n' "$plain" | wc -l | tr -d ' ')" "plain.txt yields 3 links"
assert_eq "" "$(printf '%s\n' "$plain" | grep vmess)" "vmess is dropped (podkop cannot build it)"

b64=$(parse_subscription < tests/fixtures/base64.txt)
assert_eq "$plain" "$b64" "base64.txt parses to the same links as plain.txt"

urlsafe=$(parse_subscription < tests/fixtures/base64-urlsafe.txt)
assert_eq "$plain" "$urlsafe" "unpadded url-safe base64 parses to the same links"

html=$(parse_subscription < tests/fixtures/html.txt)
rc=$?
assert_eq "0" "$rc" "an HTML error page does not make the parser fail"
assert_eq "" "$html" "an HTML error page yields no links"

empty=$(parse_subscription < tests/fixtures/empty.txt)
rc=$?
assert_eq "0" "$rc" "an empty body does not make the parser fail"
assert_eq "" "$empty" "an empty body yields no links"

dup=$(printf 'trojan://p@h.example.net:443#one\ntrojan://p@h.example.net:443#one\n' |
    parse_subscription)
assert_eq "trojan://p@h.example.net:443#one" "$dup" "identical links collapse into one"

xh='vless://u@h.example.net:443?security=tls&type=xhttp&path=/x#xh
trojan://p@h.example.net:443?type=splithttp#sh
vless://u@h.example.net:443?type=ws#name-type=xhttp'
assert_eq "vless://u@h.example.net:443?type=ws#name-type=xhttp" \
    "$(printf '%s\n' "$xh" | filter_links)" \
    "xhttp links are dropped while sing-box cannot decode them (podkop would abort)"
can_decode_link() { return 0; }
assert_eq "$xh" "$(printf '%s\n' "$xh" | filter_links)" \
    "xhttp links are kept once sing-box reports tools.decode-link"
unset -f can_decode_link
. luci-app-podkop-sub/root/usr/share/podkop-sub/lib/link.sh

# --- sanitize_link / link_name

first=$(printf '%s\n' "$plain" | sed -n 1p)
assert_contains "$first" "%20NL%2001%20Amsterdam" "spaces in #name are percent-encoded"
assert_eq "🇳🇱 NL 01 Amsterdam" "$(link_name "$first")" "link_name decodes %20 back to a space"

second=$(printf '%s\n' "$plain" | sed -n 2p)
assert_eq "ss://YWVzLTI1Ni1nY206c2VjcmV0cGFzcw==@node2.example.net:8388#node2.example.net:8388" \
    "$second" "a link without a fragment gets #host:port"
assert_eq "node2.example.net:8388" "$(link_name "$second")" "link_name of a generated fragment"

third=$(printf '%s\n' "$plain" | sed -n 3p)
assert_eq "🇩🇪 DE Frankfurt" "$(link_name "$third")" "a CRLF line is trimmed and its name decodes"

assert_eq "vless://u@h.example.net:443#a%09b" "$(sanitize_link "vless://u@h.example.net:443#a	b")" \
    "a tab in #name becomes %09"
assert_eq "vless://u@h.example.net:443?path=/x%20y#n" \
    "$(sanitize_link "vless://u@h.example.net:443?path=/x%20y#n")" \
    "nothing outside the fragment is touched"

test_summary
