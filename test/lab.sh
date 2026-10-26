#!/usr/bin/env bash
# What the compose file's header says, checked from inside the lab's own network and through
# docker exec, which is how the platform's terminal reaches the lab's Python: run by check.sh.
set -euo pipefail
: "${NET:?run through test/check.sh}"
: "${CID:?run through test/check.sh}"
probe() { docker run --rm --network "$NET" lab-check-probe bash -c "$1"; }
run() { docker exec "$CID" "$@"; }
has() { grep -Eq "$1" <<<"$2" || { echo "no match for '$1' in: $2" >&2; exit 1; }; }

echo "- JupyterLab answers with no token, and the Preview serves app/ on 8000"
probe '
set -eu
code=$(curl -s -o /dev/null -w "%{http_code}" http://jupyter:8888/lab)
[ "$code" = 200 ] || { echo "JupyterLab answered $code" >&2; exit 1; }
curl -fs http://jupyter:8888/api/contents | grep -q "start.ipynb" || { echo "no start.ipynb" >&2; exit 1; }
curl -fs -H "Host: someone-8888.example.com" -H "Origin: https://someone-8888.example.com" \
  http://jupyter:8888/api/kernelspecs | grep -q python3 || { echo "a proxied host is refused" >&2; exit 1; }
curl -fs http://jupyter:8000/ | grep -q "<title>Habit tracker</title>" || { echo "the preview is not the app" >&2; exit 1; }
curl -fs http://jupyter:8000/style.css | grep -q "@media (min-width: 600px)" || { echo "no style.css" >&2; exit 1; }
curl -fs http://jupyter:8000/app.js | grep -q "localStorage" || { echo "no app.js" >&2; exit 1; }
curl -fs http://jupyter:8000/manifest.webmanifest | grep -q "Habit tracker" || { echo "no manifest" >&2; exit 1; }
curl -fs http://jupyter:8000/sw.js | grep -q "habits-v1" || { echo "no sw.js" >&2; exit 1; }
[ "$(curl -fs http://jupyter:8000/icon-192.png | head -c 4 | od -An -tx1 | tr -d " \n")" = 89504e47 ] || { echo "icon is not a PNG" >&2; exit 1; }
echo "- no way out to the internet"
if curl -s -m 4 -o /dev/null https://example.com; then echo "the lab reached the internet" >&2; exit 1; fi
'

echo "- the work folder holds the app, the notebook and the step scripts"
run ls app/index.html app/style.css app/app.js app/manifest.webmanifest app/sw.js app/icon-192.png app/icon-512.png \
  start.ipynb steps/viewport.py steps/breakpoints.py steps/touch.py steps/manifest.py steps/offline.py steps/serve.py >/dev/null
for size in 192 512; do
  run python3 -c "
import struct, sys
d = open('app/icon-$size.png', 'rb').read()
sys.exit(0 if d[:8] == bytes([137, 80, 78, 71, 13, 10, 26, 10]) and struct.unpack('>II', d[16:24]) == ($size, $size) else 1)" \
    || { echo "icon-$size.png is not a $size pixel PNG" >&2; exit 1; }
done

echo "- viewport.py: the tag is found and says width=device-width"
out=$(run python3 steps/viewport.py)
has "^viewport meta tag: found$" "$out"
has "^content: width=device-width, initial-scale=1$" "$out"
has "^width=device-width in it: True$" "$out"

echo "- breakpoints.py: three media queries, 600 px and 900 px, and a preference"
out=$(run python3 steps/breakpoints.py)
has "^media queries: 3$" "$out"
has "^\(min-width: 600px\) -> width 600 px$" "$out"
has "^\(min-width: 900px\) -> width 900 px$" "$out"
has "^\(prefers-color-scheme: dark\) -> not a width, a preference$" "$out"

echo "- touch.py: four sizes under 44 px, the ones the task is to fix"
out=$(run python3 steps/touch.py)
has "^\.add +height +32 px UNDER 44$" "$out"
has "^\.filter +min-height +36 px UNDER 44$" "$out"
has "^\.done-button +width +30 px UNDER 44$" "$out"
has "^\.done-button +height +30 px UNDER 44$" "$out"
has "^under 44 px: 4$" "$out"

echo "- manifest.py: everything present but background_color"
out=$(run python3 steps/manifest.py)
for key in name short_name start_url display icons theme_color; do has "^$key +present$" "$out"; done
has "^background_color +MISSING$" "$out"
has "^display is standalone$" "$out"
has "^icon icon-192\.png 192x192 file exists: True$" "$out"
has "^icon icon-512\.png 512x512 file exists: True$" "$out"

echo "- offline.py: eight files to cache, and offline.html is not there"
out=$(run python3 steps/offline.py)
has "^cache name: habits-v1$" "$out"
has "^files to cache: 8$" "$out"
has "^/offline\.html +MISSING$" "$out"
has "^missing: 1$" "$out"

echo "- serve.py: the preview answers for the page, the manifest and the worker"
out=$(run python3 steps/serve.py)
has "^/ +200 text/html$" "$out"
has "^/manifest\.webmanifest +200 application/manifest\+json$" "$out"
has "^/sw\.js +200 " "$out"

echo "- a change saved to app/ shows in the Preview and in touch.py"
run sed -i 's/\.add { height: 32px;/.add { height: 48px;/' app/style.css
probe 'curl -fs http://jupyter:8000/style.css | grep -q "height: 48px" || { echo "the preview did not change" >&2; exit 1; }'
run python3 steps/touch.py | grep -q "^under 44 px: 3$" || { echo "touch.py did not change" >&2; exit 1; }

echo "- the starter notebook runs from top to bottom inside the memory limit"
run jupyter nbconvert --to notebook --execute start.ipynb --output /tmp/ran.ipynb >/dev/null 2>&1 \
  || { echo "start.ipynb does not run" >&2; exit 1; }
echo "  ok"
