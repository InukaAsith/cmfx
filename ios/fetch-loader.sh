#!/bin/bash
# The App Loader CMFX installs: the newest cmf-watch-sdk release with a `loader.wp2app` asset (scripts/release-loader
# there, or its FMC release workflow), put in the app as App/Loader/loader.wp2app with loader.json naming the release.
# CMFX_LOADER=path/to/loader.wp2app uses a local build instead; CMFX_LOADER_REPO picks another repository.
set -euo pipefail
cd "$(dirname "$0")"
repo=${CMFX_LOADER_REPO:-InukaAsith/cmf-watch-sdk}
out=App/Loader
mkdir -p "$out"
if [ -n "${CMFX_LOADER:-}" ]; then
    cp "$CMFX_LOADER" "$out/loader.wp2app"
    printf '{"tag":"local build"}\n' > "$out/loader.json"
else
    auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    rel=$(curl -fsSL ${auth[@]+"${auth[@]}"} "https://api.github.com/repos/$repo/releases?per_page=50")
    # newest first: the first release (drafts and pre-releases aside) carrying loader.wp2app
    read -r tag published commit url < <(python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r["draft"] or r["prerelease"]: continue
    for a in r["assets"]:
        if a["name"] == "loader.wp2app":
            print(r["tag_name"], r["published_at"][:10], r["target_commitish"], a["browser_download_url"]); sys.exit()
sys.exit("no release with loader.wp2app in '"$repo"'")' <<<"$rel")
    curl -fsSL -o "$out/loader.wp2app" "$url"
    printf '{"tag":"%s","published":"%s","commit":"%s"}\n' "$tag" "$published" "$commit" > "$out/loader.json"
fi
# a package, else the app would offer junk as an update
python3 - "$out/loader.wp2app" <<'PY'
import struct, sys, zlib
d = open(sys.argv[1], "rb").read()
assert d[:4] == b"WP2A" and d[6] == 1, "not a loader package"
assert zlib.crc32(d[:0x34]) == struct.unpack_from("<I", d, 0x34)[0], "bad header CRC"
name = d[8:32].split(b"\0")[0].decode()
print(f"App Loader: {name} v{struct.unpack_from('<I', d, 32)[0]} crc {struct.unpack_from('<I', d, 48)[0]:08x}")
PY
cat "$out/loader.json"
