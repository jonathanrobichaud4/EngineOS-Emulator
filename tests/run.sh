#!/bin/bash
# Every check that doesn't need a firmware file. CI runs it (.github/workflows/tests.yml); run it
# yourself with: sudo tests/run.sh   (some engine tests need root, as emu.sh does)
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
step() { printf '\n== %s\n' "$1"; }
bad() { echo "FAILED: $1"; fail=1; }

step "shell scripts parse"
for f in engine/emu.sh engine/lib/*.sh emu.sh apps/mac/engineos-emu apps/windows/build.sh apps/mac/app/build.sh; do
    bash -n "$f" || bad "$f"
done
if command -v shellcheck >/dev/null; then
    shellcheck -S error engine/emu.sh engine/lib/*.sh apps/mac/engineos-emu || bad "shellcheck"
fi

step "generated files are current"
python3 models/gen/make_panel_jp21.py >/dev/null && python3 models/gen/make_panel_p4.py >/dev/null || bad "panel generators"
git -c safe.directory="$PWD" diff --quiet -- models/*/panel.json || { git -c safe.directory="$PWD" diff --stat -- models/*/panel.json; bad "models/*/panel.json differ from models/gen (commit the regenerated files)"; }
python3 models/models.py header | cmp -s - engine/shim/models.h || bad "engine/shim/models.h is stale: make -C engine/shim"
(cd engine/shim && sha256sum -c --quiet SOURCES.sha256) || bad "engine/shim/libemushim.so wasn't rebuilt after its sources changed: make -C engine/shim"

step "the page's scripts parse"
if command -v node >/dev/null; then
    for f in viewer/web/*.js; do node -e "new Function(require('fs').readFileSync('$f','utf8'))" || bad "$f"; done
else echo "(node isn't installed; skipped)"; fi

step "python tests"
(cd tests && python3 -m unittest -v 2>&1) || bad "python tests"

[ $fail = 0 ] && printf '\nall good\n' || printf '\nsome checks failed\n'
exit $fail
