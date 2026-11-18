#!/bin/bash
# Double-click in Finder: starts the emulator and opens the deck in your browser.
# (First time: macOS may ask whether to open it; right-click > Open, then Open.)
cd "$(dirname "$0")" || exit 1
echo "Starting the SC LIVE 4 emulator..."
if ! ./sclive4-emu start; then
    echo
    echo "It didn't start. If you haven't set the deck up yet, run these in Terminal:"
    echo "  $(pwd)/sclive4-emu install"
    echo "  $(pwd)/sclive4-emu setup ~/Downloads/<SC LIVE 4 firmware file>"
fi
echo
echo "The deck keeps running when you close this window."
echo "To stop it: $(pwd)/sclive4-emu stop"
read -r -p "Press Return to close." _
