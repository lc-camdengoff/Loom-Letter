#!/usr/bin/env bash
# Loom Letter installer for macOS and Linux (per-user install).
#
#   ./install.sh               install / update
#   ./install.sh --uninstall   remove Loom Letter (keeps your log file)
#
# Set LOOMLETTER_FUSION_DIR to install somewhere else (e.g. a system-wide Fusion folder).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/Fusion"

if [[ -n "${LOOMLETTER_FUSION_DIR:-}" ]]; then
	fusion="$LOOMLETTER_FUSION_DIR"
else
	case "$(uname -s)" in
		Darwin) fusion="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion" ;;
		Linux) fusion="$HOME/.local/share/DaVinciResolve/Fusion" ;;
		*)
			echo "Unsupported system $(uname -s). On Windows run install.ps1 instead." >&2
			exit 1
			;;
	esac
fi

script="$fusion/Scripts/Utility/Loom Letter.lua"
titles="$fusion/Templates/Edit/Titles/Loom Letter"
previews="$fusion/LoomLetter/previews"

if [[ "${1:-}" == "--uninstall" ]]; then
	rm -f "$script"
	rm -rf "$titles" "$previews"
	echo "Loom Letter removed from $fusion"
	echo "(logs are kept in $fusion/LoomLetter/logs)"
	echo "Restart DaVinci Resolve to finish."
	exit 0
fi

if [[ ! -d "$src" ]]; then
	echo "Can't find $src - run this script from the Loom Letter folder." >&2
	exit 1
fi

mkdir -p "$(dirname "$script")" "$titles" "$previews" "$fusion/LoomLetter/logs"
cp "$src/Scripts/Utility/Loom Letter.lua" "$script"
# replace the template folder so renamed/removed presets don't linger
rm -f "$titles"/*.setting
cp "$src/Templates/Edit/Titles/Loom Letter/"*.setting "$titles/"
cp "$src/LoomLetter/previews/"*.png "$previews/"

count=$(find "$titles" -name '*.setting' | wc -l | tr -d ' ')
echo "Loom Letter installed to $fusion"
echo "  panel:   Scripts/Utility/Loom Letter.lua"
echo "  titles:  $count templates in Templates/Edit/Titles/Loom Letter"
echo
echo "Restart DaVinci Resolve, then open Workspace > Scripts > Loom Letter."
