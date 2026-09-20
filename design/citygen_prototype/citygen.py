"""Prototype: hierarchical district-grid city generator -> street graph + lots + SVG.
Layers: districts -> arterials -> district-local grids -> pruning/cul-de-sacs -> blocks -> lots -> buildings.
"""
import random, sys, math
from collections import deque

SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 7
rng = random.Random(SEED)
W, H = 56, 36

# ---- 1. districts ---------------------------------------------------------
DIST = {  # letter: (kind, grid spacing, drop-prob, lot size, tint, label)
    'A': ('downtown',    4, 0.05, 2, '#c9b6e8', 'Downtown'),
    'B': ('residential', 7, 0.35, 3, '#bfe3c2', 'Residential'),
    'C': ('residential', 7, 0.40, 3, '#c6e8d8', 'Residential'),
    'D': ('industrial',  9, 0.30, 4, '#e8d5b0', 'Industrial'),
    'E': ('strip',       6, 0.20, 3, '#f2c9c9', 'Commercial strip'),
    'F': ('park',        0, 0.00, 0, '#a9d68f', 'Park'),
}
seeds = {
    'A': (W*0.50, H*0.50), 'B': (W*0.18, H*0.25), 'C': (W*0.80, H*0.72),
    'D': (W*0.82, H*0.20), 'E': (W*0.30, H*0.80), 'F': (W*0.62, H*0.30),
}
weight = {'A': 0.75, 'F': 0.6}  # smaller effective radius
def district_of(x, y):
    best, bd = None, 1e9
    for k, (sx, sy) in seeds.items():
        d = math.hypot(x - sx, y - sy) / weight.get(k, 1.0)
        d += rng.uniform(-2.5, 2.5)          # noisy borders
        if d < bd: best, bd = k, d
    return best
dist = [[district_of(x, y) for x in range(W)] for y in range(H)]
# smooth the noise (majority filter) so districts are blobs, not confetti
for _ in range(2):
    nd = [row[:] for row in dist]
    for y in range(H):
        for x in range(W):
            cnt = {}
            for dy in (-1,0,1):
                for dx in (-1,0,1):
                    xx, yy = x+dx, y+dy
                    if 0 <= xx < W and 0 <= yy < H:
                        cnt[dist[yy][xx]] = cnt.get(dist[yy][xx], 0) + 1
            nd[y][x] = max(cnt, key=cnt.get)
    dist = nd

road = [[0]*W for _ in range(H)]   # 0 none, 1 local, 2 arterial

# ---- 2. arterials: MST over district seeds, L-shaped with a bend ----------
def lay(x0, y0, x1, y1, cls):
    bx = x0 + int((x1 - x0) * rng.uniform(0.3, 0.7))
    for x in range(min(x0,bx), max(x0,bx)+1): road[y0][x] = max(road[y0][x], cls)
    for y in range(min(y0,y1), max(y0,y1)+1): road[y][bx] = max(road[y][bx], cls)
    for x in range(min(bx,x1), max(bx,x1)+1): road[y1][x] = max(road[y1][x], cls)
pts = {k: (int(v[0]), int(v[1])) for k, v in seeds.items()}
inT, edges = {'A'}, []
while len(inT) < len(pts):
    best = min(((math.dist(pts[a], pts[b]), a, b) for a in inT for b in pts if b not in inT))
    edges.append((best[1], best[2])); inT.add(best[2])
for a, b in edges: lay(*pts[a], *pts[b], 2)
# one through-highway along the top-ish edge
hy = int(H*0.08); 
for x in range(W): road[hy][x] = 2
lay(*pts['D'], pts['D'][0], hy, 2)

# ---- 3. district-local grids (each district has its own spacing/offset) ---
offs = {k: (rng.randrange(v[1] or 1), rng.randrange(v[1] or 1)) for k, v in DIST.items()}
for y in range(H):
    for x in range(W):
        k = dist[y][x]; sp = DIST[k][1]
        if sp == 0: continue
        ox, oy = offs[k]
        if (x - ox) % sp == 0 or (y - oy) % sp == 0:
            if road[y][x] == 0: road[y][x] = 1
# no local road may run parallel right next to an arterial
for y in range(H):
    for x in range(W):
        if road[y][x] != 1: continue
        k = dist[y][x]; sp = DIST[k][1]; ox, oy = offs[k]
        on_row = (y - oy) % sp == 0; on_col = (x - ox) % sp == 0
        if on_row and any(0 <= yy < H and road[yy][x] == 2 for yy in (y-1, y+1)): road[y][x] = 0
        elif on_col and any(0 <= xx < W and road[y][xx] == 2 for xx in (x-1, x+1)): road[y][x] = 0
# border cleanup: clear local roads on the outer frame
for y in range(H):
    for x in range(W):
        if road[y][x] == 1 and (x in (0, W-1) or y in (0, H-1)): road[y][x] = 0

# ---- 4. prune local segments between intersections -> irregular blocks -----
def nbrs(x, y):
    for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
        xx, yy = x+dx, y+dy
        if 0 <= xx < W and 0 <= yy < H: yield xx, yy
def deg(x, y): return sum(1 for xx, yy in nbrs(x, y) if road[yy][xx])
def is_node(x, y): return road[y][x] and deg(x, y) != 2
# collect segments (paths of degree-2 tiles between nodes)
def segments():
    seen, segs = set(), []
    for y in range(H):
        for x in range(W):
            if not is_node(x, y): continue
            for xx, yy in nbrs(x, y):
                if not road[yy][xx]: continue
                path, px, py, cx, cy = [], x, y, xx, yy
                while road[cy][cx] and not is_node(cx, cy):
                    path.append((cx, cy))
                    nx = [(a, b) for a, b in nbrs(cx, cy) if road[b][a] and (a, b) != (px, py)]
                    if not nx: break
                    px, py, (cx, cy) = cx, cy, nx[0]
                key = frozenset(path) if path else frozenset({(x,y),(cx,cy)})
                if path and key not in seen:
                    seen.add(key); segs.append(path)
    return segs
def connected_from(sx, sy):
    q, seen = deque([(sx, sy)]), {(sx, sy)}
    while q:
        x, y = q.popleft()
        for xx, yy in nbrs(x, y):
            if road[yy][xx] and (xx, yy) not in seen: seen.add((xx, yy)); q.append((xx, yy))
    return seen
for path in segments():
    if any(road[y][x] == 2 for x, y in path): continue
    k = dist[path[0][1]][path[0][0]]
    if rng.random() < DIST[k][2]:
        saved = [(x, y, road[y][x]) for x, y in path]
        for x, y in path: road[y][x] = 0
        # keep only if the network stays connected
        total = sum(1 for r in road for v in r if v)
        if len(connected_from(*pts['A'])) < total:
            for x, y, v in saved: road[y][x] = v
# drop dangling local stubs (dead ends) except in residential where we keep some as cul-de-sacs
changed = True
while changed:
    changed = False
    for y in range(H):
        for x in range(W):
            if road[y][x] == 1 and deg(x, y) <= 1:
                k = dist[y][x]
                if DIST[k][0] == 'residential' and rng.random() < 0.5: continue
                road[y][x] = 0; changed = True

# ---- 5. blocks (flood fill of non-road) and lots -------------------------
block = [[-1]*W for _ in range(H)]; nb = 0
for y in range(H):
    for x in range(W):
        if road[y][x] or block[y][x] >= 0: continue
        q = deque([(x, y)]); block[y][x] = nb
        while q:
            cx, cy = q.popleft()
            for xx, yy in nbrs(cx, cy):
                if not road[yy][xx] and block[yy][xx] < 0: block[yy][xx] = nb; q.append((xx, yy))
        nb += 1
# lots: tile a block with district lot-size cells; a lot gets a building if it fronts a road
buildings = []   # (name, x, y, w, h, district)
counter = {k: 0 for k in DIST}
taken = [[False]*W for _ in range(H)]
for y in range(H):
    for x in range(W):
        if road[y][x] or taken[y][x]: continue
        k = dist[y][x]; ls = DIST[k][3]
        if ls == 0: continue
        # try lot sizes: preferred, then smaller, to fit odd blocks
        placed = False
        for s in (ls, max(2, ls-1)):
            w = h = s
            if x+w > W or y+h > H: continue
            cells = [(xx, yy) for yy in range(y, y+h) for xx in range(x, x+w)]
            if any(road[yy][xx] or taken[yy][xx] or dist[yy][xx] != k for xx, yy in cells): continue
            fronts = any(road[b][a] for xx, yy in cells for a, b in nbrs(xx, yy))
            for xx, yy in cells: taken[yy][xx] = True
            if fronts and rng.random() < (0.95 if DIST[k][0] == 'downtown' else 0.8):
                counter[k] += 1
                buildings.append((f"{k.lower()}{counter[k]}", x, y, w, h, k))
            placed = True; break

# ---- 6. graph: intersections + building entrances ------------------------
nodes = [(x, y) for y in range(H) for x in range(W) if road[y][x] and deg(x, y) in (1, 3, 4)]
print(f"seed={SEED} roads={sum(1 for r in road for v in r if v)} blocks={nb} intersections={len(nodes)} buildings={len(buildings)}",
      {k: counter[k] for k in counter})

# ---- 7. SVG ---------------------------------------------------------------
S = 18
out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W*S}" height="{H*S}" viewBox="0 0 {W*S} {H*S}" font-family="monospace">',
       f'<rect width="100%" height="100%" fill="#1a1a1f"/>']
for y in range(H):
    for x in range(W):
        out.append(f'<rect x="{x*S}" y="{y*S}" width="{S}" height="{S}" fill="{DIST[dist[y][x]][4]}" opacity="0.28"/>')
for y in range(H):
    for x in range(W):
        if road[y][x]:
            c = '#e8e2d0' if road[y][x] == 2 else '#8f8a80'
            out.append(f'<rect x="{x*S}" y="{y*S}" width="{S}" height="{S}" fill="{c}"/>')
for name, x, y, w, h, k in buildings:
    out.append(f'<rect x="{x*S+1.5}" y="{y*S+1.5}" width="{w*S-3}" height="{h*S-3}" fill="{DIST[k][4]}" stroke="#111" stroke-width="1"/>')
    fs = 11
    out.append(f'<text x="{x*S+w*S/2}" y="{y*S+h*S/2+fs*0.35}" font-size="{fs}" fill="#111" text-anchor="middle">{name}</text>')
for x, y in nodes:
    out.append(f'<circle cx="{x*S+S/2}" cy="{y*S+S/2}" r="2" fill="#ff5a36"/>')
for k, (sx, sy) in seeds.items():
    out.append(f'<text x="{sx*S}" y="{sy*S}" font-size="14" font-weight="bold" fill="#fff" stroke="#000" stroke-width="3" paint-order="stroke" text-anchor="middle">{k}: {DIST[k][5]}</text>')
out.append('</svg>')
open(f'city_{SEED}.svg', 'w').write('\n'.join(out))
