# shellcheck shell=bash
# The deck's root filesystem: what the emulator adds to the firmware's, and what it mounts.

# Point inMusic's telemetry hosts at localhost so nothing the emulated deck does reaches
# inMusic's error reporting or analytics. List from QEngine (rootfs_steps/block_telemetry.sh,
# MIT, Copyright (c) Peyton-C); Engine handles the failed connections.
block_telemetry() {
    local host
    for host in o230257.ingest.sentry.io analytics.inmusicbrands.com posthog.data.aws.inmusic.dev \
                posthog.inmusic-cloud.prod.aws.inmusic.dev ssl.google-analytics.com; do
        grep -qxF "127.0.0.1 $host" "$R/etc/hosts" 2>/dev/null || echo "127.0.0.1 $host" >> "$R/etc/hosts"
    done
}

# Models whose internal boards are USB MIDI devices (the Prime 4: Controller, Mixer, Left and
# Right Display) get them as sound cards 0-3 in the order the shim gives them. Engine binds the
# displays by USB product ID as well as by their identity reply (KnownDevices: Left 9008,
# Right b008), reading it from the device behind /sys/class/sound/cardN/device, so each card gets
# a USB device here. The boards and their IDs come from the model (midi.devices[].usb_pid).
usb_boards() {
    local i=0 b name pid hub=/sys/devices/platform/ff500000.usb/usb1/1-1
    rm -rf "$R/sys/class/sound" "$R$hub"; mkdir -p "$R/sys/class/sound"
    for b in $(model_get "$PRODUCT" boards); do
        name=$(echo "${b%%:*}" | tr _ ' '); pid=${b##*:}
        local dev=$hub/1-1.$((i + 1)) intf=$hub/1-1.$((i + 1))/1-1.$((i + 1)):1.0
        mkdir -p "$R$intf/sound/card$i"
        printf '15e4\n' > "$R$dev/idVendor"; printf '%s\n' "$pid" > "$R$dev/idProduct"
        printf '%s\n' "$name" > "$R$dev/product"; printf 'inMusic\n' > "$R$dev/manufacturer"
        printf '1\n' > "$R$dev/busnum"; printf '%s\n' $((i + 2)) > "$R$dev/devnum"; printf '1.%s\n' $((i + 1)) > "$R$dev/devpath"
        printf 'Surface%s\n' "$([ $i = 0 ] || echo $i)" > "$R$intf/sound/card$i/id"; printf '%s\n' $i > "$R$intf/sound/card$i/number"
        ln -sfn "../../devices/platform/ff500000.usb/usb1/1-1/1-1.$((i + 1))/1-1.$((i + 1)):1.0/sound/card$i" "$R/sys/class/sound/card$i"
        ln -sfn "../../../1-1.$((i + 1)):1.0" "$R$intf/sound/card$i/device"
        i=$((i + 1))
    done
}

prepare_rootfs() {
    mkdir -p "$R/etc/emu" "$R/usr/bin"
    rm -rf "$R/sys" && tar -C "$R" -xzf "$ASSETS/fakesys.tar.gz"
    printf %s "$PRODUCT" > "$R/sys/firmware/devicetree/base/inmusic,product-code"  # no newline, as on the unit
    # Engine runs only as a deck its firmware was built for: it checks the product code against
    # its own list and otherwise quits to "TestApp" (engine_loop says so). Which firmware runs as
    # which model is in the models (firmware.name).
    # RK3288 Prime decks also read their eFuses (model "efuse"): the secure one holds the product
    # code, the CPU-id one "RK3288" + board + product at byte 7. Contents as QEngine writes them
    # (rootfs_steps/write_fake_dt.sh, MIT, Copyright (c) Peyton-C). The SC LIVE 4's stand-ins
    # (fakesys) already pass, so they stay.
    if [ -n "$(model_get "$PRODUCT" efuse)" ]; then
        local ef=$R/sys/devices/platform
        mkdir -p "$ef/ffb10000.efuse/rockchip-efuse0" "$ef/ffb40000.efuse/rockchip-efuse0"
        { printf %s "$PRODUCT"; head -c $((128 - ${#PRODUCT})) /dev/zero; } > "$ef/ffb10000.efuse/rockchip-efuse0/nvmem"
        { head -c 7 /dev/zero; printf %s "RK3288AZ01$PRODUCT"; head -c $((128 - 17 - ${#PRODUCT})) /dev/zero; } \
            > "$ef/ffb40000.efuse/rockchip-efuse0/nvmem"
    fi
    [ -z "$(model_get "$PRODUCT" boards)" ] || usb_boards
    # Both names, so it works whichever path the kernel's binfmt entry was registered with.
    cp "$QEMU" "$R/usr/bin/qemu-arm-static"
    cp "$QEMU" "$R/usr/bin/qemu-arm"
    cp "$ENGINE/shim/libemushim.so" "$R/usr/lib/libemushim.so"
    cp "$ASSETS/screen.json" "$R/etc/emu/screen.json"
    rm -rf "$R/etc/emu/qml"; [ ! -d "$ASSETS/qml" ] || cp -r "$ASSETS/qml" "$R/etc/emu/qml"
    # Engine items that need OpenGL (waveforms); found per Engine build, cached by its size+mtime
    local stamp; stamp=$(stat -c '%s %Y' "$R/usr/Engine/Engine")
    if [ "$(head -n1 "$R/etc/emu/gl-items.txt" 2>/dev/null)" != "# $stamp" ]; then
        { echo "# $stamp"; python3 "$ENGINE/tools/gl_items.py" "$R/usr/Engine/Engine" "$R/lib/libQt6Quick.so.6" 2>/dev/null; } \
            > "$R/etc/emu/gl-items.txt" || :
    fi
    block_telemetry
    rm -rf "$R/usr/lib/emu-dri"
    if [ -f "$ASSETS/gl/swrast_dri.so" ]; then
        mkdir -p "$R/usr/lib/emu-dri"; cp "$ASSETS/gl/swrast_dri.so" "$R/usr/lib/emu-dri/swrast_dri.so"
    fi
    cp "$ASSETS/systemctl" "$R/etc/emu/systemctl"; chmod 755 "$R/etc/emu/systemctl"
    [ -e "$R/etc/emu/systemctl.real" ] || cp -a "$R/usr/bin/systemctl" "$R/etc/emu/systemctl.real"
}

mounts_up() {
    mountpoint -q "$R/proc" || mount -t proc proc "$R/proc"
    # Engine looks up the control-surface UARTs' IRQs by name in /proc/interrupts, then writes
    # /proc/irq/<n>/smp_affinity_list, and aborts if either fails. WSL2 has no serial ports and
    # no writable IRQ settings, so the chroot gets its own list naming the deck's UARTs and a
    # scratch /proc/irq where those writes land harmlessly.
    if ! mountpoint -q "$R/proc/interrupts"; then
        mkdir -p "$STATE"
        { grep -v ' ttyS[0-9]*$' /proc/interrupts
          echo " 250:          0          0  GICv3  54 Level     ttyS0"
          echo " 251:          0          0  GICv3  58 Level     ttyS4"
        } > "$STATE/interrupts"
        mount --bind "$STATE/interrupts" "$R/proc/interrupts"
    fi
    if ! mountpoint -q "$R/proc/irq"; then
        mount -t tmpfs -o size=1m tmpfs "$R/proc/irq"
        for n in 250 251; do
            mkdir -p "$R/proc/irq/$n"
            echo 0-3 > "$R/proc/irq/$n/smp_affinity_list"; echo f > "$R/proc/irq/$n/smp_affinity"
        done
    fi
    mountpoint -q "$R/dev" || { mount --rbind /dev "$R/dev" && mount --make-rslave "$R/dev"; }
    mountpoint -q "$R/tmp" || mount -t tmpfs -o mode=1777 tmpfs "$R/tmp"
    mountpoint -q "$R/run" || mount -t tmpfs tmpfs "$R/run"
    mountpoint -q "$R/media" || mount -t tmpfs -o mode=755 tmpfs "$R/media"  # as on the deck
    mountpoint -q "$R/usr/bin/systemctl" || mount --bind "$R/etc/emu/systemctl" "$R/usr/bin/systemctl"
    mkdir -p "$R/run/dbus" "$R/tmp/emu" "$R/tmp/sc5000-engine-home"
    chmod 700 "$R/tmp/sc5000-engine-home"
    [ -p "$R/tmp/emu/input" ] || mkfifo "$R/tmp/emu/input"
    if [ "$EMU_NET" != 1 ]; then  # no connman: give the deck the PC's resolvers directly
        mkdir -p "$R/run/connman"  # /etc/resolv.conf -> resolv-conf.connman -> /run/connman/resolv.conf
        grep -v '^nameserver 127' /etc/resolv.conf > "$R/run/connman/resolv.conf" 2>/dev/null || :
        echo "nameserver 1.1.1.1" >> "$R/run/connman/resolv.conf"
    fi
}

# The emulator's QML additions (assets/qml-inject): Engine's waveforms need OpenGL, so the emulator
# switches those items off and adds its own software-drawn waveform to their QML. The shim adds
# the snippets to Engine's compiled-in files; EngineX's UI pack has its own copies of some of
# them, so those get an injected copy bind-mounted over them while the deck runs.
qml_inject() {
    local spec res src rel gen
    rm -rf "$R/etc/emu/qml-inject" "$R/etc/emu/qml-gen"
    for spec in "$ASSETS"/qml-inject/*.inject; do
        [ -f "$spec" ] || continue
        res=$(sed -n 's/^path: //p' "$spec" | head -n1)
        mkdir -p "$R/etc/emu/qml-inject$(dirname "$res")"
        cp "$spec" "$R/etc/emu/qml-inject$res"
        for src in "$R"/data/enginex/ui/packs/*"$res"; do
            [ -f "$src" ] || continue
            grep -qF " $src " /proc/self/mounts && continue
            rel=${src#"$R"/data/enginex/ui/}; gen="$R/etc/emu/qml-gen/$rel"
            mkdir -p "$(dirname "$gen")"
            if python3 "$ENGINE/tools/qml_inject.py" "$spec" "$src" "$gen"; then
                mount --bind "$gen" "$src" || :
            else
                say "note: ${spec##*/} doesn't fit EngineX's $rel (waveforms stay blank there)"
            fi
        done
    done
}

mounts_down() {
    # Everything mounted under the rootfs, deepest first (boot-activate.sh adds its own bind mounts).
    local m
    mountpoint -q "$R/dev" && mount --make-rslave "$R/dev" 2>/dev/null || :
    for m in $(awk -v r="$R" '$2 == r || index($2, r "/") == 1 {print $2}' /proc/self/mounts | sort -r); do
        umount -l "$m" 2>/dev/null || :
    done
}
