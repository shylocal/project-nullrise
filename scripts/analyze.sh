#!/usr/bin/env sh
# Static type/lint check for the whole project (no Studio needed).
# Requires the aftman tools (rojo, luau-lsp). Fetches Roblox type definitions
# into .luau/ on first run.
set -e
cd "$(dirname "$0")/.."
TOOLS="${AFTMAN_BIN:-$HOME/.aftman/bin}"
if [ ! -f .luau/globalTypes.d.luau ]; then
	curl -sSfL -o .luau/globalTypes.d.luau \
		https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
fi
"$TOOLS/rojo" sourcemap default.project.json -o sourcemap.json >/dev/null
"$TOOLS/luau-lsp" analyze \
	--platform=roblox \
	--sourcemap=sourcemap.json \
	--defs=.luau/globalTypes.d.luau \
	--defs=.luau/testez.d.luau \
	--ignore="**/src/packages/**" \
	--ignore="**/src/server/vendor/**" \
	--ignore="**/tests/TestEZ/**" \
	src tests
