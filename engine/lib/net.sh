# shellcheck shell=bash
# Emulated USB Ethernet: the deck lives in its own network namespace behind NAT, with the
# firmware's own DHCP client (connman) and a DHCP server on the PC side. That gives it the
# internet. linkbridge.py then puts it on your network too (Engine Link, Engine DJ, StageLinQ
# lighting apps): see link_up and docs/networking.md.

NETNS=enginex
NET_HOST_IF=emu0
NET_HOST_IP=10.77.0.1
NET_DECK_IP=10.77.0.2
NET_DECK_MAC=02:4a:50:32:31:00

dns_servers() {
    # The host's resolvers, if the deck's namespace can reach them, then public fallbacks.
    local out=""
    for ns in $(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null); do
        case "$ns" in 127.*|::*|*:*) ;; *) out="$out $ns" ;; esac
    done
    echo $out 1.1.1.1 8.8.8.8
}

# The deck's address, or nothing when its network isn't up.
deck_ip() {
    [ -e /run/netns/$NETNS ] || return 0
    ip -n $NETNS -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || :
}

net_up() {
    [ "$EMU_NET" = 1 ] || return 0
    # A namespace left over from before a restart (of WSL, the VM or the computer) is just a
    # dead file; clear it so it can be made again.
    if [ -e /run/netns/$NETNS ] && ! ip netns exec $NETNS true 2>/dev/null; then ip netns del $NETNS 2>/dev/null || rm -f /run/netns/$NETNS; fi
    [ -e /run/netns/$NETNS ] || ip netns add $NETNS
    if ! ip link show $NET_HOST_IF >/dev/null 2>&1; then
        ip link add $NET_HOST_IF type veth peer name eth0 netns $NETNS
        ip -n $NETNS link set eth0 address $NET_DECK_MAC
    fi
    ip addr replace $NET_HOST_IP/24 dev $NET_HOST_IF
    ip link set $NET_HOST_IF up
    ip -n $NETNS link set lo up
    # connman classifies interfaces from sysfs uevent; with none it ignores the device.
    # No DEVTYPE means plain Ethernet, which is how a USB Ethernet adapter shows up.
    local idx; idx=$(ip -n $NETNS -o link show eth0 | cut -d: -f1)
    mkdir -p "$R/sys/class/net/eth0"
    printf 'INTERFACE=eth0\nIFINDEX=%s\n' "$idx" > "$R/sys/class/net/eth0/uevent"
    echo 1 > "$R/sys/class/net/eth0/type"
    echo $NET_DECK_MAC > "$R/sys/class/net/eth0/address"
    sysctl -qw net.ipv4.ip_forward=1
    iptables -t nat -C POSTROUTING -s 10.77.0.0/24 ! -o $NET_HOST_IF -j MASQUERADE 2>/dev/null ||
        iptables -t nat -A POSTROUTING -s 10.77.0.0/24 ! -o $NET_HOST_IF -j MASQUERADE
    iptables -C FORWARD -i $NET_HOST_IF -j ACCEPT 2>/dev/null || iptables -I FORWARD -i $NET_HOST_IF -j ACCEPT
    iptables -C FORWARD -o $NET_HOST_IF -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -o $NET_HOST_IF -m state --state RELATED,ESTABLISHED -j ACCEPT
    # DHCP server on the PC side (the firmware's own busybox udhcpd), fixed lease for the deck
    cat > "$R/etc/emu/udhcpd.conf" <<CONF
start 10.77.0.2
end 10.77.0.20
interface $NET_HOST_IF
lease_file /tmp/emu/udhcpd.leases
pidfile /tmp/emu/udhcpd.pid
static_lease $NET_DECK_MAC $NET_DECK_IP
opt subnet 255.255.255.0
opt router $NET_HOST_IP
opt dns $(dns_servers)
opt domain lan
opt lease 86400
CONF
    touch "$R/tmp/emu/udhcpd.leases"
    in_root /usr/sbin/udhcpd -f /etc/emu/udhcpd.conf > "$STATE/udhcpd.log" 2>&1 &
    echo $! > "$STATE/udhcpd.pid"
    # connman as on the deck, but it must never set the PC's clock (the clock isn't namespaced)
    sed -e '/^TimeUpdates/d' -e '/^TimezoneUpdates/d' "$R/etc/connman/main.conf" > "$R/etc/emu/connman.conf"
    printf 'TimeUpdates=manual\nTimezoneUpdates=manual\n' >> "$R/etc/emu/connman.conf"
    mkdir -p "$R/var/lib/connman"
    mkdir -p "$R/run/connman"  # connman writes resolv.conf here (/etc/resolv.conf links to it)
    in_deck /usr/sbin/connmand -n -c /etc/emu/connman.conf > "$STATE/connman.log" 2>&1 &
    echo $! > "$STATE/connman.pid"
}

net_down() {
    # linkbridge.py's stand-ins for the devices on the network (they go with emu0 itself)
    iptables -t nat -D PREROUTING -i $NET_HOST_IF -j EMU_LINK 2>/dev/null || :
    iptables -t nat -F EMU_LINK 2>/dev/null || :; iptables -t nat -X EMU_LINK 2>/dev/null || :
    # and its Pro DJ Link forwards (UDP services the deck offers CDJs)
    iptables -t nat -D PREROUTING ! -i $NET_HOST_IF -m addrtype --dst-type LOCAL -j EMU_LINK_IN 2>/dev/null || :
    iptables -t nat -F EMU_LINK_IN 2>/dev/null || :; iptables -t nat -X EMU_LINK_IN 2>/dev/null || :
    iptables -D FORWARD -d $NET_DECK_IP -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null || :
    [ -e /run/netns/$NETNS ] || return 0
    ip link del $NET_HOST_IF 2>/dev/null || :
    ip netns del $NETNS 2>/dev/null || :
    iptables -t nat -D POSTROUTING -s 10.77.0.0/24 ! -o $NET_HOST_IF -j MASQUERADE 2>/dev/null || :
    iptables -D FORWARD -i $NET_HOST_IF -j ACCEPT 2>/dev/null || :
    iptables -D FORWARD -o $NET_HOST_IF -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || :
}

# ---- on your network -------------------------------------------------------------------------
# On by default; `emu.sh network local` keeps the deck to this computer (internet only), and
# `emu.sh network on` puts it back. One setting for every deck ($DATA/network.conf).
link_on() { [ "$EMU_NET" = 1 ] && ! grep -qx 'LINK=off' "$DATA/network.conf" 2>/dev/null; }

# The deck's name on the network: its own (emu.sh network name) or the model's.
deck_name() {
    local n; n=$(cat "$STATE/network-name" 2>/dev/null || :)
    [ -n "$n" ] || n=$(model_get "$PRODUCT" hostname)
    printf '%s\n' "${n:-$PRODUCT}"
}

# This machine's addresses on its networks: where other devices reach the deck.
lan_addresses() {
    ip -4 -o addr show scope global 2>/dev/null | awk -v d="$NET_HOST_IF" '$2 != d && $2 !~ /^(docker|br-|veth|virbr|cni|flannel)/ {split($4, a, "/"); printf "%s ", a[1]}' | sed 's/ $//'
}

link_up() {
    # $1 = 1 when the deck is started stock: then it's Engine as inMusic ships it, with no Pro DJ
    # Link (that's EngineX's)
    link_on || return 0
    local prolink=""
    [ "${1:-0}" = 0 ] && [ -x "$R/data/enginex/bundle/bin/rb-bridge" ] && prolink=--prolink
    # shellcheck disable=SC2086  # $prolink is one word or none
    python3 "$ENGINE/linkbridge.py" --deck-ip "$NET_DECK_IP" --deck-if "$NET_HOST_IF" --netns "$NETNS" \
        --exclude "$CONSOLE_PORT" "$VIEW_PORT" $prolink </dev/null > "$STATE/linkbridge.log" 2>&1 &
    echo $! > "$STATE/linkbridge.pid"
}

cmd_network() {
    case "${1:-status}" in
        status|"")
            if [ "$EMU_NET" != 1 ]; then say "networking is off (EMU_NET=0)"; return; fi
            say "deck name: $(deck_name)"
            if link_on; then say "on your network: yes, at $(lan_addresses | tr ' ' ',')"
            else say "on your network: no (internet only; ./emu.sh network on)"; fi
            [ -z "$(deck_ip)" ] || say "deck's own address: $(deck_ip) (behind this computer)"
            if [ -f "$STATE/linkbridge.log" ] && running; then grep -v '^linkbridge: bridging' "$STATE/linkbridge.log" | tail -n 12 | sed 's/^linkbridge: /  /'; fi ;;
        on|local)
            need_root
            { grep -v '^LINK=' "$DATA/network.conf" 2>/dev/null || :; echo "LINK=$([ "$1" = on ] && echo on || echo off)"; } > "$DATA/network.conf.tmp"
            mv "$DATA/network.conf.tmp" "$DATA/network.conf"
            say "$([ "$1" = on ] && echo 'decks are visible on your network' || echo 'decks stay on this computer (internet only)')$(running && echo '; restart the deck (reboot) for it to take effect')" ;;
        name)
            local n=${2:-}
            [ -n "$n" ] || { deck_name; return; }
            case "$n" in *[!A-Za-z0-9_-]*) die "network names are letters, digits, - and _" ;; esac
            [ ${#n} -le 32 ] || die "network names are at most 32 characters"
            need_root; mkdir -p "$STATE"; printf '%s\n' "$n" > "$STATE/network-name"
            say "this deck is $n on the network$(running && echo '; restart Engine (./emu.sh restart) for it to take effect')" ;;
        *) die "usage: ./emu.sh network [status] | on | local | name [NAME]" ;;
    esac
}
