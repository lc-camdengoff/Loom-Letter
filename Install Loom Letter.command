#!/bin/bash
# Double-click this file in Finder to install Loom Letter (macOS).
cd "$(dirname "$0")" || exit 1
bash ./install.sh "$@"
status=$?
echo
if [ $status -eq 0 ]; then echo "Done - you can close this window."; else echo "Install failed (exit $status). Copy the text above and send it along."; fi
read -r -p "Press Return to close..." _
exit $status
