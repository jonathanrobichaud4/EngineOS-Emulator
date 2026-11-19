# shellcheck shell=bash
# Starting and stopping the deck: Engine under qemu, and the processes around it (the deck page,
# drives, network, GL server, EngineX's console).

engine_loop() {
    rm -f "$STATE/engine-error"
    # Restarts Engine when it exits, like engine.service does (also how the console's restart works).
    local stock=$1 preload=/usr/lib/libemushim.so n=0 t0 glfail=0 msg
    # eglfs on Mesa's surfaceless EGL; the shim turns its window into a pbuffer and reads frames
    # back at each swap. eglfs insists on opening a framebuffer device but only needs it for the
    # size, which is given here, so /dev/null does. 339x212 mm keeps Qt at 96 dpi.
    local render="QT_QPA_PLATFORM=eglfs QT_QPA_EGLFS_INTEGRATION=none QT_QPA_EGLFS_WIDTH=1280 QT_QPA_EGLFS_HEIGHT=800
        QT_QPA_EGLFS_PHYSICAL_WIDTH=339 QT_QPA_EGLFS_PHYSICAL_HEIGHT=212 QT_QPA_EGLFS_HIDECURSOR=1
        QT_QPA_EGLFS_DISABLE_INPUT=1 QT_QPA_EGLFS_NO_LIBINPUT=1 QT_QPA_EGLFS_FB=/dev/null EGL_PLATFORM=surfaceless
        LIBGL_DRIVERS_PATH=/usr/lib/emu-dri GALLIUM_DRIVER=virpipe VTEST_SOCKET_NAME=/tmp/emu/virgl.sock EMU_GL=1"
    if [ "$stock" = 0 ] && [ -f "$R/data/enginex/bundle/lib/libengine-ui-hook.so" ]; then
        preload=$preload:${EMU_HOOK:-/data/enginex/bundle/lib/libengine-ui-hook.so}
    fi
    while :; do
        if [ -f "$R/tmp/emu/engine-ctl" ] && [ "$(cat "$R/tmp/emu/engine-ctl")" = stop ]; then sleep 1; continue; fi
        rm -f "$R/tmp/emu/engine-ctl"
        n=$((n + 1)); t0=$(date +%s)
        echo "=== Engine start #$n $(date '+%F %T') preload=$preload" >> "$STATE/engine.log"
        # shellcheck disable=SC2086  # $render is a list of VAR=value words
        in_deck EMU_DEBUG=${EMU_DEBUG:-0} EMU_QML_FIND=${EMU_QML_FIND:-} EMU_HOSTNAME="$(deck_name)" LD_PRELOAD="$preload" $render \
            MALLOC_ARENA_MAX=1 QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1 \
            /usr/Engine/Engine -d0 -skipFirmwareUpdate -loggerOptions "Type, Message, Thread, Category, SplitLongLines" \
            >> "$STATE/engine.log" 2>&1 || :
        echo "=== Engine exited $(date '+%F %T')" >> "$STATE/engine.log"
        msg=
        # Quit straight to "TestApp": this firmware doesn't run as this model.
        if [ "$(cat "$R/tmp/engine-quit-reason" 2>/dev/null)" = TestApp ] && [ $(($(date +%s) - t0)) -lt 120 ]; then
            rm -f "$R/tmp/engine-quit-reason"
            msg="this firmware doesn't run as a $(product_name "$PRODUCT"): $MODEL_RUNS_AS. Change the deck's model or set it up with the right firmware."
        # OpenGL that starts but doesn't work (virgl drops Engine as soon as it connects), or a
        # virgl server that has died, twice in a row.
        elif { [ $(($(date +%s) - t0)) -lt 30 ] && tail -n 40 "$STATE/engine.log" | grep -q 'lost connection to rendering server'; } ||
             ! kill -0 "$(cat "$STATE/virgl.pid" 2>/dev/null)" 2>/dev/null; then
            glfail=$((glfail + 1))
            [ $glfail -lt 2 ] || msg="OpenGL isn't working here: Engine keeps losing the virgl server (see $STATE/virgl.log)."
        else
            glfail=0
        fi
        # Say why and stop restarting it.
        if [ -n "$msg" ]; then
            echo "=== emu: $msg" >> "$STATE/engine.log"
            echo "$msg" > "$STATE/engine-error"
            return 0
        fi
        rm -f "$STATE/engine-error"
        sleep 2
    done
}

# Is a process with this name running inside the deck's root?
deck_has() {
    local real p; real=$(readlink -f "$R")
    for p in $(pgrep -f "$1" 2>/dev/null); do
        [ "$(readlink "/proc/$p/root" 2>/dev/null)" = "$real" ] && return 0
    done
    return 1
}

cmd_start() {
    need_root
    [ -x "$R/usr/Engine/Engine" ] || die "run: sudo ./emu.sh setup FIRMWARE.img [ENGINEX_BUNDLE]"
    running && die "already running (sudo ./emu.sh stop first)"
    local other
    for other in "$DATA"/state*/emu.pid; do
        [ -f "$other" ] && [ "$other" != "$STATE/emu.pid" ] && kill -0 "$(cat "$other")" 2>/dev/null &&
            die "another profile is running ($(basename "$(dirname "$other")")); stop it first"
    done
    local stock=0; [ "${1:-}" = --stock ] && stock=1
    deps; gl_ready; binfmt; prepare_rootfs >/dev/null; mounts_up
    mkdir -p "$STATE"; : > "$STATE/engine.log"
    # the deck's D-Bus (connman needs it): a socket left by a stopped one doesn't count
    deck_has dbus-daemon || { rm -f "$R/run/dbus/system_bus_socket"; in_root /usr/bin/dbus-daemon --system --fork --nopidfile; }
    net_up
    link_up $stock
    python3 "$ENGINE/edisks_emu.py" --rootfs "$R" --drives "$DATA/drives.txt" </dev/null > "$STATE/edisks.log" 2>&1 &
    echo $! > "$STATE/edisks.pid"
    if [ $stock = 0 ] && [ -x "$R/data/enginex/bundle/bin/stream-sync" ]; then
        # EngineX picks its Pro DJ Link interface once, when it starts: let the deck get its address
        # first (DHCP can take a while under emulation; up to 30 s)
        local n; for n in $(seq 1 120); do [ "$EMU_NET" != 1 ] || [ -n "$(deck_ip)" ] && break; sleep 0.25; done
        in_deck /data/enginex/bundle/bin/stream-sync --listen ":$CONSOLE_PORT" > "$STATE/stream-sync.log" 2>&1 &
        echo $! > "$STATE/stream-sync.pid"
        # EngineX's rekordbox library and Pro DJ Link bridge (its enginex-rb-bridge service)
        if [ -x "$R/data/enginex/bundle/bin/rb-bridge" ]; then
            in_deck /data/enginex/bundle/bin/rb-bridge --prolink > "$STATE/rb-bridge.log" 2>&1 &
            echo $! > "$STATE/rb-bridge.pid"
        fi
    fi
    mkdir -p "$R/tmp/emu"; rm -f "$R/tmp/emu/virgl.sock"
    virgl_test_server --use-egl-surfaceless --socket-path "$R/tmp/emu/virgl.sock" \
        </dev/null > "$STATE/virgl.log" 2>&1 &
    echo $! > "$STATE/virgl.pid"
    local w
    for w in $(seq 1 20); do [ -S "$R/tmp/emu/virgl.sock" ] && break; sleep 0.25; done
    if [ ! -S "$R/tmp/emu/virgl.sock" ]; then
        tail -n 5 "$STATE/virgl.log" >&2; cmd_stop >/dev/null 2>&1 || :
        die "the virgl server didn't start (OpenGL; its log is above)"
    fi
    engine_loop $stock </dev/null >/dev/null 2>&1 & echo $! > "$STATE/emu.pid"
    local fwd=""; [ "$EMU_NET" = 1 ] && fwd="--forward $CONSOLE_PORT=$NET_DECK_IP:$CONSOLE_PORT"
    # shellcheck disable=SC2086  # $fwd is two words or none
    PYTHONPATH="$ROOT" python3 -m viewer --rootfs "$R" --product "$PRODUCT" --profile "${PROFILE:-default}" \
        --port "$VIEW_PORT" --console "http://localhost:$CONSOLE_PORT/" --drives "$DATA/drives.txt" $fwd \
        < /dev/null > "$STATE/viewer.log" 2>&1 &
    echo $! > "$STATE/viewer.pid"
    # Don't report success unless the deck page is actually answering.
    local i
    for i in $(seq 1 30); do
        curl -sf -o /dev/null -m 2 "http://127.0.0.1:$VIEW_PORT/" && break
        if ! kill -0 "$(cat "$STATE/viewer.pid")" 2>/dev/null; then
            echo "emu: the deck page server stopped; its log:" >&2; tail -n 20 "$STATE/viewer.log" >&2; cmd_stop >/dev/null 2>&1 || :
            die "start failed"
        fi
        sleep 0.5
    done
    [ "$i" -lt 30 ] || { tail -n 20 "$STATE/viewer.log" >&2; die "the deck page isn't answering on port $VIEW_PORT"; }
    say "booting $(product_name "$PRODUCT")${PROFILE:+ (deck $PROFILE)} (first screen takes 1-2 minutes under emulation)"
    say "deck:    http://localhost:$VIEW_PORT/  (screen, controls, audio, drives)"
    [ $stock = 1 ] || [ ! -x "$R/data/enginex/bundle/bin/stream-sync" ] || say "EngineX console: http://localhost:$CONSOLE_PORT/"
    if [ "$EMU_NET" != 1 ]; then say "network: off (EMU_NET=0)"
    elif link_on; then say "network: on your network as $(deck_name) at $(lan_addresses | tr ' ' ',') (./emu.sh network local to keep it to this computer)"
    else say "network: internet only, not visible on your network (./emu.sh network on)"; fi
    say "logs:    sudo ./emu.sh ${PROFILE:+--profile $PROFILE }log      stop: sudo ./emu.sh ${PROFILE:+--profile $PROFILE }stop"
}

cmd_stop() {
    need_root
    local f
    for f in emu viewer stream-sync rb-bridge connman udhcpd edisks virgl linkbridge; do
        [ -f "$STATE/$f.pid" ] && kill "$(cat "$STATE/$f.pid")" 2>/dev/null || :
        rm -f "$STATE/$f.pid"
    done
    pkill -f '/usr/Engine/Engine -d0' 2>/dev/null || :
    pkill -f 'enginex/bundle/bin/' 2>/dev/null || :
    # started through in_deck in the background, so the saved pid is a subshell's: by command line
    pkill -f '/etc/emu/connman.conf' 2>/dev/null || :; pkill -f '/etc/emu/udhcpd.conf' 2>/dev/null || :
    pkill -f "$ENGINE/linkbridge.py" 2>/dev/null || :
    # Mod helper scripts started inside the chroot
    local real; real=$(readlink -f "$R")
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/root" 2>/dev/null)" = "$real" ] && kill "${p#/proc/}" 2>/dev/null || :
    done
    sleep 2
    mounts_down
    net_down
    say "stopped"
}

cmd_restart_engine() {
    need_root
    echo restart > "$R/tmp/emu/engine-ctl"; pkill -f '/usr/Engine/Engine -d0' || :
}

cmd_status() {
    running && say "running (pid $(cat "$STATE/emu.pid"))" || say "not running"
    pgrep -f '/usr/Engine/Engine -d0' >/dev/null && say "Engine process up" || say "Engine process not up"
    [ -z "$(deck_ip)" ] || say "network: deck $(deck_ip) via $NET_HOST_IF ($NET_HOST_IP)"
    [ -f "$R/data/enginex/version.txt" ] && say "EngineX $(cat "$R/data/enginex/version.txt")" || say "EngineX not installed"
    curl -s "http://localhost:$VIEW_PORT/status" 2>/dev/null && echo || :
}

cmd_tap() { printf 'down %s %s\n' "$1" "$2" > "$R/tmp/emu/input"; sleep 0.2; printf 'up %s %s\n' "$1" "$2" > "$R/tmp/emu/input"; }

# Emulators before 1.3 could also render without OpenGL, and older apps still set this before
# starting a deck. There's only OpenGL now, so it just says so.
cmd_graphics() { say "graphics: OpenGL through virgl (the only renderer)"; }

cmd_reset_data() {
    need_root; running && die "stop it first"
    rm -rf "$R/data/AppDataUser" "$R/data/StreamingAccounts.json"
    say "Engine settings and library reset (EngineX kept)"
}
