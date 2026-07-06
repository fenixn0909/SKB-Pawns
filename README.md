# SKB Pawns -- Solar2D Mockup

A tactics/puzzle mockup: push, drag, and swap pawns around a grid to solve
each room, while the "sinking star" hazard tiles count down and swallow
whatever's standing on them when they go.

## Running it

1. Install Solar2D (https://solar2d.com).
2. Open Solar2D Simulator -> **File > Open** -> select this folder
   (the one containing `main.lua` / `config.lua`).
3. It launches straight into a demo room, no menu yet.

## Controls

- **Click a PC** (or press **1**/**2**/**3**, or **Tab** to cycle) to activate it. A ring marks whoever's active and now correctly follows them through every move, push, swap, or drag.
- **Move the active PC** with the **arrow keys**, or by clicking an adjacent tile. Movement is always exactly **one grid cell, orthogonal only** (no diagonals) -- abilities are the only thing allowed to relocate a pawn further or differently.
- **Click an ability button** in the sidebar to arm it:
  - Abilities with no target (Push All, Guard) fire immediately.
  - Abilities needing a target (Swap, Drag) then wait for you to click a pawn.
  - Fire Beam-style abilities wait for a click on any tile to imply a direction (enemies only, AI-driven here).
  - **Esc** cancels a pending ability (arrow keys are ignored while an ability is armed, so they can't be misread as a target).
- **End Turn** button hands control to the enemy AI, then hazard tiles tick down and it's your turn again.

## Module map

| Module | Responsibility |
|---|---|
| `modules/chessMap.lua` | Tile grid, legend, spawn/wall/mechanism/goal/hazard data, hazard sink countdown, terrain rendering. Knows nothing about pawns. |
| `modules/pawnDplyr.lua` | Deploys PCs/enemies/movables/mechanisms, owns the occupancy grid. Each pawn is a container group (sprite + HP text as children in local coords), so anything else parented to it -- like the selection ring -- moves automatically whenever the container is tweened. |
| `modules/pawnCon.lua` | Input: pick/cycle the active PC, route taps to movement or ability targeting. |
| `modules/abltMng.lua` | Ability catalog -- each ability's targeting rule and its `execute(user, target, ctx)` logic. |
| `modules/chessUpdtr.lua` | The resolution engine: turn flow, movement validation, the `ctx` primitives abilities are built from, enemy AI, hazard ticking, win/lose checks. |
| `data/sampleLevel.lua` | One demo room (20x15) as an ASCII legend + spawn assignments. |
| `tests/` | Headless smoke test with a fake Solar2D API, so the logic can be checked without the simulator (see below). |

The split between `abltMng` (ability *rules*) and `chessUpdtr` (the *engine*
those rules run on) is deliberate: `abltMng` never touches the board
directly, it's handed a small toolkit of primitives (`tryPush`, `swapPawns`,
`pullPawn`, `traceBeam`, `setStatus`) by `chessUpdtr`. That's what let me
test all five abilities headlessly (see `tests/smoke_test.lua`) without
booting the simulator at all -- run it yourself with `texlua tests/smoke_test.lua`
if you have any Lua 5.3 interpreter handy (LuaTeX's `texlua` works fine and
is often already installed alongside a TeX distribution).

## Abilities implemented

- **Push All** (Knight, Guardian) -- shoves every adjacent pawn one tile outward.
- **Swap** (Knight, Mage) -- trade places with an adjacent pawn.
- **Drag** (Mage) -- pull a pawn one tile toward you, range 3, needs a clear line.
- **Guard** (Guardian, Brute) -- absorbs the next push or halves the next hit against you.
- **Fire Beam** (Turret, Wraith) -- damages everything in a straight line until a wall. Currently enemy-only and AI-driven (fires automatically at any PC sharing a clear row/column).

## Sprites

Placeholder retro pixel-art PNGs for every pawn kind plus wall/gear/goal/hazard
terrain overlays and a selection ring, in `images/`. Generated procedurally
(see the note in the delivery message) -- easy to swap for hand-drawn art later
since every reference is just a path string in `pawnDplyr.KIND_INFO` /
`chessMap`'s overlay table.

## Known simplifications (mockup scope)

- Enemy AI is a single rule (fire at any PC in a clear line). No pathing/positioning AI yet.
- No turn-order/initiative system within a phase -- PCs act in any order, then all enemies act.
- No AP/action economy beyond "one ability or move per activation" -- nothing stops you from moving a pawn and also using its ability in the same activation right now.
- Movement is one grid cell per action (arrow key or adjacent tile click); nothing animates a multi-tile path since there isn't one.
