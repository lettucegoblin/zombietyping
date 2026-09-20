#!/bin/zsh
# Run a headless Godot scene/script with a time cap (macOS has no `timeout`).
#   tools/gd.sh <seconds> <godot args...>
G=/Users/lettuce/Documents/Godot.app/Contents/MacOS/Godot
secs=$1; shift
cd /Users/lettuce/zombietyping
"$G" --headless --path . "$@" 2>&1 &
pid=$!
( sleep $secs; kill $pid 2>/dev/null ) &
wpid=$!
wait $pid
code=$?
kill $wpid 2>/dev/null
exit $code
