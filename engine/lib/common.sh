# shellcheck shell=bash
# Paths, the selected deck (profile), its model and small helpers. Sourced first by engine/emu.sh.
#
#   ENGINE  this folder's parent (engine/): the code that runs on the Linux side
#   ROOT    the checkout
#   DATA    where the decks (rootfs*/, state*/) and drives.txt live: the checkout too
#           (ignored by git, so updating the code never touches them), or EMU_DATA (the tests
#           use a scratch folder)
#   R       the selected deck's root filesystem, STATE its runtime files

ROOT=$(cd "$ENGINE/.." && pwd)
DATA=${EMU_DATA:-$ROOT}
ASSETS=$ROOT/assets
MODELS=$ROOT/models

# PROFILE (the selected deck; engine/emu.sh reads --profile) has its own rootfs-NAME/ and
# state-NAME/; the default deck uses rootfs/ and state/.
SUFFIX=${PROFILE:+-$PROFILE}
R=${EMU_ROOTFS:-$DATA/rootfs$SUFFIX}
STATE=$DATA/state$SUFFIX
VIEW_PORT=${VIEW_PORT:-8090}
CONSOLE_PORT=${CONSOLE_PORT:-8080}
QEMU=/usr/bin/qemu-arm-static   # replaced by find_qemu() if the distro names it differently

EMU_NET=${EMU_NET:-1}

die() { echo "emu: $*" >&2; exit 1; }
say() { echo "emu: $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "run with sudo"; }

# The models (models/<CODE>/model.json, read by models/models.py): MODEL_CODES and model_<CODE>_*.
# Engine picks its product from the devicetree, which the emulator writes (prepare_rootfs).
if command -v python3 >/dev/null 2>&1 && _models=$(python3 "$MODELS/models.py" shell 2>/dev/null); then
    eval "$_models"
else
    # No Python yet (a bare system before setup installs it): the first model is enough to start.
    MODEL_CODES=JP21; model_JP21_name="SC LIVE 4"; model_JP21_container=AZ0x; model_JP21_default=1; model_JP21_enginex=1
    MODEL_RUNS_AS="the SC LIVE 4 firmware runs as an SC LIVE 4"
fi
model_get() { local v="model_${1}_$2"; printf '%s' "${!v:-}"; }
product_name() { local n; n=$(model_get "$1" name); printf '%s\n' "${n:-$1}"; }
is_model() { case " $MODEL_CODES " in *" $1 "*) return 0 ;; esac; return 1; }
# The model that firmware of this container ("AZ0x", "AZ01") sets a deck up as by default.
default_model_for() { local c; for c in $MODEL_CODES; do [ "$(model_get "$c" container)" = "$1" ] && [ -n "$(model_get "$c" default)" ] && { echo "$c"; return; }; done; }

PRODUCT=$(cat "$STATE/product" 2>/dev/null || :)
is_model "$PRODUCT" || PRODUCT=${MODEL_CODES%% *}

in_root() { chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/data LANG=C.UTF-8 "$@"; }
# Like in_root, but inside the deck's own network namespace when emulated networking is on.
in_deck() {
    if [ -e /run/netns/$NETNS ]; then nsenter --net=/run/netns/$NETNS -- chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/data LANG=C.UTF-8 "$@"
    else in_root "$@"; fi
}

running() { [ -f "$STATE/emu.pid" ] && kill -0 "$(cat "$STATE/emu.pid")" 2>/dev/null; }

# How to run emu.sh again for another deck (the shell that runs it may have no PATH to it).
emu_self() { "$ENGINE/emu.sh" "$@"; }
