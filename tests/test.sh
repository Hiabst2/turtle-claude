#!/bin/sh
# Syntaxpruefung aller Programme und Tests ausserhalb von Minecraft (braucht lua5.2)
cd "$(dirname "$0")/.." || exit 1
status=0
for f in $(find . -name '*.lua' -not -path './.git/*'); do
  luac5.2 -p "$f" || status=1
done
lua5.2 tests/run.lua || status=1
rm -f luac.out
exit $status
