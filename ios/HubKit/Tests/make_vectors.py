"""HubKit's test vectors, from the Python hosts that drive the watch apps in cmf-watch-sdk (the reference).

  uv run --with pillow python Tests/make_vectors.py ../../../cmf-watch-sdk > Tests/HubKitTests/vectors.json
"""
import json, random, struct, sys, pathlib

sdk = pathlib.Path(sys.argv[1]).resolve()
sys.path.insert(0, str(sdk / "hosts"))
sys.path.insert(0, str(sdk / "src"))
import mapbuild, spotihost, pixhost  # noqa: E402
import math  # noqa: E402
from wp2apps import adpcm, play, tune  # noqa: E402

random.seed(7)
w, h = 40, 6
px = [random.choice([0, 0, 0, 3, 3, 15]) for _ in range(w * h)]
px[:20] = [5] * 20
long_row = [2] * 300
hdr = b"I" + struct.pack("<HHBhh", 152, 152, 1, 0, 0) + b"".join(struct.pack("<H", i * 0x1111) for i in range(16))
st = {"flags": 3, "pos": 83, "dur": 215, "vol": 60, "title": "Midnight City é", "artist": "M83", "device": "iPhone"}
idx = bytearray(b"WMP1") + bytes([1])
for c in mapbuild.PALETTE:
    idx += struct.pack("<H", pixhost.rgb565(*c))
idx += struct.pack("<BIIBBI", 15, 16370, 10896, 3, 4, 2990)
cx, cy = pixhost.world(51.508, -0.1281, 20)
idx += struct.pack("<II", int(cx), int(cy))
# the Music app's speaker stream (wp2apps play/tune/adpcm): a 6000-sample mix of bass, mids and noise at 10.67 kHz
rng = random.Random(11)
sig = [int(9000 * math.sin(2 * math.pi * 110 * i / 10667) + 5000 * math.sin(2 * math.pi * 1300 * i / 10667)
           + 2500 * math.sin(2 * math.pi * 3500 * i / 10667) + rng.randint(-1500, 1500)) for i in range(6000)]
tuned = tune.for_speaker(sig, 10667)
# the options: loudness levelling and the trellis encoder on ("enhance"), volume smoothing off
from wp2apps import adpcm  # noqa: E402
tuned_x = tune.for_speaker(sig, 10667, level=1, smooth=0)
print(json.dumps({
    "speaker_x": {"in": sig, "tuned": tuned_x,
                  "blocks": [m.hex() for m in play.messages(tuned_x + [0] * (10667 * 2 // 5), adpcm.Encoder(play.PATHS))]},
    "speaker": {"in": sig, "tuned": tuned, "blocks": [m.hex() for m in play.messages(tuned + [0] * (10667 * 2 // 5))]},
    "tokens": {"w": w, "h": h, "px": px, "out": mapbuild.tokens(bytes(px), w, h).hex()},
    "long": {"w": 300, "h": 1, "px": long_row, "out": mapbuild.tokens(bytes(long_row), 300, 1).hex()},
    "rgb565": [[0xD7, 0x19, 0x21, pixhost.rgb565(0xD7, 0x19, 0x21)], [255, 255, 255, pixhost.rgb565(255, 255, 255)]],
    "header": hdr.hex(),
    "now": spotihost.now_message(st).hex(),
    "list": [m.hex() for m in spotihost.list_messages(b"P", [("Chill", "42 songs", True), ("Gym", "2 songs", False)])],
    "palette": [pixhost.rgb565(*c) for c in mapbuild.PALETTE],
    "idx": {"z": 15, "x0": 16370, "y0": 10896, "w": 3, "h": 4, "mm": 2990, "lat": 51.508, "lon": -0.1281,
            "out": bytes(idx).hex()},
    "world": [51.508, -0.1281, 16, *pixhost.world(51.508, -0.1281, 16)],
}, indent=1))
