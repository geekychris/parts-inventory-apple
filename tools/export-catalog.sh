#!/bin/sh
# Copy the built-in parts list and the look labels from the web tool (geekychris-site), so both
# versions recognise the same parts. Rerun tools/make-clip-embeddings.py afterwards if the looks changed.
set -e
SITE=${1:-../geekychris-site}
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$SITE/site/static/tools"
node -e '
const fs = require("fs"); const P = require("./parts-identify-core.js");
const [res, tools] = process.argv.slice(1);
fs.writeFileSync(res + "/catalog.json", JSON.stringify({ source: "geekychris-site parts-identify-core.js", catalog: P.CATALOG, generic: P.GENERIC, boardish: P.BOARDISH }, null, 1));
const s = P.clipStages();
fs.writeFileSync(tools + "/clip-labels.json", JSON.stringify({ template: "a photo of {}.", kinds: s.kinds, boards: s.boards }, null, 1));
' "$HERE/PartsKit/Sources/PartsKit/Resources" "$HERE/tools"
echo "catalog.json and clip-labels.json updated"
