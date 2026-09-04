#!/usr/bin/env bash
# Offline / CI conversion of ABP-syntax filter lists into Apple WebKit
# content-blocker JSON, using Brave's adblock-rust.
#
# The Rust engine is deliberately NOT linked into the iOS app: this runs at
# build time and the app only ever consumes the generated JSON.
#
# Requires a Rust toolchain. The adblock version is pinned in
# tools/filter-convert/Cargo.toml; re-pin deliberately, because the
# content-blocking API has moved between releases.
#
# Output is raw-DEFLATE compressed (*.json.deflate) because 14MB of JSON in the
# app bundle is 14MB the user downloads. RuleData.load inflates it, and only on
# a cache miss.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${root}/build/filters"
out="${root}/ios/App/CleanPlayerApp/Resources/rules"
mkdir -p "$work" "$out"

fetch() { # name url
  echo "==> fetching $1"
  curl --fail --silent --show-error --location \
       --max-time 60 --max-filesize 12000000 \
       -o "${work}/$1.txt" "$2"
}

fetch easylist       https://easylist.to/easylist/easylist.txt
fetch easyprivacy    https://easylist.to/easylist/easyprivacy.txt
# Fanboy's Annoyance already contains the Cookie and Social lists, so those are
# not fetched separately — it would be the same rules twice.
fetch annoyances     https://easylist.to/easylist/fanboy-annoyance.txt
# Brave's compatibility exceptions. Note the repo ROOT, not brave-lists/ —
# the copy in that subdirectory is a stub.
fetch braveunbreak   https://raw.githubusercontent.com/brave/adblock-lists/master/brave-unbreak.txt

# The unbreak list goes into EVERY output, last. WebKit applies
# ignore-previous-rules only within the compiled list that holds it, so a
# separate "unbreak" rule list would cancel nothing. Its exceptions have to be
# parsed alongside the rules they undo.
echo "==> converting"
cargo run --release --manifest-path "${root}/tools/filter-convert/Cargo.toml" -- \
  --input "${work}/easylist.txt"     --input "${work}/braveunbreak.txt" \
    --output "${out}/ads.json" \
  --input "${work}/easyprivacy.txt"  --input "${work}/braveunbreak.txt" \
    --output "${out}/privacy.json" \
  --input "${work}/annoyances.txt"   --input "${work}/braveunbreak.txt" \
    --output "${out}/annoyances.json"

echo "==> compressing + manifest"
python3 - "$work" "$out" <<'PY'
import hashlib, json, pathlib, subprocess, sys, datetime, zlib
work, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

def compress(path):
    """Raw DEFLATE (wbits=-15) — what NSData.decompressed(using: .zlib) wants.
    A zlib or gzip wrapper decodes to nothing on the device."""
    raw = path.read_bytes()
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    blob = c.compress(raw) + c.flush()
    assert zlib.decompress(blob, -15) == raw, f"{path.name} round-trip failed"
    path.with_suffix(path.suffix + ".deflate").write_bytes(blob)
    path.unlink()
    return len(raw), len(blob)

def version(p):
    for line in p.read_text(errors="replace").splitlines()[:40]:
        s = line.strip()
        if s.startswith("!") and "version:" in s.lower():
            return s.split(":", 1)[1].strip()
    return "unknown"

manifest = {
    "convertedAt": datetime.datetime.now(datetime.UTC).isoformat(),
    "converter": subprocess.run(["cargo", "--version"], capture_output=True,
                                text=True).stdout.strip(),
    "sources": {},
}
for name, generated in (("easylist", "ads.json"),
                        ("easyprivacy", "privacy.json"),
                        ("annoyances", "annoyances.json")):
    src, gen = work / f"{name}.txt", out / generated
    rules = json.loads(gen.read_text())
    # Hash the JSON, not the compressed blob: the hash keys WebKit's compiled
    # cache, and what it compiles is the JSON.
    digest = hashlib.sha256(gen.read_bytes()).hexdigest()
    plain, packed = compress(gen)
    manifest["sources"][name] = {
        "version": version(src),
        "sourceSha256": hashlib.sha256(src.read_bytes()).hexdigest(),
        "generated": generated,
        "ruleCount": len(rules),
        "generatedSha256": digest,
        "bytes": plain,
        "compressedBytes": packed,
    }
(out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest["sources"], indent=2))
PY

echo "==> done. Review ${out}/manifest.json before committing."
