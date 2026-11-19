# shellcheck shell=bash
# Folders plugged into the deck as USB drives or the SD card. drives.txt (in the checkout, shared
# by every deck): label <TAB> usb|sd <TAB> folder. edisks_emu.py picks up changes within a second.

cmd_drive() {
    local f="$DATA/drives.txt"; touch "$f"
    case "${1:-list}" in
        add)
            local folder=${2:-} kind=usb label=""
            [ -d "$folder" ] || die "usage: ./emu.sh drive add FOLDER [--sd] [--label NAME]"
            folder=$(cd "$folder" && pwd); shift 2
            while [ $# -gt 0 ]; do
                case "$1" in --sd) kind=sd ;; --usb) kind=usb ;; --label) label=${2:-}; shift ;; esac; shift
            done
            [ -n "$label" ] || label=$(basename "$folder" | tr -c 'A-Za-z0-9_\n-' '_' | cut -c1-11)
            [ -n "$label" ] && [ "$label" != "/" ] || label=MUSIC
            case "$label" in */*|.*) die "bad label: $label" ;; esac
            grep -q "^$label	" "$f" && die "a drive called $label is already attached"
            [ "$kind" != sd ] || ! grep -q "	sd	" "$f" || die "the deck has one SD slot and it's in use"
            printf '%s\t%s\t%s\n' "$label" "$kind" "$folder" >> "$f"
            say "attached $folder as $([ $kind = sd ] && echo 'SD card' || echo 'USB drive') \"$label\"" ;;
        remove|eject)
            local label=${2:-}; [ -n "$label" ] || die "usage: ./emu.sh drive remove LABEL"
            grep -q "^$label	" "$f" || die "no drive called $label"
            grep -v "^$label	" "$f" > "$f.tmp" || :; mv "$f.tmp" "$f"
            say "removed $label" ;;
        rename)
            # the name the deck shows for the drive
            local old=${2:-} new=${3:-}
            [ -n "$old" ] && [ -n "$new" ] || die "usage: ./emu.sh drive rename LABEL NEWLABEL"
            case "$new" in */*|.*|*[!A-Za-z0-9_-]*) die "drive names are letters, digits, - and _" ;; esac
            [ ${#new} -le 11 ] || die "drive names are at most 11 characters (like a real USB stick)"
            grep -q "^$old	" "$f" || die "no drive called $old"
            [ "$old" = "$new" ] || ! grep -q "^$new	" "$f" || die "a drive called $new is already attached"
            awk -F'\t' -v o="$old" -v n="$new" 'BEGIN{OFS="\t"} $1==o{$1=n} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            say "renamed $old to $new" ;;
        type)
            # plugged into a USB port or the SD card slot (there's one)
            local label=${2:-} kind=${3:-}
            case "$kind" in usb|sd) ;; *) die "usage: ./emu.sh drive type LABEL usb|sd" ;; esac
            grep -q "^$label	" "$f" || die "no drive called $label"
            [ "$kind" != sd ] || ! grep -v "^$label	" "$f" | grep -q "	sd	" || die "the deck has one SD slot and it's in use"
            awk -F'\t' -v l="$label" -v k="$kind" 'BEGIN{OFS="\t"} $1==l{$2=k} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            say "$label is now $([ "$kind" = sd ] && echo 'in the SD slot' || echo 'a USB drive')" ;;
        list|"")
            if [ "${2:-}" = --json ]; then python3 "$ENGINE/state.py" --root "$ROOT" --data "$DATA" drives; return; fi
            [ -s "$f" ] || { say "no drives attached (./emu.sh drive add FOLDER [--sd] [--label NAME])"; return; }
            awk -F'\t' '{printf "  %-12s %-4s %s\n", $1, $2, $3}' "$f" ;;
        *) die "usage: ./emu.sh drive add FOLDER [--sd] [--label NAME] | remove LABEL | rename LABEL NEW | type LABEL usb|sd | list [--json]" ;;
    esac
}

# Drive folders from before the rename to EngineOS Emulator (~/SCLive4Emulator on a Mac,
# Music\SC LIVE 4 Emulator on Windows) are moved by the apps; point drives.txt at the new place.
migrate_drive_paths() {
    local f="$DATA/drives.txt" line out= changed=
    [ -s "$f" ] && [ -w "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        local new
        new=$(printf '%s\n' "$line" | sed -E 's#/SCLive4Emulator(/|$)#/EngineOSEmulator\1#; s#/SC LIVE 4 Emulator(/|$)#/EngineOS Emulator\1#')
        if [ "$new" != "$line" ] && [ -d "${new##*$'\t'}" ]; then line=$new; changed=1; fi
        out+="$line"$'\n'
    done < "$f"
    [ -z "$changed" ] || printf %s "$out" > "$f"
}
