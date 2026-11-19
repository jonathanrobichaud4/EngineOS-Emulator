# shellcheck shell=bash
# Mods: installing one through EngineX, and writing Engine's built-in QML out to build them from.

cmd_mod_install() {
    # Uploads a mod package through EngineX on the deck itself (loopback needs no console
    # login), enables it and restarts Engine so its QML loads.
    need_root
    local f=${1:-}
    [ -f "$f" ] || die "usage: sudo ./emu.sh mod-install MOD.tar.gz"
    running || die "start the emulator first"
    local id
    id=$(tar xzOf "$f" --wildcards '*mod.json' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') ||
        die "not a mod package (no mod.json)"
    cp "$f" "$R/tmp/emu/mod-upload.tar.gz"
    local out
    out=$(in_deck /usr/bin/curl -s -m 60 -F "file=@/tmp/emu/mod-upload.tar.gz" http://127.0.0.1:$CONSOLE_PORT/v1/sc5000/mods/upload) ||
        die "upload failed (is EngineX running?)"
    rm -f "$R/tmp/emu/mod-upload.tar.gz"
    case "$out" in
        *'already installed'*) say "$id is already installed; enabling it" ;;
        *'"error":"'[!\"]*) die "EngineX refused it: $out" ;;
    esac
    in_deck /usr/bin/curl -s -m 30 -H 'Content-Type: application/json' -d "{\"id\":\"$id\",\"enabled\":true}" \
        http://127.0.0.1:$CONSOLE_PORT/v1/sc5000/mods >/dev/null || die "couldn't enable $id"
    echo restart > "$R/tmp/emu/engine-ctl"; pkill -f '/usr/Engine/Engine -d0' || :
    say "installed and enabled $id; Engine is restarting"
}

cmd_dump_qml() {
    # Write Engine's compiled-in QML and other resources out as plain files (for building mods
    # whose QML is kept as patches against the stock files).
    need_root
    local out=${1:-}; local filter=${2:-/}
    [ -n "$out" ] || die "usage: sudo ./emu.sh dump-qml OUTDIR [PATH-FILTER]"
    running && die "stop the emulator first (sudo ./emu.sh stop)"
    [ -x "$R/usr/Engine/Engine" ] || die "run setup first"
    command -v zstd >/dev/null || { apt-get install -y -qq zstd >/dev/null 2>&1 || die "needs zstd"; }
    binfmt; prepare_rootfs >/dev/null; mounts_up
    rm -f "$R"/tmp/emu/dump_* "$R"/tmp/emu/dump/* 2>/dev/null || :
    mkdir -p "$STATE"
    in_root EMU_QML_FIND="$filter" LD_PRELOAD=/usr/lib/libemushim.so QT_QPA_PLATFORM=offscreen \
        /usr/Engine/Engine -d0 > "$STATE/dump.log" 2>&1 &
    local n=0 last=-1 i
    for i in $(seq 1 60); do
        sleep 1
        n=$(grep -c 'emushim: resource' "$STATE/dump.log" 2>/dev/null || :)
        [ "${n:-0}" -gt 0 ] && [ "$n" = "$last" ] && break
        last=$n
    done
    pkill -f '/usr/Engine/Engine -d0' 2>/dev/null || :
    sleep 1
    mkdir -p "$out"
    python3 "$ENGINE/tools/dump_qml.py" "$STATE/dump.log" "$R/tmp/emu" "$out"
    rm -f "$R"/tmp/emu/dump_* 2>/dev/null || :
    mounts_down
}
