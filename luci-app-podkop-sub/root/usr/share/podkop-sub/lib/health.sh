# shellcheck shell=dash
# shellcheck disable=SC3043 # busybox ash has `local`; podkop's own script relies on it
# shellcheck disable=SC2016 # single-quoted jq filters use jq's own $vars, not the shell's
# podkop-sub: keeping the traffic on a node that answers

# <count> <index to try last> <indexes to try first...> - every index once, 0 meaning none
probe_order() {
    local n="$1" last="$2" i
    shift 2
    for i in "$@"; do
        [ "$i" -ge 1 ] && [ "$i" -le "$n" ] && [ "$i" != "$last" ] && printf '%s ' "$i"
    done
    i=1
    while [ "$i" -le "$n" ]; do
        case " $* $last " in *" $i "*) ;; *) printf '%s ' "$i" ;; esac
        i=$((i + 1))
    done
    [ "$last" -ge 1 ] && [ "$last" -le "$n" ] && printf '%s ' "$last"
    return 0
}

# <section> <links file> <timeout> <max failures> <index...> - sets PROBE_WIN and PROBE_TRIED
probe_indexes() {
    local s="$1" f="$2" to="$3" maxf="$4" i name
    shift 4
    PROBE_WIN=0
    PROBE_TRIED=0
    for i in "$@"; do
        name=$(link_name "$(sed -n "${i}p" "$f")")
        PROBE_TRIED=$((PROBE_TRIED + 1))
        if ping_node "$s" "$i" "$to"; then
            log "$s: $(safe_name "$name") answered in $PING_MS ms"
            PROBE_WIN=$i
            return 0
        fi
        log "$s: $(safe_name "$name") did not answer"
        [ "$PROBE_TRIED" -lt "$maxf" ] || break
    done
    return 1
}

mark_section() {
    state_apply --arg s "$1" --arg st "$2" --argjson f "$3" --argjson t "$(date +%s)" \
        '.sections[$s] = ((.sections[$s] // {}) + {status: $st, fails: $f, checked: $t})
         | if (.sections[$s] | '"$HEALTH"') == "ok" then del(.sections[$s].health_ack) else . end'
}

# <link> - is there a TCP socket at the endpoint? 2 when the link cannot be probed.
# curl's exit code cannot answer this: a server that accepts the connection and then stays silent
# times out with 28, exactly like one that was never reachable. time_connect separates them - it is
# zero only when the handshake itself never completed. A silent socket is what a VLESS endpoint
# looks like when curl speaks MQTT at it, so this is the common case, not an edge one.
tcp_up() {
    local hp t secs
    # hy2/hysteria2 are UDP: there is nothing to connect to, and "cannot tell" is not "dead"
    case "$1" in hy2://* | hysteria2://*) return 2 ;; esac
    hp=$(link_hostport "$1")
    case "$hp" in *:*) ;; *) return 2 ;; esac
    secs=$((($(setting ping_timeout 2000) + 999) / 1000))
    [ "$secs" -ge 1 ] || secs=1
    # mqtt:// is the cheapest plain-TCP scheme this curl has: telnet:// is not compiled in
    t=$(curl -sk -o /dev/null -w '%{time_connect}' \
        --connect-timeout "$secs" --max-time "$((secs + 1))" "mqtt://$hp" 2> /dev/null)
    # any non-zero digit means the connect completed, whatever separator the build prints
    case "$(printf '%s' "$t" | tr -dc '0-9')" in
        *[1-9]*) return 0 ;;
    esac
    return 1
}

# the first node the section's subscriptions offer that it does not carry and that TCP answers
emergency_link() {
    local s="$1" f="$2" id l
    for id in $(section_subs "$s"); do
        [ -s "$CACHE_DIR/$id.lst" ] || continue
        while IFS= read -r l; do
            # by name: a fresh cache may hold his own nodes under new links
            [ "$(link_index "$f" "$(link_name "$l")")" -gt 0 ] && continue
            tcp_up "$l"
            case "$?" in
                0)
                    printf '%s\n' "$l"
                    return 0
                    ;;
                # our stdout is the link the caller captures, so these lines go to stderr
                2) log "$s: $(safe_name "$(link_name "$l")") cannot be probed, skipping it" >&2 ;;
                *) log "$s: $(safe_name "$(link_name "$l")") is not reachable, skipping it" >&2 ;;
            esac
        done < "$CACHE_DIR/$id.lst"
    done
    return 1
}

# every chosen node is dead: borrow one the user did not pick, and let apply write it in
add_emergency() {
    local s="$1" f="$2" link name
    link=$(emergency_link "$s" "$f")
    [ -n "$link" ] || {
        log "$s: the subscription offers nothing else, leaving the section as it is"
        return 1
    }
    name=$(link_name "$link")
    log "$s: every node is dead, borrowing $(safe_name "$name") from the subscription"
    state_apply --arg s "$s" --arg n "$name" --arg l "$link" \
        '.sections[$s] = ((.sections[$s] // {}) + {added: $n, added_link: $l})' || return 1
    # a uci commit and a podkop restart: once per check pass, never in a loop
    CHECK_ADDED=1
    cmd_apply
    wait_for_group "$s" "$RESTORE_WAIT"
}

# a chosen node answers again: the section goes back to the user's selection alone
drop_emergency() {
    local s="$1" name="$2"
    log "$s: $(safe_name "$name") is not needed any more, dropping it from the section"
    state_apply --arg s "$s" 'del(.sections[$s].added, .sections[$s].added_link)' || return 1
    cmd_apply
    wait_for_group "$s" "$RESTORE_WAIT"
}

# <section> <its links> <dead links> [<nothing else answers>] - 0 when a fresh fetch revives one
fresh_node() {
    local s="$1" f="$2" fresh="$CHECKTMP/fresh.$1" id old name i new hit=''
    [ -s "$3" ] || return 1
    log "$s: re-reading its subscriptions, podkop stays as it is"
    for id in $(section_subs "$s"); do
        # once a pass per subscription, however many sections it feeds
        [ -e "$CHECKTMP/fetched.$id" ] && continue
        : > "$CHECKTMP/fetched.$id"
        cmd_update "$id"
    done
    for id in $(section_subs "$s"); do cat "$CACHE_DIR/$id.lst" 2> /dev/null; done > "$fresh"
    while IFS= read -r old; do
        name=$(link_name "$old")
        i=$(link_index "$fresh" "$name")
        [ "$i" -gt 0 ] || continue
        new=$(sed -n "${i}p" "$fresh")
        tcp_up "$new"
        case "$?" in
            0) ;;
            2)
                # nothing else runs, so a new link we cannot check is still worth a restart
                if [ -n "$4" ] && [ "$new" != "$old" ]; then
                    log "$s: $(safe_name "$name") has a new link that cannot be probed, applying it"
                    hit=1
                    break
                fi
                log "$s: $(safe_name "$name") cannot be probed, leaving it"
                continue
                ;;
            *)
                log "$s: $(safe_name "$name") is not reachable by TCP either"
                continue
                ;;
        esac
        if [ "$new" != "$old" ]; then
            log "$s: $(safe_name "$name") answers with the fresh link, applying it"
            hit=1
            break
        fi
        # podkop already carries this very link, so it can tell whether the server is back
        i=$(link_index "$f" "$name")
        if ping_node "$s" "$i" "$(setting ping_timeout 2000)" < /dev/null; then
            log "$s: $(safe_name "$name") is reachable again, podkop gets through in $PING_MS ms"
            return 0
        fi
        log "$s: $(safe_name "$name") is reachable, but podkop still cannot get through it"
    done < "$3"
    [ -n "$hit" ] || return 1
    cmd_apply
    wait_for_group "$s" "$RESTORE_WAIT" || log "$s: podkop's proxy groups did not come back"
}

# probe the node that carries the traffic, fail over when it dies, come back when it revives
check_section() {
    local s="$1" to="$2" maxf="$3" again="${4:-}"
    local f n mode sel fail add add_i fail_i sel_i now order name win dead i
    if ! uci -q get "podkop.$s" > /dev/null 2>&1; then
        log "section $s is gone from podkop, dropping it"
        forget_section "$s"
        return 0
    fi
    f="$CHECKTMP/links.$s"
    current_links "$s" > "$f"
    n=$(wc -l < "$f" | tr -d ' ')
    if [ "$n" -eq 0 ]; then
        log "$s: podkop has no links for this section"
        mark_section "$s" fail 0
        return 0
    fi
    # a pick that is no longer in the section can never answer again, so it is not a pick
    sel=$(sec_state "$s" selected)
    if [ -n "$sel" ] && [ "$(link_index "$f" "$sel")" -eq 0 ]; then
        log "$s: $(safe_name "$sel") is not in this section any more, forgetting it"
        forget_choice "$s"
    fi
    # no apply happens in a healthy pass, so this is the only place his pick is ever learned
    remember_choice "$s"
    mode=$(section_mode "$s")
    sel=$(sec_state "$s" selected)
    fail=$(sec_state "$s" failover)
    add=$(sec_state "$s" added)
    add_i=$(link_index "$f" "$add")
    fail_i=$(link_index "$f" "$fail")
    sel_i=$(link_index "$f" "$sel")
    now=0
    [ "$mode" = selector ] && now=$(selector_index "$s")
    # a failover lasts only while the selector still sits on it; anything that moved it ended it
    if [ -n "$fail" ] && [ "$fail_i" -eq 0 ]; then
        forget_failover "$s"
        fail=''
    elif [ -n "$fail" ] && [ "$now" -gt 0 ] && [ "$now" != "$fail_i" ]; then
        log "$s: the selector left $(safe_name "$fail"), that failover is over"
        forget_failover "$s"
        fail=''
        fail_i=0
    fi

    # a borrowed reserve goes last: any of his own nodes that answers wins over it
    if [ "$mode" = selector ] && [ "$fail_i" -gt 0 ] && [ "$fail_i" = "$add_i" ]; then
        order=$(probe_order "$n" "$fail_i" "$sel_i")
    # his pick first, then the reserve: trading one live reserve for another only drops connections
    elif [ "$mode" = selector ] && [ "$fail_i" -gt 0 ]; then
        order=$(probe_order "$n" 0 "$sel_i" "$fail_i")
    elif [ "$mode" != selector ] && [ "$add_i" -gt 0 ]; then
        order=$(probe_order "$n" "$add_i")
    elif [ "$mode" = selector ]; then
        order=$(probe_order "$n" 0 "$now")
    else
        # a urltest section picks for itself; there is no "current" node to start from
        i=$(awk -v n="$n" 'BEGIN { srand(); print int(rand() * n) + 1 }')
        order=$(probe_order "$n" 0 "$i")
    fi

    # shellcheck disable=SC2086 # the order is a list of indexes: word splitting is the point
    probe_indexes "$s" "$f" "$to" "$maxf" $order
    # for the fresh fetch: his first node if a reserve answered, every node tried if none did
    dead="$CHECKTMP/dead.$s"
    : > "$dead"
    # shellcheck disable=SC2086 # echo squeezes the list, so cut counts one index per field
    for i in $(echo $order | cut -d' ' -f"1-$PROBE_TRIED"); do
        [ "$i" != "$PROBE_WIN" ] || break
        # the borrowed node is not his to bring back
        [ "$i" = "$add_i" ] || sed -n "${i}p" "$f" >> "$dead"
        [ "$PROBE_WIN" = 0 ] || break
    done
    if [ "$PROBE_WIN" = 0 ]; then
        log "$s: no node answered ($PROBE_TRIED of $n tried)"
        if [ -z "$again" ] && fresh_node "$s" "$f" "$dead" 1; then
            check_section "$s" "$to" "$maxf" 1
            return 0
        fi
        if [ "$PROBE_TRIED" -ge "$n" ] && [ -z "$CHECK_ADDED" ] && add_emergency "$s" "$f"; then
            current_links "$s" > "$f"
            add=$(sec_state "$s" added)
            add_i=$(link_index "$f" "$add")
            if [ "$add_i" -gt 0 ]; then
                probe_indexes "$s" "$f" "$to" 1 "$add_i"
                [ "$mode" = selector ] && select_node "$s" "$add_i" "$add"
                if [ "$PROBE_WIN" -gt 0 ]; then
                    mark_section "$s" ok 0
                    return 0
                fi
            fi
        fi
        mark_section "$s" fail "$PROBE_TRIED"
        return 0
    fi

    win=$PROBE_WIN
    name=$(link_name "$(sed -n "${win}p" "$f")")
    # every link but the borrowed one is the user's, so a win elsewhere means his side is back
    if [ -n "$add" ] && [ "$win" != "$add_i" ]; then
        drop_emergency "$s" "$add"
        # that was this pass's restart; his node gets its fresh look on the next one
        : > "$dead"
        current_links "$s" > "$f"
        win=$(link_index "$f" "$name")
        now=0
        [ "$mode" = selector ] && now=$(selector_index "$s")
    fi
    if [ "$mode" = selector ] && [ "$win" -gt 0 ] && [ "$win" != "$now" ]; then
        if [ "$name" = "$sel" ]; then
            "$PODKOP" clash_api set_group_proxy "$s-out" "$s-$win-out" > /dev/null 2>&1 ||
                log "$s: could not switch to $(safe_name "$name")"
        else
            select_node "$s" "$win" "$name"
        fi
    fi
    # the recovery is reported where the failover is dropped, not where the selector is moved
    if [ "$name" = "$sel" ] && [ -n "$fail" ]; then
        log "$s: $(safe_name "$name") answers again, the selector is back on it"
        forget_failover "$s"
    fi
    mark_section "$s" ok 0
    # selector only: urltest routes around a dead node by itself
    if [ "$mode" = selector ] && [ -z "$again" ] && fresh_node "$s" "$f" "$dead"; then
        check_section "$s" "$to" "$maxf" 1
    fi
    return 0
}

cmd_check() {
    local timeout maxf s
    if ! clash_up; then
        log "podkop is not answering, skipping the check"
        return 0
    fi
    timeout=$(setting ping_timeout 2000)
    maxf=$(setting max_failures 5)
    [ "$maxf" -ge 1 ] || maxf=1
    CHECK_ADDED=''
    CHECKTMP=$(mktemp -d) || return 1
    # a pass only probes; a section whose node died re-reads its own subscriptions
    for s in $(state_json | jq -r '.sections | keys[]?'); do
        check_section "$s" "$timeout" "$maxf"
    done
    rm -rf "$CHECKTMP"
    return 0
}

DAEMON_STOP=0

# ash finishes a plain `sleep` before handling a signal, so wait on it instead
nap() {
    local pid
    [ "$DAEMON_STOP" = 0 ] || return 0
    sleep "$1" &
    pid=$!
    wait "$pid"
    kill "$pid" 2> /dev/null
    return 0
}

cmd_daemon() {
    local interval
    trap 'DAEMON_STOP=1' TERM INT
    log "daemon started"
    # let podkop and sing-box finish booting before the first check
    nap 60
    while [ "$DAEMON_STOP" = 0 ]; do
        config_load podkop-sub
        cmd_check
        [ "$DAEMON_STOP" = 0 ] || break
        interval=$(setting check_interval 60)
        [ "$interval" -ge 1 ] || interval=60
        nap $((interval * 60))
    done
    log "daemon stopped"
    return 0
}
