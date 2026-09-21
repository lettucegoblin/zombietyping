# Next steps

State as of 2026-09-21. Everything in `README.md` is implemented and the headless suite
passes. City streets now use a continuous global hierarchy of warped avenues, collectors,
and local streets; districts, lots, building uses, apartment units, semantic rooms, and
furnishings are all procedural. Furnishings already expose stable prop ids, loot-table tags,
and base-utility tags. This is the remaining backlog, roughly in the order the owner has
brought things up, plus the rough edges found while building. Nothing here has been started
unless noted.

## Asked for by the owner, not built yet

1. **Second zombie design** (so runner and shambler stop sharing the hoodie frames).
   Same style as the hoodie, humanoid, static forward-facing neutral idle first → owner
   confirms the pose → then rotations + the ~90-generation animation set (run, flinch_a/b,
   attack, death-on-floor, breathing idle). Shambler: slower, maybe a bloater/crawler.
2. **Tab map art** via PixelLab's tileset tools (`create_topdown_tileset` /
   `create_map`) instead of the coloured squares. Keep labels and fog as they are.
3. **Looting, survivors, bases, and supply lines.** Prop ids and loot/utility metadata now
   provide the deterministic source objects; inventories and prop-depletion persistence are
   not built. Survivors should live in cleared buildings; a cleared block becomes safe
   (`World.state[...]["safe"]` is already drawn cyan on the map), bases consume utility-tagged
   furnishings, and supply lines follow the connected road hierarchy between safe buildings.
   The simulation, UI, and persistence rules still need design.
4. **Save / load** of `World.state`, `World.explored`, seed, player tile, hp/kills.
5. **Street props / more ambience**: abandoned cars, litter, streetlights, more sky life.
   Clouds and crows exist; the owner keeps asking for "more atmosphere".
6. **Real sound.** Every wav is synthesized; replace with recordings or better synthesis
   (the beds/events wiring in `sfx.gd` stays).

## Rough edges seen while playtesting (owner has NOT reported these yet)

- **Balance in small rooms**: two runners spawning close to the threshold of a 1-wide
  hall is brutal. Options: spawn distance floor, longer notice beat in small rooms, fewer
  zombies in "hall"-kind rooms.
- **Large apartment clears** are now meaningfully long: a six-floor block can exceed 100
  rooms. The generation is correct, but floor count and unit density may need balance tuning.
- **Approach leg** walks a straight line at the zombie; in L-shaped halls it could clip a
  wall (rooms are rectangles so far, so it hasn't).
- **Sweep facing** picks the nearest zombie still standing in the room; with several dormant
  ones you fight them one at a time, which is intended, but there is no cue that it is a
  sweep (a small "…" or a head-turn sound would help).
- Corpses lie on the floor forever inside buildings (they go with the storey). Fine, but
  pile-ups in a corridor look odd.
- Minimap packs labels tightly in dense blocks at 5 px/tile.
- The `runner/` sprite folder is dead weight; delete when the second design lands.
- `FloorPlan.Door.open_always` is unused (archways were tried and reverted); safe to remove.
- Headless tests leak a few ObjectDB instances at exit (awaited timers); harmless.

## Ideas that came up and were parked

- Typed `go` to resume the rail (owner chose auto-resume instead).
- Archway stairwells (no doors) — tried, owner preferred doors so the landing works as a
  hub; keep doors.
- A "manual search" cue in the HUD ("nothing left here — moving on") exists; could become
  a short on-screen arrow/marker for where the rail is taking you.

## How to pick this up cold

1. Read `README.md` §1 (rules) and §7 (rails/typing/combat) — that is where most owner
   feedback lands.
2. Open the editor (`README.md` §2), run `tools/gd.sh 200 res://scenes/tests/test_combat.tscn`
   to confirm the toolchain, then `python3 tools/live/run_and_shot.py run` and screenshot.
3. Playtest notes usually arrive as a list; the loop that has worked: reproduce with the
   live drivers (`tools/live/play.py`, F7/F8 dumps), fix, extend the relevant test, run the
   suite (interior test alone), commit without attribution, relaunch the game for the owner.
