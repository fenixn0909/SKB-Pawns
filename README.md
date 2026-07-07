# SKB Pawns -- Solar2D Mockup

A tactics/puzzle mockup: push, swap, and pull pawns around a grid to solve
each room, while the "sinking star" hazard tiles count down and swallow
whatever's standing on them when they go. A scrolling camera follows
whoever's active, and every action is undoable.

## Running it

1. Install Solar2D (https://solar2d.com).
2. Open Solar2D Simulator -> **File > Open** -> select this folder
   (the one containing `main.lua` / `config.lua`).
3. It launches straight into a demo room, no menu yet.

## Controls

- **Click a PC** (or press **1**/**2**/**3**, or **Tab** to cycle) to activate it. A ring marks whoever's active and follows them through every move, push, swap, or drag. The camera also pans to keep the active PC in view -- it's a no-op on this particular room (small enough to fit on screen), but the map can be bigger than the viewport now (see Camera, below).
- **Move the active PC** with the **arrow keys**, or by clicking an adjacent tile. What a directional input actually *does* depends on that pawn's Moving ability (see below) -- Knight pushes, Mage swaps, Guardian pulls; anyone without one just steps one tile onto open floor.
- **G** -- Guard (Guardian only): braces, absorbing the next push/hit against you.
- **E** -- End Turn: hands control to the enemy AI, then hazard tiles tick down and it's your turn again.
- **, / .** -- Undo / Redo, like most apps. **R** -- Restart the whole stage from its very first state.
- **Esc** cancels a pending targeted ability, if one's armed.
- The small **»/«** button in the top-right corner shows/hides the sidebar, if it's ever in the way.

## Camera

`modules/chessMap.lua` uses a **fixed tile size** now instead of scaling to
fit the screen, so a map can be bigger than the viewport. `modules/camera.lua`
pans a clipped viewport around it, centering whoever's selected and clamping
so the map's edges never scroll into empty space (an axis that already fits
the viewport just stays centered and never scrolls). The board's tap
coordinates go through `contentToLocal()` so tile-picking still lines up
correctly no matter how far the camera has panned.

## Designing abilities: Passive / Moving / Flow / Active

Every ability has a **trigger** (`abltMng.TRIGGER`), i.e. what causes it to
fire:

- **Active** -- the player arms it, then (if it needs one) supplies a
  target. Everything before this system existed was implicitly Active.
  Only **Guard** still works this way by default now (bound to the **G**
  key) -- Push/Swap/Drag are still registered abilities (a mechanism could
  still grant one as a temporary buff) but no longer sit on a PC's default
  kit, since their Moving-trigger equivalents below cover the same ground.
- **Passive** -- always on, no activation at all. Reserved for future
  stat-modifier-style abilities (equipment, etc.) -- none of the defaults
  use it yet, but the trigger slot exists.
- **Moving** -- fires as *what a directional input does* for that pawn,
  via `pawn.movingAbility` (see `pawnDplyr.KIND_INFO`). Replaces baseline
  one-tile movement for whoever has one assigned.
- **Flow** -- a reaction to being moved by someone/something else (pushed,
  dragged, swapped). Pull/Pull+'s chain effect is implemented as part of
  the *mover's* own ability rather than a separate registry entry on the
  receiver, but the trigger tag exists for a future ability that needs to
  react on the *receiving* end of a displacement.

### The Moving abilities (test them against the stones in the demo room)

- **Push** (Knight) -- walking into a pawn shoves it, and any chain
  directly behind it (unlimited depth), forward by one tile, then you
  step into the space it left.
- **Push+** -- like Push, but the chain it can shove tops out at 2 pawns;
  a longer line won't budge at all.
- **Swap** (Mage) -- instead of stepping, instantly swaps with the first
  pawn along your facing direction (facing = your last move direction) --
  unlimited range, but a wall blocks line of sight. Falls back to a normal
  step if nothing's found.
- **Swap+** -- same, but sees straight through walls.
- **Pull** (Guardian) -- a normal one-tile step, plus whatever pawn is
  directly behind you gets dragged into the tile you just vacated.
- **Pull+** -- same, but the whole contiguous line behind you shuffles
  forward one tile each, like a conga line / sneaking train.

Each pawn can only have **one** Moving ability equipped at a time (it
replaces what your movement input does, so two would conflict) --
`pawnDplyr.KIND_INFO[kind].movingAbility` is the single source of truth.
To try a variant not currently assigned to a PC (Push+, Swap+, Pull+),
just change that field for the pawn you want to test with.

## Designing traits

Traits (`modules/traitMng.lua`) are always-on boolean adjectives a pawn
either has or doesn't (`pawn.traits[id] == true`) -- contrast with
abilities, which are things a pawn *does*. They can be native
(`KIND_INFO.traits`, copied in at deploy time) or granted/revoked at
runtime via `pawnDplyr:addTrait` / `:removeTrait` (e.g. a future buff or
piece of equipment).

- **Lightweight** (Mage) -- pushed or dragged one *extra* tile, if the
  tile beyond is clear. Checked inside `chessUpdtr`'s `tryPushChain` /
  `dragBehindChain` primitives.
- **Stealth** -- ignored by automatic enemy line-of-sight targeting
  (`chessUpdtr:findBeamTarget`). Not natively on anyone by default in this
  demo room (see `tests/smoke_test.lua`'s stealth section for a runtime
  grant/revoke example) -- it's there for a future buff/equipment to hand
  out.

## Stones

`stone_a` / `stone_b` / `stone_c` (`pawnDplyr.KIND_INFO`) are plain,
ability-less, HP-less movable blockers -- test furniture for the
Push/Swap/Pull family above. They're mechanically identical; the three
ids just exist so a level could label them if it wanted to. The demo room
places a few of them (`data/sampleLevel.lua`'s `extras`) right in front of
each PC's spawn so you can try each Moving ability immediately.

## History: undo / redo / restart

`modules/historyMng.lua` snapshots the *entire* board (every pawn's
position/HP/statuses/traits/facing, every tile's type and hazard
countdown, and the turn/round counters) after every move, ability, or
completed round. It's a full-state snapshot rather than move-by-move
reversal, because pawns can die/sink (and need to come back on undo) and
hazard tiles change type over time -- reversing those cleanly one at a
time would need its own inverse for every kind of change, whereas a
snapshot just re-declares "this is the state" and rebuilds to match.
Applying one tears down every pawn's display objects and recreates them
fresh from the snapshot's data. **, / .** step back/forward through the
history; **R** jumps straight back to the level's starting snapshot.

## Module map

| Module | Responsibility |
|---|---|
| `modules/chessMap.lua` | Tile grid, legend, spawn/wall/mechanism/goal/hazard data, hazard sink countdown, terrain rendering. Fixed tile size -- the world can exceed the viewport. Knows nothing about pawns. |
| `modules/camera.lua` | Pans/clamps a viewport around the world so a chosen point (the selected PC) stays centered. |
| `modules/pawnDplyr.lua` | Deploys PCs/enemies/movables/mechanisms/stones, owns the occupancy grid, facing, and traits. Each pawn is a container group (sprite + HP text + facing indicator as children in local coords), so anything else parented to it -- like the selection ring -- moves automatically whenever the container is tweened. |
| `modules/pawnCon.lua` | Input: pick/cycle the active PC, route taps to movement or ability targeting, Guard's keybinding. |
| `modules/abltMng.lua` | Ability catalog -- targeting rule, trigger type, and `execute(user, target, ctx)` logic for every ability. |
| `modules/traitMng.lua` | Trait catalog (native, always-on modifiers like Lightweight/Stealth). |
| `modules/chessUpdtr.lua` | The resolution engine: turn flow, movement + Moving-ability dispatch, the `ctx` primitives abilities are built from, enemy AI, hazard ticking, win/lose checks. |
| `modules/historyMng.lua` | Full-board-state snapshot/undo/redo/restart. |
| `data/sampleLevel.lua` | One demo room (20x15) as an ASCII legend + spawn assignments + stone/crate placement. |
| `tests/` | Headless smoke test with a fake Solar2D API, so the logic can be checked without the simulator (see below). |

The split between `abltMng` (ability *rules*) and `chessUpdtr` (the *engine*
those rules run on) is deliberate: `abltMng` never touches the board
directly, it's handed a toolkit of primitives (`tryPushChain`, `swapPawns`,
`swapFacing`, `dragBehindChain`, `pullPawn`, `traceBeam`, `setStatus`, ...)
by `chessUpdtr`. That's what lets every ability -- including the new
Push/Swap/Pull family and the history system -- get tested headlessly (see
`tests/smoke_test.lua`) without booting the simulator at all -- run it
yourself with `texlua tests/smoke_test.lua` if you have any Lua 5.3
interpreter handy (LuaTeX's `texlua` works fine and is often already
installed alongside a TeX distribution).

## Abilities implemented

- **Push / Push+** (Knight) -- Moving-trigger; see "Designing abilities" above.
- **Swap / Swap+** (Mage) -- Moving-trigger; see above. (A separate Active, click-to-target adjacent-only "Swap" also still exists in the catalog for anything that wants a manually-armed version.)
- **Pull / Pull+** (Guardian) -- Moving-trigger; see above.
- **Push All** -- Active; shoves every adjacent pawn (and any chain behind them) outward. Not on a default PC right now, but still in the catalog.
- **Drag** -- Active; pull a pawn one tile toward you, range 3, needs a clear line. Not on a default PC right now, but still in the catalog.
- **Guard** (Guardian) -- Active, keybound to **G**; absorbs the next push or halves the next hit against you.
- **Fire Beam** (Turret, Wraith) -- Active; damages everything in a straight line until a wall. Enemy-only and AI-driven (fires automatically at any non-stealthed PC sharing a clear row/column).

## Sprites

Placeholder retro pixel-art PNGs for every pawn kind plus wall/gear/goal/hazard
terrain overlays and a selection ring, in `images/`. Generated procedurally
(see the note in the delivery message) -- easy to swap for hand-drawn art later
since every reference is just a path string in `pawnDplyr.KIND_INFO` /
`chessMap`'s overlay table. Stones reuse a single procedurally-generated
`images/stone.png`.

## Known simplifications (mockup scope)

- Enemy AI is a single rule (fire at any non-stealthed PC in a clear line). No pathing/positioning AI yet.
- No turn-order/initiative system within a phase -- PCs act in any order, then all enemies act.
- No AP/action economy beyond "one ability or move per activation" -- nothing stops you from moving a pawn and also using its ability in the same activation right now.
- A pawn's facing only updates on its own moves (arrow key / tile tap), not when it's displaced by someone else's push/pull/swap.
- Only one Moving ability can be equipped per pawn at a time (see "Designing abilities" above).
