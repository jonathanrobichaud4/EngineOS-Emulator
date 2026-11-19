#!/bin/bash
# The emulator's command line lives in engine/emu.sh; this keeps `./emu.sh ...` working from the
# top of the checkout, as it always has (and for apps from before the move).
cmd_info() { :; }  # older Windows apps look for this line to tell a current emulator from an old one
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/engine/emu.sh" "$@"
