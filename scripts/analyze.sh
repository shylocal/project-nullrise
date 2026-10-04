#!/usr/bin/env sh
# Static type/lint check for the whole project (no Studio needed).
# Requires the aftman tools (rojo, luau-lsp, selene) and Wally. Fetches Roblox
# type definitions into .luau/ and installs Wally packages on first run.
set -e
cd "$(dirname "$0")/.."
TOOLS="${AFTMAN_BIN:-$HOME/.aftman/bin}"
WALLY="${WALLY:-$HOME/.rokit/bin/wally}"
if [ ! -d Packages ] || [ ! -d DevPackages ]; then
	"$WALLY" install
fi
if [ ! -f .luau/globalTypes.d.luau ]; then
	curl -sSfL -o .luau/globalTypes.d.luau \
		https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
fi
"$TOOLS/rojo" sourcemap default.project.json -o sourcemap.json >/dev/null

status=0
"$TOOLS/luau-lsp" analyze \
	--platform=roblox \
	--sourcemap=sourcemap.json \
	--defs=.luau/globalTypes.d.luau \
	--defs=.luau/testez.d.luau \
	--ignore="**/src/packages/**" \
	--ignore="**/src/server/vendor/**" \
	--ignore="**/Packages/**" \
	--ignore="**/DevPackages/**" \
	src tests || status=1

# selene runs once selene.toml exists. Its Roblox standard library (roblox.yml)
# is generated locally on first run and is not committed. Errors fail the
# script; warnings are printed and must still be fixed in the files you own.
if [ -f selene.toml ]; then
	if [ ! -f roblox.yml ]; then
		"$TOOLS/selene" generate-roblox-std >/dev/null
	fi
	"$TOOLS/selene" --allow-warnings --display-style=quiet src tests || status=1
fi

exit $status
