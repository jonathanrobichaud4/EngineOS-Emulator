# shellcheck shell=bash
# Decks (profiles): each one is rootfs[-NAME]/ and state[-NAME]/ in the checkout ("default" has
# no suffix). state[-NAME]/product holds its model code.

cmd_profiles() {
    # One line per deck: name <TAB> set up? <TAB> EngineX version <TAB> model code <TAB> running?
    # A deck exists once it has a rootfs (set up) or a state folder (made with "profile new").
    # --json: the same as a list of objects.
    python3 "$ENGINE/state.py" --root "$ROOT" --data "$DATA" profiles ${1:+"$1"}
}

profile_name() {
    case "$1" in
        ""|*[!A-Za-z0-9_-]*) die "deck names are letters, digits, - and _" ;;
    esac
}
profile_sfx() { [ "$1" = default ] && echo "" || echo "-$1"; }
profile_exists() { local x; x=$(profile_sfx "$1"); [ -d "$DATA/rootfs$x" ] || [ -d "$DATA/state$x" ]; }
profile_running() { local x; x=$(profile_sfx "$1"); [ -f "$DATA/state$x/emu.pid" ] && kill -0 "$(cat "$DATA/state$x/emu.pid")" 2>/dev/null; }
# Stopped, with nothing of the host (drives, /dev, /proc) still mounted inside it.
profile_quiet() {
    local x r; x=$(profile_sfx "$1"); r=$DATA/rootfs$x
    profile_running "$1" && die "deck $1 is running; stop it first"
    if awk -v r="$r" 'index($2, r "/") == 1 || $2 == r {f=1} END {exit !f}' /proc/self/mounts; then
        EMU_PROFILE=$1 EMU_ROOTFS= emu_self unmount >/dev/null 2>&1 || :
        awk -v r="$r" 'index($2, r "/") == 1 || $2 == r {f=1} END {exit !f}' /proc/self/mounts &&
            die "deck $1 still has folders mounted inside it; restart the computer (or WSL/VM) and try again"
    fi
    return 0
}

cmd_profile() {
    local what=${1:-}; shift || :
    case "$what" in
        new)
            local name=${1:-} model=${2:-${MODEL_CODES%% *}}
            profile_name "$name"; need_root
            profile_exists "$name" && die "there's already a deck called $name"
            model=$(echo "$model" | tr a-z A-Z)
            is_model "$model" || die "unknown model $model; one of: $MODEL_CODES"
            mkdir -p "$DATA/state$(profile_sfx "$name")"
            echo "$model" > "$DATA/state$(profile_sfx "$name")/product"
            say "made deck $name ($(product_name "$model")); set it up with a firmware file" ;;
        rename)
            local old=${1:-} new=${2:-} a b
            profile_name "$old"; profile_name "$new"; need_root
            profile_exists "$old" || die "there's no deck called $old"
            profile_exists "$new" && die "there's already a deck called $new"
            profile_quiet "$old"
            a=$(profile_sfx "$old"); b=$(profile_sfx "$new")
            [ ! -d "$DATA/rootfs$a" ] || mv "$DATA/rootfs$a" "$DATA/rootfs$b"
            [ ! -d "$DATA/state$a" ] || mv "$DATA/state$a" "$DATA/state$b"
            say "renamed deck $old to $new" ;;
        delete)
            local name=${1:-} x
            profile_name "$name"; need_root
            profile_exists "$name" || die "there's no deck called $name"
            profile_quiet "$name"
            x=$(profile_sfx "$name")
            # --one-file-system: never follow into anything that might still be mounted.
            rm -rf --one-file-system "$DATA/rootfs$x" "$DATA/state$x"
            say "deleted deck $name" ;;
        model)
            local name=${1:-} model=${2:-} x
            profile_name "$name"
            profile_exists "$name" || die "there's no deck called $name"
            x=$(profile_sfx "$name")
            [ -n "$model" ] || { cat "$DATA/state$x/product" 2>/dev/null || echo "${MODEL_CODES%% *}"; return; }
            EMU_PROFILE= emu_self --profile "$name" product "$model" ;;
        *) die "usage: ./emu.sh profile new NAME [MODEL] | rename OLD NEW | delete NAME | model NAME [MODEL]" ;;
    esac
}

cmd_product() {
    if [ -z "${1:-}" ]; then echo "$PRODUCT ($(product_name "$PRODUCT"))"; return; fi
    local want; want=$(echo "$1" | tr a-z A-Z)
    is_model "$want" || die "unknown product $1; one of: $MODEL_CODES"
    need_root; mkdir -p "$STATE"; echo "$want" > "$STATE/product"
    say "this deck is now: $(product_name "$want") ($want)$(running && echo '; restart it (reboot) to switch')"
}
