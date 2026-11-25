#!/bin/bash
# The watch apps CMFX installs from its Apps page: the newest cmf-watch-sdk release with an `apps.json` asset
# (scripts/release-apps there), put in the app as App/WatchApps/<crate>.wp2app with apps.json listing them.
# CMFX_APPS=dir uses local builds (apps.json and the packages) instead; CMFX_APPS_REPO picks another repository.
set -euo pipefail
cd "$(dirname "$0")"
repo=${CMFX_APPS_REPO:-InukaAsith/cmf-watch-sdk}
out=App/WatchApps
rm -rf "$out"
mkdir -p "$out"
if [ -n "${CMFX_APPS:-}" ]; then
    cp "$CMFX_APPS"/apps.json "$CMFX_APPS"/*.wp2app "$out/"
else
    auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    rel=$(curl -fsSL ${auth[@]+"${auth[@]}"} "https://api.github.com/repos/$repo/releases?per_page=50")
    # the newest (by when it was published: the API's own order isn't by date) release, drafts and pre-releases
    # aside, carrying apps.json; every asset of it
    python3 -c '
import json, sys
for r in sorted(json.load(sys.stdin), key=lambda r: r.get("published_at") or "", reverse=True):
    if r["draft"] or r["prerelease"]: continue
    names = [a["name"] for a in r["assets"]]
    if "apps.json" not in names: continue
    print(r["tag_name"])
    for a in r["assets"]:
        if a["name"] == "apps.json" or a["name"].endswith(".wp2app"): print(a["name"], a["browser_download_url"])
    sys.exit()
sys.exit("no release with apps.json in '"$repo"'")' <<<"$rel" > "$out/.list"
    tag=$(head -1 "$out/.list")
    tail -n +2 "$out/.list" | while read -r name url; do curl -fsSL -o "$out/$name" "$url"; done
    rm "$out/.list"
    echo "Watch apps: $tag"
fi
# each listed package is there and is an app (kind 0) with a good header
python3 - "$out" <<'PY'
import json, os, struct, sys, zlib
d = sys.argv[1]
for a in json.load(open(os.path.join(d, "apps.json"))):
    b = open(os.path.join(d, a["file"]), "rb").read()
    assert b[:4] == b"WP2A" and b[6] == 0, f"{a['file']}: not an app package"
    assert zlib.crc32(b[:0x34]) == struct.unpack_from("<I", b, 0x34)[0], f"{a['file']}: bad header CRC"
    print(f"  {a['name']} v{struct.unpack_from('<I', b, 32)[0]}")
PY
