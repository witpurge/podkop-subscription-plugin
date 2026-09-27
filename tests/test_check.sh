#!/bin/sh
# shellcheck shell=dash
# L2: check, its failover and the daemon, against the podkop and curl mocks.
set -u
. tests/lib.sh

ROOT=$PWD
MOCK_FIXTURE_DIR=$ROOT/tests/fixtures
MOCK_CALLS=/tmp/mock-calls-check
MOCK_PROXIES=/tmp/mock-proxies-check.json
MOCK_DEAD=''
MOCK_TCP_DEAD=''
MOCK_TCP_SILENT=''
export MOCK_FIXTURE_DIR MOCK_CALLS MOCK_PROXIES MOCK_DEAD MOCK_TCP_DEAD MOCK_TCP_SILENT

STATE=/etc/podkop-sub/state.json
LOG=/tmp/podkop-sub.log

# main is a selector over 5 links (NL, node2, DE from one subscription, FI, SG from the other),
# media a urltest over the first three
NL='🇳🇱 NL 01 Amsterdam'
N2='node2.example.net:8388'
# this fixture node carries no #fragment, so its name is its endpoint and the log masks it
N2_LOG='node2.x.net:8388'
DE='🇩🇪 DE Frankfurt'
FI='🇫🇮 FI Helsinki'
SG='SG Singapore'

# every scenario starts from a freshly applied stand
reset() { # [<selector position>]
    uci -q revert podkop
    uci -q revert podkop-sub
    rm -rf /etc/podkop-sub
    rm -f "$LOG"
    cp -r "$ROOT"/tests/mock/. /
    install_core
    cp "$ROOT/luci-app-podkop-sub/root/etc/init.d/podkop-sub" /etc/init.d/podkop-sub
    chmod +x /usr/bin/podkop-sub /usr/bin/podkop /usr/bin/curl \
        /etc/init.d/podkop /etc/init.d/podkop-sub
    at "${1:-main-1-out}"
    MOCK_DEAD=''
    MOCK_TCP_DEAD=''
    MOCK_TCP_SILENT=''
    unset MOCK_DELAY MOCK_PODKOP_DOWN MOCK_BODY_plain MOCK_BODY_alt MOCK_HTTP_CODE
    podkop-sub update --all > /dev/null 2>&1
    podkop-sub apply > /dev/null 2>&1
    : > "$MOCK_CALLS"
    : > "$LOG"
}

at() { printf '{"proxies":{"main-out":{"now":"%s"},"media-out":{}}}\n' "$1" > "$MOCK_PROXIES"; }
now_at() { jq -r '.proxies["main-out"].now' "$MOCK_PROXIES"; }
pings() { grep -c get_proxy_latency "$MOCK_CALLS"; }
# a subscription fetch is named after the URL's last element; a reachability probe says "probe"
fetches() { grep -c '^curl \(plain\|alt\) ' "$MOCK_CALLS"; }
probes() { grep -c '^curl probe ' "$MOCK_CALLS"; }
sec() { jq -r --arg k "$2" ".sections.$1[\$k] // \"\"" "$STATE"; }
st() { podkop-sub status 2> /dev/null | jq -r --arg s "$1" --arg k "$2" '.sections[] | select(.name == $s) | .[$k]'; }
links_of() { for l in $(uci -q get "podkop.$1.selector_proxy_links"); do echo "$l"; done; }

# ---------------------------------------------------------------- the node that carries traffic

reset main-3-out
# apply stamps this only when it really commits, so it is where a stray restart would show
applied=$(sec main applied)
podkop-sub check > /dev/null 2>&1
assert_eq "0" "$?" "check exits 0"
assert_eq "2" "$(pings)" "a live section costs exactly one ping"
assert_cmd "the node the selector points at is the one probed" \
    grep -qF 'get_proxy_latency main-3-out 2000' "$MOCK_CALLS"
assert_cmd "the probe is in the log with the node name and the latency" \
    grep -qF "main: $DE answered in 42 ms" "$LOG"
assert_eq "" "$(grep set_group_proxy "$MOCK_CALLS")" "a live section moves no selector"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" "a live section does not restart podkop"
assert_eq "0" "$(fetches)" "a pass where every section answers fetches no subscription"
assert_eq "$applied" "$(sec main applied)" "and commits nothing to podkop"
assert_eq "" "$(uci changes podkop)" "leaving no uncommitted change behind either"
assert_eq "ok ok" "$(jq -r '[.sections[].status] | join(" ")' "$STATE")" "both sections stay ok"
assert_eq "true" "$(jq '[.sections[].checked] | all(. > 0)' "$STATE")" \
    "check stamps the time on every section"
assert_eq "$DE" "$(sec main selected)" "the node it points at is remembered as the user's pick"

# ---------------------------------------------------------------- failover, and coming back

reset main-3-out
MOCK_DEAD='main-3-out'
export MOCK_DEAD
podkop-sub check > /dev/null 2>&1
assert_eq "3" "$(grep -c 'get_proxy_latency main-' "$MOCK_CALLS")" \
    "the dead node is tried, then the next one in list order, then the dead one for the fresh list"
assert_cmd "the failure is logged with the node name" grep -qF "main: $DE did not answer" "$LOG"
assert_cmd "so is the node that answered" grep -qF "main: $NL answered in" "$LOG"
assert_cmd "and so is the switch" grep -qF "main: switched to $NL" "$LOG"
assert_cmd "the selector really was moved" \
    grep -qF 'set_group_proxy main-out main-1-out' "$MOCK_CALLS"
assert_eq "main-1-out" "$(now_at)" "podkop now points at the working node"
assert_eq "$NL" "$(sec main failover)" "the emergency pick is recorded as ours"
assert_eq "$DE" "$(sec main selected)" "the user's own pick is left untouched"
assert_eq "ok" "$(sec main status)" "a section that failed over is ok, not failed"
assert_eq "2" "$(fetches)" "his node dying re-reads the subscriptions feeding the section"
assert_cmd "even a link the subscription did not change is probed, the server may be back" \
    grep -qF 'curl probe node3.example.net:443' "$MOCK_CALLS"
assert_cmd "an open port is not enough while podkop still cannot get through" \
    grep -qF "main: $DE is reachable, but podkop still cannot get through it" "$LOG"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" \
    "an unchanged list leaves podkop running on the reserve"

# our own pick must not be adopted as his by a later pass
: > "$MOCK_CALLS"
podkop-sub check > /dev/null 2>&1
assert_eq "$DE" "$(sec main selected)" "a second pass still does not adopt our pick as his"
assert_cmd "the user's pick is probed first while we hold the selector" \
    grep -qF 'get_proxy_latency main-3-out 2000' "$MOCK_CALLS"
assert_eq "get_proxy_latency main-3-out|get_proxy_latency main-1-out|" \
    "$(grep -o 'get_proxy_latency main-[0-9]*-out' "$MOCK_CALLS" | head -n 2 | tr '\n' '|')" \
    "the reserve carrying the traffic is probed right after his pick"
assert_eq "" "$(grep set_group_proxy "$MOCK_CALLS")" \
    "a live reserve is kept, never traded for another live node"
assert_eq "$NL" "$(sec main failover)" "so the failover stays where it was"

# only a reserve that died too sends the probe on to the other nodes
MOCK_DEAD='main-3-out main-1-out'
podkop-sub check > /dev/null 2>&1
assert_eq "main-2-out" "$(now_at)" "a dead reserve is replaced by the next node that answers"
assert_eq "$N2" "$(sec main failover)" "which becomes the reserve"
MOCK_DEAD='main-3-out'

# his node answers again
MOCK_DEAD=''
: > "$MOCK_CALLS"
: > "$LOG"
podkop-sub check > /dev/null 2>&1
assert_eq "1" "$(grep -c 'get_proxy_latency main-' "$MOCK_CALLS")" \
    "the recovery costs one ping: his own pick is probed first"
assert_cmd "the recovery is logged" grep -qF "main: $DE answers again" "$LOG"
assert_eq "main-3-out" "$(now_at)" "the selector is back where the user left it"
assert_eq "" "$(sec main failover)" "and we no longer claim the selector"

# the selector moved behind our back - podkop's own dashboard, a restart - so the failover is over
MOCK_DEAD='main-3-out'
podkop-sub check > /dev/null 2>&1
assert_eq "$NL" "$(sec main failover)" "we hold the selector again"
MOCK_DEAD=''
at main-3-out
: > "$MOCK_CALLS"
: > "$LOG"
podkop-sub check > /dev/null 2>&1
assert_eq "" "$(grep set_group_proxy "$MOCK_CALLS")" "a selector already back in place is not moved"
assert_cmd "the state is told the selector left our node" \
    grep -qF "main: the selector left $NL, that failover is over" "$LOG"
assert_eq "" "$(sec main failover)" "so the failover is dropped before anything is probed"
assert_eq "ok" "$(st main health)" "and the page stops being warned about it"

# a selector parked on a node that is not ours and not his clears the failover just the same
MOCK_DEAD='main-3-out'
podkop-sub check > /dev/null 2>&1
assert_eq "$NL" "$(sec main failover)" "a failover to set up the next case"
at main-2-out
MOCK_DEAD='main-3-out main-2-out'
: > "$LOG"
podkop-sub check > /dev/null 2>&1
assert_cmd "a third node under the selector ends the failover too" \
    grep -qF "main: the selector left $NL, that failover is over" "$LOG"
assert_contains "$(grep answer "$LOG" | head -n 1)" "$N2_LOG" \
    "with the failover gone, the node the selector really sits on is probed first"
# moving the selector by hand is how the user changes his mind, so that node becomes his pick
assert_eq "$N2" "$(sec main selected)" "a node the user parked the selector on becomes his pick"
MOCK_DEAD=''

# ---------------------------------------------------------------- every chosen node dead

# the user picks one node per subscription, so the rest of the list is his to borrow from
reset main-1-out
uci add_list "podkop-sub.@subscription[0].nodes=$NL"
uci add_list "podkop-sub.@subscription[1].nodes=$SG"
uci commit podkop-sub
podkop-sub update --all > /dev/null 2>&1
podkop-sub apply > /dev/null 2>&1
assert_eq "2" "$(links_of main | wc -l | tr -d ' ')" "main carries only the two chosen nodes"
assert_eq "" "$(sec main selected)" "his own apply leaves nothing remembered behind it"

: > "$MOCK_CALLS"
: > "$LOG"
MOCK_DEAD='main-1-out main-2-out media-1-out'
# the first node the subscription offers is unreachable, the next one answers
MOCK_TCP_DEAD='node2.example.net:8388'
podkop-sub check > /dev/null 2>&1
assert_cmd "a candidate that does not answer the probe is named and skipped" \
    grep -qF "main: $N2_LOG is not reachable, skipping it" "$LOG"
assert_cmd "the next one is the node that gets borrowed" \
    grep -qF "main: every node is dead, borrowing $DE from the subscription" "$LOG"
assert_eq "$DE" "$(sec main added)" "state.json records which node is ours, not his"
assert_eq "2" "$(grep -c '^curl probe node[23]\.' "$MOCK_CALLS")" \
    "the scan stops at the first candidate that answers"
assert_eq "" "$(grep 'curl probe node7' "$MOCK_CALLS")" "the candidates behind it are never probed"
assert_eq "1" "$(grep -c 'podkop-init restart' "$MOCK_CALLS")" \
    "borrowing a node restarts podkop exactly once"
assert_eq "3" "$(links_of main | wc -l | tr -d ' ')" "exactly one node was added to the section"
assert_eq "$NL" "$(sec main selected)" "adding it does not touch the user's own selection"
assert_eq "main-3-out" "$(now_at)" "the selector was pointed at the borrowed node"
assert_eq "$DE" "$(sec main failover)" "the borrowed node is recorded as ours"
assert_eq "ok" "$(sec main status)" "a section running on a borrowed node is ok"
assert_eq "added" "$(st main health)" "status tells the page a node was borrowed"
assert_eq "$DE" "$(st main added)" "and names it"
assert_eq "1" "$(grep -c 'every node is dead, borrowing' "$LOG")" \
    "only one section borrows a node in a pass"
assert_eq "fail" "$(sec media status)" "the other dead section waits for the next pass"
assert_eq "" "$(grep -F "$N2" "$LOG")" "a skipped candidate's address is masked in the log too"

# ---------------------------------------------------------------- and giving it back

: > "$MOCK_CALLS"
: > "$LOG"
MOCK_DEAD=''
MOCK_TCP_DEAD=''
podkop-sub check > /dev/null 2>&1
assert_cmd "the borrowed node is dropped by name" grep -qF "main: $DE is not needed any more" "$LOG"
assert_eq "" "$(sec main added)" "state.json no longer claims a borrowed node"
assert_eq "2" "$(links_of main | wc -l | tr -d ' ')" "the section is back to his selection alone"
assert_eq "" "$(links_of main | grep -c node3 | grep -v '^0$')" "the borrowed link is gone from uci"
assert_eq "main-1-out" "$(now_at)" "the selector is back on his own node"
assert_eq "" "$(sec main failover)" "and nothing is held on our behalf any more"
assert_eq "ok" "$(st main health)" "and the page is told the section is normal again"

# ------------------------------------------------- nothing the subscription offers answers either

: > "$MOCK_CALLS"
: > "$LOG"
MOCK_DEAD='main-1-out main-2-out media-1-out'
MOCK_TCP_DEAD='node2.example.net:8388 node3.example.net:443'
podkop-sub check > /dev/null 2>&1
assert_eq "2" "$(grep -c "main: .* is not reachable, skipping it" "$LOG")" \
    "both TCP candidates are probed and skipped"
assert_cmd "a UDP node is skipped as unprobeable, not reported dead" \
    grep -qF "main: $FI cannot be probed, skipping it" "$LOG"
assert_cmd "and the section is left alone" \
    grep -qF "main: the subscription offers nothing else" "$LOG"
assert_eq "" "$(sec main added)" "nothing is borrowed when no candidate answers"
assert_eq "2" "$(links_of main | wc -l | tr -d ' ')" "so podkop's section is untouched"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" "and podkop is not restarted"
assert_eq "fail" "$(sec main status)" "the section is reported as dead"
MOCK_TCP_DEAD=''

# ---------------------------------------------------------------- the user's choice is kept

reset main-1-out
MOCK_DEAD='main-2-out main-3-out'
before=$(uci -q get podkop.main.selector_proxy_links)
podkop-sub check > /dev/null 2>&1
assert_eq "$before" "$(uci -q get podkop.main.selector_proxy_links)" \
    "dead nodes are not pruned while a chosen one still works"

# ---------------------------------------------------------------- a dead section, same content

reset main-1-out
uci set podkop-sub.settings.max_failures=2
uci commit podkop-sub
MOCK_DELAY=fail
export MOCK_DELAY
podkop-sub check > /dev/null 2>&1
assert_eq "0" "$?" "check exits 0 with every node down"
assert_eq "8" "$(pings)" "max_failures caps the nodes a pass tries, each asked once more for the fresh list"
assert_eq "2" "$(fetches)" "each subscription is re-read once a pass, however many sections it feeds"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" \
    "an unchanged subscription does not restart podkop"
assert_eq "fail fail" "$(jq -r '[.sections[].status] | join(" ")' "$STATE")" \
    "a dead section is recorded as fail"
assert_eq "2 2" "$(jq -r '[.sections[].fails] | join(" ")' "$STATE")" \
    "state.json keeps the failure count of the pass"
assert_eq "" "$(sec main added)" "a section that was not fully probed borrows nothing"
assert_eq "selector" "$(uci -q get podkop.main.proxy_config_type)" "podkop is left alone"

# ---------------------------------------------------------------- a dead section, new content

reset main-1-out
before=$(uci -q get podkop.main.selector_proxy_links)
MOCK_DELAY=fail
MOCK_BODY_plain=moved
export MOCK_DELAY MOCK_BODY_plain
podkop-sub check > /dev/null 2>&1
assert_eq "0" "$?" "check exits 0 when the content changed under it"
assert_cmd "a dead section says why it re-reads its subscriptions" \
    grep -qF "main: re-reading its subscriptions, podkop stays as it is" "$LOG"
assert_cmd "and which node got a fresh link that answers" \
    grep -qF "main: $DE answers with the fresh link, applying it" "$LOG"
assert_eq "12" "$(grep -c 'get_proxy_latency main-' "$MOCK_CALLS")" \
    "every link is tried, the unchanged ones before DE once more, then every link of the new list"
assert_contains "$(cat "$MOCK_CALLS")" "podkop-init restart" \
    "changed subscription content is applied and podkop restarted"
assert_cmd "the section's links actually changed" \
    test "$before" != "$(uci -q get podkop.main.selector_proxy_links)"
assert_cmd "with nothing left to borrow, the section is left alone" \
    grep -q 'the subscription offers nothing else' "$LOG"
assert_eq "fail" "$(sec main status)" "a section whose every node is dead is fail"

# ------------------------------------------------ his node moved while a reserve still answers

# DE moved: the reserve takes the traffic, podkop restarts only once the new link answers
reset main-3-out
MOCK_DEAD='main-3-out'
MOCK_BODY_plain=moved
MOCK_TCP_DEAD='node9.example.net:443'
export MOCK_DEAD MOCK_BODY_plain MOCK_TCP_DEAD
podkop-sub check > /dev/null 2>&1
assert_eq "main-1-out" "$(now_at)" "the traffic moves to the first node that answers"
assert_cmd "his node's new link is probed without podkop" \
    grep -qF 'curl probe node9.example.net:443' "$MOCK_CALLS"
assert_cmd "a fresh link that does not answer either is logged" \
    grep -qF "main: $DE is not reachable by TCP either" "$LOG"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" "and costs no podkop restart"
assert_eq "$NL" "$(sec main failover)" "the section waits on the reserve for the next pass"

MOCK_TCP_DEAD=''
: > "$MOCK_CALLS"
: > "$LOG"
podkop-sub check > /dev/null 2>&1
assert_eq "main: $DE did not answer|main: re-reading its subscriptions, podkop stays as it is|main: $DE answers with the fresh link, applying it|main: $DE answered in 42 ms|main: $DE answers again, the selector is back on it|" \
    "$(grep -F -e "main: $DE" -e 'main: re-reading' "$LOG" | cut -d' ' -f3- | tr '\n' '|')" \
    "once the new link answers, podkop gets it and the selector comes back to his node"
assert_eq "1" "$(grep -c 'podkop-init restart' "$MOCK_CALLS")" \
    "podkop restarts exactly once, for the link that answered"
assert_eq "main-1-out" "$(now_at)" "the selector is on his node at its new place"
assert_eq "" "$(sec main failover)" "and the reserve is let go"

: > "$MOCK_CALLS"
podkop-sub check > /dev/null 2>&1
assert_eq "0" "$(fetches)" "with his node back, the next pass fetches nothing"
unset MOCK_BODY_plain
MOCK_DEAD=''

# ---------------------------------------------------------------- the same link, and it is back

# the server came back mid-pass under the link podkop already has: podkop is asked, nothing applied
reset main-3-out
MOCK_DEAD_ONCE='main-3-out'
export MOCK_DEAD_ONCE
podkop-sub check > /dev/null 2>&1
assert_cmd "the unchanged link is probed without podkop first" \
    grep -qF 'curl probe node3.example.net:443' "$MOCK_CALLS"
assert_cmd "then podkop confirms the server is back" \
    grep -qF "main: $DE is reachable again, podkop gets through" "$LOG"
assert_eq "main-3-out" "$(now_at)" "the selector returns from the reserve to his node"
assert_eq "" "$(sec main failover)" "and the reserve is let go"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" "without an apply or a restart"
unset MOCK_DEAD_ONCE

# ---------------------------------------------------------------- a dead section, a new UDP link

# hy2 cannot be probed over TCP, but a dead section has nothing to lose
reset main-1-out
MOCK_DELAY=fail
MOCK_BODY_alt=moved-alt
export MOCK_DELAY MOCK_BODY_alt
podkop-sub check > /dev/null 2>&1
assert_cmd "a dead section takes a new link it cannot probe" \
    grep -qF "main: $FI has a new link that cannot be probed, applying it" "$LOG"
assert_contains "$(uci -q get podkop.main.selector_proxy_links)" "node17.example.net" \
    "so the moved UDP node reaches podkop"
unset MOCK_DELAY MOCK_BODY_alt

# ---------------------------------------------------------------- his node is never borrowed

# his own node under a new link is still his, not a candidate to borrow
reset main-1-out
MOCK_DELAY=fail
MOCK_BODY_plain=moved
MOCK_TCP_DEAD='node9.example.net:443'
export MOCK_DELAY MOCK_BODY_plain MOCK_TCP_DEAD
podkop-sub check > /dev/null 2>&1
assert_cmd "his moved node that does not answer stays out of the section" \
    grep -qF "main: the subscription offers nothing else" "$LOG"
assert_eq "" "$(grep -F "$DE is not reachable, skipping it" "$LOG")" \
    "and is never looked at as a node to borrow"
unset MOCK_DELAY MOCK_BODY_plain
MOCK_TCP_DEAD=''

# ---------------------------------------------------------------- a urltest section routes itself

# one live node is enough for urltest: no fetch, no restart
reset main-1-out
uci set podkop-sub.main.mode=urltest
uci commit podkop-sub
podkop-sub apply > /dev/null 2>&1
: > "$MOCK_CALLS"
MOCK_DEAD='main-1-out main-2-out main-3-out main-4-out'
podkop-sub check > /dev/null 2>&1
assert_eq "0" "$(fetches)" "a urltest section with a live node fetches nothing"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" "and restarts nothing"
MOCK_DEAD=''

# ------------------------------------------- the dead section's own subscriptions, and no others

reset main-1-out
MOCK_DEAD='media-1-out media-2-out media-3-out'
podkop-sub check > /dev/null 2>&1
assert_eq "1" "$(grep -c '^curl plain ' "$MOCK_CALLS")" \
    "the subscription feeding the dead section is re-read"
assert_eq "" "$(grep '^curl alt ' "$MOCK_CALLS")" \
    "the one that does not feed it is left alone"
assert_eq "ok" "$(sec main status)" "the section that answered was never fetched for"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" \
    "and an unchanged list restarts nothing"
MOCK_DEAD=''

# ---------------------------------------------------------------- a failed update does not abort

reset main-1-out
before=$(uci -q get podkop.main.selector_proxy_links)
MOCK_DELAY=fail
MOCK_HTTP_CODE=502
export MOCK_DELAY MOCK_HTTP_CODE
podkop-sub check > /dev/null 2>&1
assert_eq "0" "$?" "check exits 0 when every subscription fails to download"
assert_cmd "the download failure is logged" grep -q 'http 502' "$LOG"
assert_eq "9" "$(grep -c 'get_proxy_latency main-' "$MOCK_CALLS")" \
    "a failed fetch leaves the old links: podkop is asked once more only for those TCP answers"
assert_eq "$before" "$(uci -q get podkop.main.selector_proxy_links)" \
    "podkop keeps the list it is running on"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" "and is not restarted"
assert_eq "fail" "$(sec main status)" "the section is judged on its probes, not on the fetch"
unset MOCK_DELAY MOCK_HTTP_CODE

# ---------------------------------------------------------------- a name that comes back

reset main-1-out
uci add_list "podkop-sub.@subscription[0].nodes=$DE"
uci commit podkop-sub
MOCK_BODY_plain=alt
export MOCK_BODY_plain
podkop-sub update --all > /dev/null 2>&1
assert_eq "$DE" "$(jq -r '[.subs[].missing[]?] | join("")' "$STATE")" \
    "the provider dropped a chosen node"
unset MOCK_BODY_plain
: > "$LOG"
# the name comes back with the fetch, and only a section whose node died fetches
MOCK_DELAY=fail
export MOCK_DELAY
podkop-sub check > /dev/null 2>&1
assert_cmd "the returning name is logged" grep -qF "$DE is back" "$LOG"
assert_eq "" "$(jq -r '[.subs[].missing[]?] | join("")' "$STATE")" "and it is no longer missing"
unset MOCK_DELAY

# ---------------------------------------------------------------- a section podkop no longer has

reset main-1-out
uci delete podkop.media
uci commit podkop
podkop-sub check > /dev/null 2>&1
assert_eq "0" "$?" "check exits 0 with a section deleted from podkop"
assert_eq "false" "$(jq '.sections | has("media")' "$STATE")" "the deleted section is forgotten"
assert_cmd "the deleted section leaves no backup" test ! -e /etc/podkop-sub/backup/media.uci
assert_eq "1" "$(pings)" "only the section that still exists is pinged"

# ---------------------------------------------------------------- podkop not running

reset main-1-out
MOCK_PODKOP_DOWN=1
export MOCK_PODKOP_DOWN
out=$(podkop-sub check 2>&1)
assert_eq "0" "$?" "check exits 0 when podkop is not running"
assert_contains "$out" "podkop is not answering" "check says why it did nothing"
assert_eq "0" "$(pings)" "nothing is pinged when podkop is not running"
assert_eq "" "$(grep '^curl' "$MOCK_CALLS")" "nothing is downloaded when podkop is not running"

# ---------------------------------------------------------------- what the banner is told

reset main-3-out
podkop-sub check > /dev/null 2>&1
assert_eq "ok" "$(st main health)" "a healthy section gives the page nothing to warn about"

MOCK_DEAD='main-3-out'
export MOCK_DEAD
podkop-sub check > /dev/null 2>&1
assert_eq "failover" "$(st main health)" "a failover is reported as its own state"
assert_eq "$DE" "$(st main selected)" "the page can name the node the user picked"
assert_eq "$NL" "$(st main failover)" "and the one his traffic really goes through"

podkop-sub ack-section main
assert_eq "failover" "$(sec main health_ack)" "the ack records which state was silenced"
assert_eq "ok" "$(st main health)" "a dismissed warning is still dismissed on the next read"
podkop-sub check > /dev/null 2>&1
assert_eq "ok" "$(st main health)" "and after another pass in the same state"

# a dismissal must never hide a different problem
MOCK_DEAD='main-1-out main-2-out main-3-out main-4-out main-5-out'
podkop-sub check > /dev/null 2>&1
assert_eq "fail" "$(st main health)" "a section that then loses every node warns again"
assert_eq "failover" "$(sec main health_ack)" "without the old ack being rewritten"

MOCK_DEAD=''
podkop-sub check > /dev/null 2>&1
assert_eq "ok" "$(st main health)" "the recovered section is normal again"
assert_eq "" "$(sec main health_ack)" "and the core dropped the ack when it recovered"

MOCK_DEAD='main-3-out'
podkop-sub check > /dev/null 2>&1
assert_eq "failover" "$(st main health)" "so the next failover warns instead of staying silent"
MOCK_DEAD=''

# ---------------------------------------------------------------- the service fields of status

reset main-1-out
podkop-sub status > /tmp/status-check.json 2> /dev/null
assert_cmd "status is valid JSON with the real service fields" jq -e . /tmp/status-check.json
assert_eq "false" "$(jq -r '.service.running' /tmp/status-check.json)" \
    "the service is not running in the stand"
assert_eq "false" "$(jq -r '.service.enabled' /tmp/status-check.json)" \
    "the service is not enabled in the stand"

# ---------------------------------------------------------------- the daemon answers TERM

reset main-1-out
rm -f /tmp/daemon.log
podkop-sub daemon > /tmp/daemon.log 2>&1 &
daemon_pid=$!
sleep 1
kill -TERM "$daemon_pid" 2> /dev/null
waited=0
while [ "$waited" -lt 8 ] && ! grep -q "daemon stopped" /tmp/daemon.log; do
    sleep 1
    waited=$((waited + 1))
done
wait "$daemon_pid" 2> /dev/null
assert_cmd "the daemon exits on TERM" grep -q "daemon stopped" /tmp/daemon.log
assert_cmd "it exits at once, not after the initial 60 s wait" test "$waited" -lt 5
assert_eq "0" "$(pings)" "a daemon stopped during its first wait never reached a check"

# ---------------------------------------------------------------- a socket that connects, then waits

# a VLESS endpoint accepts the connection and says nothing, so curl gives up with 28 even though the
# handshake succeeded: the probe reads time_connect, never the exit code
# the same ground as the borrow scenario: the section carries only the two nodes he chose
reset main-1-out
uci add_list "podkop-sub.@subscription[0].nodes=$NL"
uci add_list "podkop-sub.@subscription[1].nodes=$SG"
uci commit podkop-sub
podkop-sub update --all > /dev/null 2>&1
podkop-sub apply > /dev/null 2>&1
: > "$MOCK_CALLS"
: > "$LOG"
MOCK_DEAD='main-1-out main-2-out media-1-out'
MOCK_TCP_SILENT='node2.example.net:8388'
podkop-sub check > /dev/null 2>&1
assert_eq "" "$(grep -F 'is not reachable' "$LOG")" \
    "a socket that connects and then stays silent is never called unreachable"
assert_cmd "it is borrowed like any other live node" \
    grep -qF "main: every node is dead, borrowing $N2_LOG from the subscription" "$LOG"
assert_eq "$N2" "$(sec main added)" "and it is the node that ends up in the section"

# his pick is still dead, but his other node wins over the borrowed reserve
MOCK_DEAD='main-1-out'
MOCK_TCP_SILENT=''
: > "$MOCK_CALLS"
podkop-sub check > /dev/null 2>&1
assert_eq "" "$(sec main added)" "any of his own nodes answering drops the borrowed one"
assert_eq "$SG" "$(sec main failover)" "and carries the traffic until his pick is back"
assert_eq "1" "$(grep -c 'podkop-init restart' "$MOCK_CALLS")" \
    "dropping it is the only podkop restart of the pass"
MOCK_DEAD=''

# ------------------------------------------------- the pick the user dropped from his node list

# he failed over to NL, then deselected DE entirely: a save & apply is him redoing his choice,
# so nothing of the old one survives it and the next pass adopts whatever runs now
reset main-3-out
MOCK_DEAD='main-3-out'
podkop-sub check > /dev/null 2>&1
assert_eq "$DE" "$(sec main selected)" "the failover starts from his pick"
assert_eq "$NL" "$(sec main failover)" "with our own node carrying the traffic"

uci add_list "podkop-sub.@subscription[0].nodes=$NL"
uci add_list "podkop-sub.@subscription[0].nodes=$N2"
uci commit podkop-sub
podkop-sub update --all > /dev/null 2>&1
: > "$MOCK_CALLS"
podkop-sub apply > /dev/null 2>&1
assert_eq "" "$(grep -F 'set_group_proxy main-out main-3-out' "$MOCK_CALLS")" \
    "his apply never puts the selector back on the pick that died"
assert_eq "" "$(sec main selected)" "a save & apply forgets the pick he had"
assert_eq "" "$(sec main failover)" "and the failover that was standing in for it"

MOCK_DEAD=''
podkop-sub check > /dev/null 2>&1
assert_eq "$NL" "$(sec main selected)" "the next pass takes the node that runs now as his pick"
assert_eq "ok" "$(st main health)" "so the page stops warning about a node he removed himself"
assert_eq "" "$(sec media selected)" "a urltest section keeps no pick at all, it picks the fastest"

# the subscription dropping a node leaves the same dangling pick, without an apply to clear it
jq '.sections.main.selected = "a node that left"' "$STATE" > /tmp/state.new && mv /tmp/state.new "$STATE"
: > "$LOG"
podkop-sub check > /dev/null 2>&1
assert_cmd "a pick the section no longer carries is forgotten on the spot" \
    grep -qF "main: a node that left is not in this section any more, forgetting it" "$LOG"
assert_eq "$NL" "$(sec main selected)" "and the node under the selector takes its place"

test_summary
