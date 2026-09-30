# shellcheck shell=dash
# shellcheck disable=SC3043 # busybox ash has `local`; podkop's own script relies on it
# shellcheck disable=SC2016 # single-quoted jq filters use jq's own $vars, not the shell's
# podkop-sub: subscriptions into podkop's sections - fetch, apply, roll back

DEFAULT_UA='v2rayNG/1.9.0'

sub_error() {
    # masked here, not at the call sites: an error path must not be the one that leaks the endpoint
    log "$1 ($(mask_host "$2")): $3"
    state_apply --arg id "$1" --arg url "$4" --arg e "$3" \
        '.subs[$id] = ((.subs[$id] // {}) + {url: $url, status: "error", error: $e})'
}

update_one() {
    local sec="$1" target="$2" force="$3"
    local en url id ua host hdrs body dec lst count all kept skipped hash old now want miss back
    local ui up down total expire left

    config_get_bool en "$sec" enabled 1
    [ "$en" = 1 ] || return 0
    config_get url "$sec" url
    [ -n "$url" ] || return 0
    id=$(sub_id "$url")
    [ "$target" = "--all" ] || [ "$target" = "$id" ] || return 0
    UPDATE_TRIED=1

    config_get ua "$sec" user_agent "$DEFAULT_UA"
    host=${url#*://}
    host=${host%%/*}
    host=${host%%\?*}

    hdrs="$RUNTMP/$id.hdr"
    body="$RUNTMP/$id.body"
    if ! now=$(curl -sL --max-time 20 --retry 2 -A "$ua" -D "$hdrs" -o "$body" \
        -w '%{http_code}' "$url" 2> /dev/null); then
        sub_error "$id" "$host" "download failed" "$url"
        return 0
    fi
    case "$now" in
        2??) ;;
        *)
            sub_error "$id" "$host" "http ${now:-000}" "$url"
            return 0
            ;;
    esac
    [ -s "$body" ] || {
        sub_error "$id" "$host" "empty body" "$url"
        return 0
    }

    dec="$RUNTMP/$id.dec"
    lst="$RUNTMP/$id.lst"
    decode_body < "$body" > "$dec"
    parse_subscription < "$dec" > "$lst"
    count=$(wc -l < "$lst" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        sub_error "$id" "$host" "no supported links" "$url"
        return 0
    fi
    all=$(grep -c '://' "$dec")
    kept=$(filter_links < "$dec" | wc -l | tr -d ' ')
    skipped=$((all - kept))
    [ "$skipped" -ge 0 ] || skipped=0

    hash=$(sha256sum "$lst" | cut -d' ' -f1)
    old=$(state_json | jq -r --arg id "$id" '.subs[$id].hash // ""')
    if [ "$hash" = "$old" ] && [ -z "$force" ] && [ -s "$CACHE_DIR/$id.lst" ]; then
        log "$id ($(mask_host "$host")): unchanged, $count links"
    else
        mv "$lst" "$CACHE_DIR/$id.lst" || return 0
        log "$id ($(mask_host "$host")): $count links, $skipped skipped"
    fi

    # chosen names the provider no longer offers; never written back, so they survive a bad fetch
    want="$RUNTMP/$id.want"
    miss="$RUNTMP/$id.miss"
    : > "$want"
    config_list_foreach "$sec" nodes append_line "$want"
    sub_names "$id" > "$RUNTMP/$id.names"
    grep -Fxv -f "$RUNTMP/$id.names" "$want" > "$miss"
    # a name the provider had dropped and offers again is the recovery the check loop is for
    state_json | jq -r --arg id "$id" '.subs[$id].missing[]?' > "$RUNTMP/$id.was"
    while IFS= read -r back; do
        [ -n "$back" ] && ! grep -Fxq "$back" "$miss" && log "$id ($(mask_host "$host")): $(safe_name "$back") is back"
    done < "$RUNTMP/$id.was"

    ui=$(grep -i '^subscription-userinfo:' "$hdrs" 2> /dev/null | tr -d '\r' | tail -n 1)
    up=$(ui_field "$ui" upload)
    down=$(ui_field "$ui" download)
    total=$(ui_field "$ui" total)
    expire=$(ui_field "$ui" expire)
    left=$((${total:-0} - ${up:-0} - ${down:-0}))
    [ "$left" -ge 0 ] || left=0
    now=$(date +%s)

    state_apply --arg id "$id" --arg url "$url" --arg h "$hash" \
        --argjson c "$count" --argjson s "$skipped" --argjson t "$now" \
        --argjson e "${expire:-0}" --argjson l "$left" --rawfile miss "$miss" \
        '($miss | split("\n") | map(select(length > 0))) as $m |
         (($m | length) > 0 and (.subs[$id].missing_ack // false)) as $ack |
         .subs[$id] = {url: $url, hash: $h, count: $c, skipped: $s, updated: $t,
                       status: "ok", error: "", expire: $e, traffic_left: $l,
                       missing: $m, missing_ack: $ack}'
    UPDATE_OK=1
}

cmd_update() {
    local a target=--all force=''
    for a in "$@"; do
        case "$a" in
            --all) target=--all ;;
            --force) force=1 ;;
            -*)
                log "unknown option: $a"
                return 1
                ;;
            *) target=$a ;;
        esac
    done
    UPDATE_OK=0
    UPDATE_TRIED=0
    RUNTMP=$(mktemp -d) || return 1
    config_foreach update_one subscription "$target" "$force"
    rm -rf "$RUNTMP"
    [ "$UPDATE_OK" = 1 ] || [ "$UPDATE_TRIED" = 0 ]
}

cmd_ack() {
    [ -n "${1:-}" ] || return 1
    state_apply --arg id "$1" '.subs[$id] = ((.subs[$id] // {}) + {missing_ack: true})'
}

# a section's health changes on its own, so the ack records which state was silenced
cmd_ack_section() {
    [ -n "${1:-}" ] || return 1
    state_apply --arg s "$1" \
        '.sections[$s] = ((.sections[$s] // {}) + {health_ack: (.sections[$s] // {} | '"$HEALTH"')})'
}

collect_links() {
    local sec="$1" dir="$2" en url id secs s want pick
    config_get_bool en "$sec" enabled 1
    [ "$en" = 1 ] || return 0
    config_get url "$sec" url
    [ -n "$url" ] || return 0
    id=$(sub_id "$url")
    [ -s "$CACHE_DIR/$id.lst" ] || return 0
    # the only place the link list is assembled, so the only place the node choice is applied
    want="$dir/want.$id"
    pick="$dir/pick.$id"
    : > "$want"
    config_list_foreach "$sec" nodes append_line "$want"
    pick_links "$CACHE_DIR/$id.lst" "$want" > "$pick"
    config_get secs "$sec" sections
    for s in $secs; do
        cat "$pick" >> "$dir/sec.$s"
    done
}

podkop_changes_clear() {
    local changes
    changes=$(uci changes podkop) || {
        log "could not read pending podkop changes"
        return 1
    }
    [ -z "$changes" ] || {
        log "podkop has pending changes, save or revert them first"
        return 1
    }
}

snapshot_apply() {
    cp -p /etc/config/podkop "$RUNTMP/podkop" || return 1
    cp -Rp "$BACKUP_DIR" "$RUNTMP/backup" || return 1
    [ ! -e "$STATE" ] || cp -p "$STATE" "$RUNTMP/state.json"
}

rollback_apply() {
    local restart="$1" state_ok=1
    if ! uci -q revert podkop || ! cp -p "$RUNTMP/podkop" /etc/config/podkop; then
        log "could not restore podkop config; snapshot kept in $RUNTMP"
        return 1
    fi
    if ! rm -f "$BACKUP_DIR"/*.uci || ! cp -Rp "$RUNTMP/backup/." "$BACKUP_DIR/"; then
        log "could not restore section backups; snapshot kept in $RUNTMP"
        return 1
    fi
    if [ -e "$RUNTMP/state.json" ]; then
        cp -p "$RUNTMP/state.json" "$STATE" || state_ok=''
    else
        rm -f "$STATE" || state_ok=''
    fi
    if [ -z "$state_ok" ]; then
        log "could not restore plugin state; snapshot kept in $RUNTMP"
        return 1
    fi
    if [ -n "$restart" ] && ! /etc/init.d/podkop restart; then
        log "config restored but podkop restart failed; snapshot kept in $RUNTMP"
        return 1
    fi
    log "previous podkop config and plugin state restored"
    rm -rf "$RUNTMP"
}

apply_locked() {
    local force="$1" f s targets='' n pending='' extra
    podkop_changes_clear || return 1
    RUNTMP=$(mktemp -d) || return 1
    snapshot_apply || {
        log "could not snapshot podkop config and plugin state"
        rm -rf "$RUNTMP"
        return 1
    }
    config_foreach collect_links subscription "$RUNTMP"

    for f in "$RUNTMP"/sec.*; do
        [ -f "$f" ] || continue
        s=${f##*/sec.}
        # a section the user deleted is forgotten, never recreated from the backup
        if ! uci -q get "podkop.$s" > /dev/null 2>&1; then
            log "section $s is gone from podkop, dropping it"
            forget_section "$s"
            continue
        fi
        if [ -z "$(section_mode "$s")" ]; then
            log "section $s has no configuration type set, skipping it"
            continue
        fi
        # the node check borrowed while every chosen one was dead rides along until it is dropped
        extra=$(state_json | jq -r --arg s "$s" '.sections[$s].added_link // ""')
        [ -n "$extra" ] && ! grep -Fxq "$extra" "$f" && printf '%s\n' "$extra" >> "$f"
        targets="$targets $s"
        write_section "$s" "$f"
    done

    for s in $(state_json | jq -r '.sections | keys[]?'); do
        case " $targets " in *" $s "*) continue ;; esac
        if uci -q get "podkop.$s" > /dev/null 2>&1; then
            log "section $s is no longer targeted, rolling it back"
            rollback_section "$s"
        else
            log "section $s is gone from podkop, dropping it"
        fi
        forget_section "$s"
    done

    if [ -z "$(uci changes podkop)" ] && [ -z "$force" ]; then
        log "no changes"
        rm -rf "$RUNTMP"
        return 0
    fi

    uci commit podkop || {
        log "uci commit podkop failed"
        rollback_apply ''
        return 1
    }
    /etc/init.d/podkop restart || {
        log "podkop restart failed"
        rollback_apply restart
        return 1
    }
    log "podkop restarted for${targets:- none}"

    for s in $targets; do
        needs_restore "$s" && pending=1
        n=$(wc -l < "$RUNTMP/sec.$s" | tr -d ' ')
        state_apply --arg s "$s" --arg m "$(section_mode "$s")" \
            --argjson n "$n" --argjson t "$(date +%s)" \
            '.sections[$s] = ((.sections[$s] // {}) +
                              {mode: $m, links: $n, status: "ok", applied: $t})'
    done

    # his apply forgets, so only our own ever waits for sing-box behind LuCI's 20 s rpc
    if [ -z "$pending" ]; then
        rm -rf "$RUNTMP"
    else
        restore_nodes "$RUNTMP"
    fi
    return 0
}

cmd_apply() {
    local force=''
    [ "${1:-}" = "--force" ] && force=1
    (
        flock -n 9 || {
            log "another podkop-sub run holds the lock"
            exit 1
        }
        apply_locked "$force"
    ) 9> "$LOCK"
}

restore_locked() {
    local target="$1" f s
    podkop_changes_clear || return 1
    for f in "$BACKUP_DIR"/*.uci; do
        [ -f "$f" ] || continue
        s=${f##*/}
        s=${s%.uci}
        [ -z "$target" ] || [ "$target" = "$s" ] || continue
        if uci -q get "podkop.$s" > /dev/null 2>&1; then
            rollback_section "$s"
            log "restored section $s"
        else
            log "section $s is gone from podkop, dropping it"
        fi
        forget_section "$s"
    done
    [ -n "$(uci changes podkop)" ] || return 0
    uci commit podkop && /etc/init.d/podkop restart
}

cmd_restore() {
    local target="${1:-}"
    (
        flock -n 9 || {
            log "another podkop-sub run holds the lock"
            exit 1
        }
        restore_locked "$target"
    ) 9> "$LOCK"
}

sub_id_if_targets() {
    local sec="$1" want="$2" en url secs x
    config_get_bool en "$sec" enabled 1
    [ "$en" = 1 ] || return 0
    config_get url "$sec" url
    [ -n "$url" ] || return 0
    config_get secs "$sec" sections
    for x in $secs; do
        [ "$x" = "$want" ] && printf '%s\n' "$(sub_id "$url")" && return 0
    done
    return 0
}

section_subs() { config_foreach sub_id_if_targets subscription "$1"; }
