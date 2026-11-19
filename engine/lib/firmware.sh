# shellcheck shell=bash
# Setting a deck up from a firmware file, installing EngineX, and telling dropped files apart.

install_bundle() {
    local src=$1 tmp
    [ -e "$src" ] || die "no such bundle: $src"
    [ -d "$R/usr/Engine" ] || die "run setup first"
    # EngineX is built from the SC LIVE 4 firmware: on a deck with other firmware (the Prime 4's)
    # it would swap that Engine for the SC LIVE 4 one. Which models take it is in the models.
    [ -n "$(model_get "$PRODUCT" enginex)" ] || die "EngineX is made for the SC LIVE 4 firmware, so it can't go on a $(product_name "$PRODUCT") deck. Use it on an SC LIVE 4 (or, untested, a Prime 4+) deck."
    binfmt; mounts_up
    tmp=$R/tmp/emu-bundle; rm -rf "$tmp"; mkdir -p "$tmp"
    case "$src" in
        *.tar.gz|*.tgz) tar -xzf "$src" -C "$tmp" ;;
        *.img) cp "$src" "$tmp/" ;;
        *) [ -d "$src" ] || die "bundle must be a .tar.gz, an EngineX Update .img or a folder"; cp -a "$src" "$tmp/" ;;
    esac
    local inst img
    img=$(ls "$tmp"/*.img 2>/dev/null | head -1 || :)
    inst=$(ls "$tmp"/*/install.sh "$tmp"/install.sh 2>/dev/null | head -1 || :)
    if [ -n "$img" ]; then
        # The Update .img carries its own install.sh; any stock bundle's install.sh can unpack it.
        [ -x "$R/data/enginex/bundle/install.sh" ] || die "an Update .img needs EngineX installed once from the .tar.gz bundle"
        in_root sh /data/enginex/bundle/install.sh "/tmp/emu-bundle/${img##*/}"
    else
        [ -n "$inst" ] || die "no install.sh found in $src"
        in_root sh "${inst#$R}"
    fi
    in_root sh /data/enginex/bundle/boot-activate.sh >/dev/null 2>&1 || :
    rm -rf "$tmp"
    say "EngineX $(cat "$R/data/enginex/version.txt" 2>/dev/null || echo '?') installed"
}

cmd_setup() {
    need_root
    local fw=${1:-}; [ -f "$fw" ] || die "usage: sudo ./emu.sh setup FIRMWARE.img [ENGINEX_BUNDLE]"
    case "$R" in /mnt/[a-z]/*) die "keep the emulator folder in your Linux home (e.g. ~/engineos-emulator), not on a Windows drive under /mnt: the rootfs needs Linux permissions and symlinks" ;; esac
    deps
    [ ! -e "$R/usr/Engine/Engine" ] || { cmd_stop >/dev/null 2>&1 || :; say "replacing existing rootfs"; mounts_down; rm -rf "$R"; }
    mkdir -p "$STATE"
    # A Windows updater .exe, a Mac updater zip or a zipped image carry the same update image;
    # QEngine's readers (engine/firmware) take it out and check the rootfs's own digest.
    local magic; magic=$(head -c4 "$fw" | od -An -tx1 | tr -d ' \n')
    case "$magic" in
        504b0304|4d5a*|377abcaf)
            say "taking the update image out of ${fw##*/}"
            python3 "$ENGINE/firmware/extract_updater.py" "$fw" "$STATE/update.img" >/dev/null ||
                die "couldn't find an update image in ${fw##*/}"
            fw="$STATE/update.img" ;;
    esac
    say "extracting rootfs from ${fw##*/} (checking its digest)"
    # "AZ01" images (Prime 4, Prime GO, SC6000) have the older container layout.
    local container=AZ0x
    [ "$(head -c 4 "$fw")" = AZ01 ] && container=AZ01
    if [ $container = AZ01 ]; then
        python3 "$ENGINE/firmware/extract_az01_rootfs.py" "$fw" "$STATE/rootfs.img" >/dev/null 2>"$STATE/extract.log" ||
            die "couldn't read ${fw##*/}: $(tail -n1 "$STATE/extract.log")"
    elif ! python3 "$ENGINE/firmware/extract_az0x_rootfs.py" "$fw" "$STATE/rootfs.img" >/dev/null 2>"$STATE/extract.log"; then
        say "note: $(tail -n1 "$STATE/extract.log"); trying the plain reader"
        python3 "$ENGINE/firmware/az0x_extract.py" "$fw" "$STATE/rootfs.img" rootfs
    fi
    # A deck set to a model this firmware can't run as follows the firmware: it becomes that
    # firmware's default model (SC LIVE 4 firmware: SC LIVE 4, Prime 4 firmware: Prime 4).
    local want=
    [ "$(model_get "$PRODUCT" container)" = $container ] || want=$(default_model_for $container)
    rm -f "$STATE/update.img"
    say "unpacking ext4 image"
    mkdir -p "$R"
    debugfs -R "rdump / $R" "$STATE/rootfs.img" >/dev/null 2>"$STATE/debugfs.log" || die "debugfs failed, see $STATE/debugfs.log"
    rm -f "$STATE/rootfs.img"
    [ -x "$R/usr/Engine/Engine" ] || die "no /usr/Engine/Engine in that firmware; is it an Engine OS update?"
    if [ -n "$want" ]; then
        say "this is $(product_name "$want") firmware, so the deck is now a $(product_name "$want") (it was set to $(product_name "$PRODUCT"))"
        PRODUCT=$want; echo "$want" > "$STATE/product"
    fi
    prepare_rootfs
    say "Engine OS ready in $R"
    [ -z "${2:-}" ] || install_bundle "$2"
    mounts_down
    say "done. Start it with: sudo ./emu.sh ${PROFILE:+--profile $PROFILE }start"
}

cmd_identify() {
    # What a dropped file is: firmware | enginex | mod | unknown
    local f=${1:-}
    [ -f "$f" ] || { echo unknown; return; }
    case "$f" in
        *.img|*.IMG)
            # inMusic update images: "AZ0x" (SC LIVE 4 and newer), "AZ01" (Prime 4, older layout)
            case "$(head -c4 "$f" 2>/dev/null)" in AZ0x|AZ01) echo firmware ;; *) echo enginex ;; esac ;;
        *.exe|*.EXE|*.zip|*.ZIP)  # inMusic's desktop updaters and zipped images (engine/firmware)
            case "$(head -c2 "$f" 2>/dev/null)" in MZ|PK) echo firmware ;; *) echo unknown ;; esac ;;
        *.tar.gz|*.tgz|*.TAR.GZ)
            local list; list=$(tar tzf "$f" 2>/dev/null | head -n 400)
            if echo "$list" | grep -q '/mod.json$\|^mod.json$'; then echo mod
            elif echo "$list" | grep -q 'install.sh$'; then echo enginex
            else echo unknown; fi ;;
        *) echo unknown ;;
    esac
}
