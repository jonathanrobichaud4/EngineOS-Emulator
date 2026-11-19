# shellcheck shell=bash
# What the apps read: the selected deck's state, every deck, the drives and the models.

cmd_info() {
    local engine=down ip
    pgrep -f '/usr/Engine/Engine -d0' >/dev/null && engine=up
    ip=$(deck_ip)
    if [ "${1:-}" = --json ]; then
        # Everything the apps show in one answer (docs/cli.md describes it).
        python3 "$ENGINE/state.py" --root "$ROOT" --data "$DATA" info --profile "${PROFILE:-default}" --product "$PRODUCT" \
            --rootfs "$R" --state "$STATE" --engine "$engine" --ip "$ip" \
            --deck-url "http://localhost:$VIEW_PORT/" --console-url "http://localhost:$CONSOLE_PORT/" \
            --net "$([ "$EMU_NET" != 1 ] && echo off || { link_on && echo lan || echo local; })" \
            --net-name "$(deck_name)" --net-addresses "$(lan_addresses)"
        return
    fi
    # key=value lines, as before (older apps read these).
    echo "profile=${PROFILE:-default}"
    echo "product=$PRODUCT"
    echo "product_name=$(product_name "$PRODUCT")"
    [ -x "$R/usr/Engine/Engine" ] && echo "setup=yes" || echo "setup=no"
    echo "engine_error=$(cat "$STATE/engine-error" 2>/dev/null)"
    if [ -f "$R/data/enginex/version.txt" ]; then echo "enginex=$(head -n1 "$R/data/enginex/version.txt")"; else echo "enginex="; fi
    running && echo "running=yes" || echo "running=no"
    echo "engine=$engine"
    echo "ip=$ip"
    echo "deck_url=http://localhost:$VIEW_PORT/"
    echo "console_url=http://localhost:$CONSOLE_PORT/"
}

cmd_models() {
    case "${1:-}" in
        --json) python3 "$MODELS/models.py" json ;;
        *) local c; for c in $MODEL_CODES; do printf '%s\t%s\n' "$c" "$(product_name "$c")"; done ;;
    esac
}

cmd_version() { cat "$ROOT/VERSION" 2>/dev/null || echo dev; }
