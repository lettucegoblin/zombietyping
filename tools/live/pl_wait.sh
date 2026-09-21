#!/bin/zsh
# wait until the character bundle is downloadable (all jobs done), then unzip into $2
CID=$1; OUT=$2; mkdir -p "$OUT"
for i in $(seq 1 60); do
  code=$(curl -sL -o "$OUT/bundle.zip" "https://api.pixellab.ai/mcp/characters/$CID/download" -w "%{http_code}")
  if [ "$code" = "200" ]; then echo "bundle ready after $((i*10))s"; cd "$OUT" && rm -rf Idle Idle_Standing Idle_Grin metadata.json && unzip -qo bundle.zip && python3 -c "
import json; m=json.load(open('metadata.json'))
for st in m['states']:
    an=st['frames'].get('animations',{}); print(st['folder'], {k:(len(v), len(list(v.values())[0])) for k,v in an.items()})"; exit 0; fi
  sleep 10
done
echo "timed out"; exit 1
