"""Import a PixelLab character bundle (zip) into the game's sprite folder.

usage: python3 tools/import_character.py <bundle.zip> <type_name> [palette.png] [state_folder] [--map src=dst ...]
state_folder picks one state out of a multi-state bundle (e.g. Idle_Grin); default = first state.
--map death_floor=death imports the bundle's "death_floor" animation under the game's name "death"
(and drops the bundle's own "death"). --nudge death=4 shifts that animation up 4 px (feet line fix). Frames are padded onto one common canvas, centred, so the
feet line stays put when one animation came back on a bigger canvas.
Writes assets/sprites/zombie/<type_name>/<anim>/<dir>_<frame>.png and frames.json:
  {"size": [w,h], "anims": {"idle": {"south": ["idle/south_0.png", ...], ...}, "run": {...}}}
If a palette PNG is given, every frame is quantized onto it (nearest colour, alpha kept).
"""
import sys, os, json, zipfile, shutil
from PIL import Image

args = [a for a in sys.argv[1:] if not a.startswith("--")]
rename = {}
argv = sys.argv[1:]
nudge = {}   # game anim name -> pixels to shift up (+) at import
for i, a in enumerate(argv):
    if a == "--map":
        src, dst = argv[i + 1].split("=")
        rename[src] = dst
        args.remove(argv[i + 1])
    if a == "--nudge":
        name, dy = argv[i + 1].split("=")
        nudge[name] = int(dy)
        args.remove(argv[i + 1])
bundle, tname = args[0], args[1]
palette_png = args[2] if len(args) > 2 and args[2] != "-" else None
state_pick = args[3] if len(args) > 3 else None
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sprites", "zombie", tname)
tmp = os.path.join("/tmp", "pixellab_bundle_" + tname)
shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp)
with zipfile.ZipFile(bundle) as z: z.extractall(tmp)
meta = json.load(open(os.path.join(tmp, "metadata.json")))

pal = None
if palette_png:
    pim = Image.open(palette_png).convert("RGB")
    pal = sorted(set(pim.getdata()))
def quant(im):
    if pal is None: return im
    im = im.convert("RGBA"); px = im.load()
    cache = {}
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a < 128: px[x, y] = (0, 0, 0, 0); continue
            key = (r, g, b)
            if key not in cache:
                cache[key] = min(pal, key=lambda p: (p[0]-r)**2*0.9 + (p[1]-g)**2*1.2 + (p[2]-b)**2*0.7)
            px[x, y] = cache[key] + (255,)
    return im

shutil.rmtree(root, ignore_errors=True)
os.makedirs(root, exist_ok=True)
manifest = {"size": None, "anims": {}}
states = meta["states"]
if state_pick:
    states = [st for st in states if st["folder"] == state_pick]
    assert states, "state folder not found: " + state_pick
else:
    states = states[:1]

# pass 1: collect (game_name, direction, [rel paths])
plan = []   # (name, dir, [rel])
for state in states:
    frames = state["frames"]
    rot = frames.get("rotations", {})
    for d, rel in rot.items():
        plan.append(("idle", d, [rel]))
    anims_meta = frames.get("animations", {})
    items = anims_meta.items() if isinstance(anims_meta, dict) else [((a.get("display_name") or a.get("name") or "anim"), a.get("directions", {})) for a in anims_meta]
    names = {}
    for name, dirs in items:
        names[name.lower().replace(" ", "_")] = dirs
    for src, dst in rename.items():
        if src in names:
            names[dst] = names.pop(src)
    for name, dirs in names.items():
        for d, rels in dirs.items():
            plan.append((name, d, list(rels)))

# common canvas: the largest frame, everything else centred on it (keeps the feet line)
W = H = 0
for _, _, rels in plan:
    for rel in rels:
        with Image.open(os.path.join(tmp, rel)) as im:
            W, H = max(W, im.width), max(H, im.height)
def pad(im):
    if im.size == (W, H): return im
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    out.paste(im, ((W - im.width) // 2, (H - im.height) // 2), im)
    return out

for name, d, rels in plan:
    manifest["anims"].setdefault(name, {})
    os.makedirs(os.path.join(root, name), exist_ok=True)
    paths = []
    for i, rel in enumerate(rels):
        im = quant(pad(Image.open(os.path.join(tmp, rel)).convert("RGBA")))
        if nudge.get(name, 0):
            moved = Image.new("RGBA", im.size, (0, 0, 0, 0))
            moved.paste(im, (0, -nudge[name]), im)
            im = moved
        out = f"{name}/{d}_{i}.png"; im.save(os.path.join(root, out)); paths.append(out)
    manifest["anims"][name][d] = paths
manifest["size"] = [W, H]
json.dump(manifest, open(os.path.join(root, "frames.json"), "w"), indent=1)
print("imported", tname, "->", {k: len(v) for k, v in manifest["anims"].items()}, "size", manifest["size"])
