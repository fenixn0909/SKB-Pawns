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

- **Click a PC** (or press **1**-**6**, **Tab**/**E** to cycle forward, **Q** to cycle backward) to activate it. A ring marks whoever's active and follows them through every move, push, swap, or drag. The camera also pans to keep the active PC in view.
- **Move the active PC** with the **arrow keys**, or by clicking an adjacent tile. What a directional input actually *does* depends on that pawn's Moving ability (see below) -- Knight pushes, Mage swaps, Guardian pulls, Brawler kicks, Slinger throws; Scout (and anyone without a Moving ability) just steps one tile onto open floor.
- **G** -- Guard (Guardian only): braces, absorbing the next push/hit against you.
- **Space** -- End Turn: hands control to the enemy AI, then hazard tiles tick down and it's your turn again.
- **, / .** -- Undo / Redo, like most apps. **R** -- Restart the whole stage from its very first state.
- **+ / -** -- Zoom in/out (0.5x-3x).
- **Esc** cancels a pending targeted ability, if one's armed.
- The small **»/«** button in the top-right corner shows/hides the sidebar, if it's ever in the way.

## Camera

`main.lua` computes a tile size that fits the whole map inside the board
area, so everything's visible by default -- and `modules/camera.lua` pans
to keep the selected PC centered, clamping so the map's edges never scroll
into empty space (an axis that already fits the viewport just stays
centered). **+ / -** zoom from 0.5x-3x on top of that (`camera:setZoom`)
for a closer look at a busy area, like the annex's vault.

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
- **Kick** (Brawler) -- a normal one-tile step, then whoever's now in your
  facing direction gets kicked: they slide until blocked by a wall or
  another pawn (unlimited distance). Their own facing never changes.
- **Kick+** -- same, but kicks every pawn lined up in your facing
  direction, not just the first -- each slides independently, farthest one
  first so nobody transiently overlaps mid-resolution.
- **Throw** (Slinger) -- a normal one-tile step, then the pawn now
  adjacent in your facing direction is thrown: it jumps over the 1st tile
  beyond it (ignoring any pawn there, but not a wall) and lands on the
  2nd. See "Jump landings," below, for what happens if it lands on someone.

Each pawn can only have **one** Moving ability equipped at a time (it
replaces what your movement input does, so two would conflict) --
`pawnDplyr.KIND_INFO[kind].movingAbility` is the single source of truth.
To try a variant not currently assigned to a PC (Push+, Swap+, Pull+,
Kick+), just change that field for the pawn you want to test with.

### Jump landings (Throw)

If a thrown pawn (`jmpPawn`) lands on an occupied tile (`bedPawn`), what
happens is resolved in priority order by `chessUpdtr:resolveJumpLanding`:

1. **jmpPawn is Armored or Protected** -- `bedPawn` dies, `jmpPawn` lands
   there safely, regardless of `bedPawn`'s own traits.
2. **bedPawn is Spike-Headed** (and jmpPawn isn't Armored/Protected) --
   `jmpPawn` is impaled and dies; `bedPawn` is unharmed.
3. **jmpPawn is Lightweight** (and neither of the above applies) --
   `jmpPawn` taps `bedPawn` (who survives, untouched) and keeps jumping to
   the *next* tile in the same direction, re-running this whole check
   against whatever's there. Chains through as many pawns as are lined up.
   Dies if it bounces into a wall.
4. **None of the above** -- mutual destruction: both `jmpPawn` and
   `bedPawn` die.

## Designing traits

Traits (`modules/traitMng.lua`) are always-on boolean adjectives a pawn
either has or doesn't (`pawn.traits[id] == true`) -- contrast with
abilities, which are things a pawn *does*. They can be native
(`KIND_INFO.traits`, copied in at deploy time) or granted/revoked at
runtime via `pawnDplyr:addTrait` / `:removeTrait` (e.g. a future buff or
piece of equipment).

- **Lightweight** (Mage) -- pushed or dragged one *extra* tile, if the
  tile beyond is clear. Also the key to bouncing safely off jump landings
  -- see "Jump landings," above. Checked inside `chessUpdtr`'s
  `tryPushChain` / `dragBehindChain` / `resolveJumpLanding`.
- **Stealth** -- ignored by automatic enemy line-of-sight targeting
  (`chessUpdtr:findBeamTarget`). Not natively on anyone by default in this
  demo room (see `tests/smoke_test.lua`'s stealth section for a runtime
  grant/revoke example) -- it's there for a future buff/equipment to hand
  out.
- **Armor** / **Protected** -- two separate ids that mean the same thing
  mechanically (kept separate so different sources -- a shield item vs. a
  temporary ward spell -- can grant "the same" immunity without sharing an
  id): full immunity to Treant's slam and Spitter's acid ball, and crushes
  whoever's landed on in a jump (see "Jump landings," above).
- **Parry** -- immune to Treant's melee slam specifically. Does *not*
  protect against Spitter's ranged acid -- it's a melee-only defense.
- **Spike-Headed** -- a non-Armored/Protected pawn that jump-lands on this
  one dies instead of it. See "Jump landings," above.
- **Tiny Size** (Scout) -- can pass through jail bars, a wall's tiny hole,
  and tunnels (which teleport it to the paired exit) -- tiles that block
  every other pawn. Checked in `chessMap:isWalkable`.

## Stones

`stone_a` / `stone_b` / `stone_c` (`pawnDplyr.KIND_INFO`) are plain,
ability-less, HP-less movable blockers -- test furniture for the
Push/Swap/Pull/Kick/Throw family above. They're mechanically identical;
the three ids just exist so a level could label them if it wanted to. The
demo room places a few of them (`data/sampleLevel.lua`'s `extras`) right
in front of each PC's spawn so you can try each Moving ability immediately.

## Enemies

Enemy AI is fully automatic (no player input ever drives an enemy) --
`chessUpdtr:runEnemyPhase` checks each enemy's abilities for an
`aiPattern` and fires accordingly:

- **Fire Beam** (Turret, Wraith) -- `aiPattern = "beam_pierce"`. Aims at
  any non-stealthed PC sharing a clear row/column; damages *everything* on
  that line, piercing straight through.
- **Acid Spit** (Spitter) -- `aiPattern = "beam_first"`. Same aiming as
  Fire Beam, but the shot stops at -- and only affects -- the first pawn
  it reaches, rather than piercing. Armor and Protected grant immunity
  (Parry does not -- it's a melee-only defense); an immune pawn still
  stops the shot, it just takes no damage.
- **Treant Slam** (Treant) -- `aiPattern = "melee8"`. No aiming at all --
  fires every enemy turn regardless of position, damaging every PC in the
  8 surrounding tiles (including diagonals). Treant never moves on its
  own, so this is its entire kit. Armor, Protected, and Parry all grant
  immunity.

## Tiles

Beyond the original floor/wall/hazard/goal/mechanism set, three tile
types exist purely to gate movement by trait:

- **Jail bars** (`J`) / **wall hole** (`H`) -- both block every pawn
  except a **Tiny Size** one, exactly like a wall. They're two different
  ids purely so a level can pick whichever visual fits (bars vs. a hole in
  a wall) -- mechanically identical.
- **Tunnel** (`T`) -- also Tiny-only, but instead of just letting a Tiny
  pawn stand there, stepping onto one instantly teleports it to the other
  tunnel tile sharing its id. Pair them via `sampleLevel.tunnels = { {id=,
  col=, row=}, ... }` (see `data/sampleLevel.lua`'s vault for an example);
  `chessMap:getTunnelExit` looks up the other end.

The demo room's annex has a small sealed vault reachable only by the
Scout (the Tiny Size PC) -- through the jail bars, the wall hole, or by
stepping onto the tunnel tile out in the open, which teleports straight
into the vault.

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
| `modules/chessMap.lua` | Tile grid, legend, spawn/wall/mechanism/goal/hazard/jail/hole/tunnel data, hazard sink countdown, tunnel pairing, terrain rendering. Fixed tile size -- the world can exceed the viewport. Knows nothing about pawns. |
| `modules/camera.lua` | Pans/clamps a viewport around the world so a chosen point (the selected PC) stays centered. |
| `modules/pawnDplyr.lua` | Deploys PCs/enemies/movables/mechanisms/stones, owns the occupancy grid, facing, traits, and directional sprite swapping. Each pawn is a container group (sprite + HP text as children in local coords), so anything else parented to it -- like the selection ring -- moves automatically whenever the container is tweened. |
| `modules/pawnCon.lua` | Input: pick/cycle the active PC (Tab/Q/E/1-6), route taps to movement or ability targeting, Guard's keybinding. |
| `modules/abltMng.lua` | Ability catalog -- targeting rule, trigger type, `aiPattern` (enemy abilities), and `execute(user, target, ctx)` logic for every ability. |
| `modules/traitMng.lua` | Trait catalog (native, always-on modifiers -- Lightweight, Stealth, Armor, Protected, Parry, Spike-Headed, Tiny Size). |
| `modules/chessUpdtr.lua` | The resolution engine: turn flow, movement + Moving-ability dispatch, the `ctx` primitives abilities are built from (including the jump-landing resolution table), enemy AI dispatch, hazard ticking, win/lose checks. |
| `modules/historyMng.lua` | Full-board-state snapshot/undo/redo/restart. |
| `data/sampleLevel.lua` | One demo room (32x15: a 20x15 original room plus a walled annex) as an ASCII legend + spawn assignments + stone/crate placement + tunnel pairing. |
| `tests/` | Headless smoke test with a fake Solar2D API, so the logic can be checked without the simulator (see below). |

The split between `abltMng` (ability *rules*) and `chessUpdtr` (the *engine*
those rules run on) is deliberate: `abltMng` never touches the board
directly, it's handed a toolkit of primitives (`tryPushChain`, `swapPawns`,
`swapFacing`, `dragBehindChain`, `kickChain`, `throwPawn`, `pullPawn`,
`traceBeam`, `traceBeamFirst`, `meleeSlam8`, `setStatus`, ...) by
`chessUpdtr`. That's what lets every ability -- including Kick/Throw, the
jump-landing table, and the history system -- get tested headlessly (see
`tests/smoke_test.lua`) without booting the simulator at all -- run it
yourself with `texlua tests/smoke_test.lua` if you have any Lua 5.3
interpreter handy (LuaTeX's `texlua` works fine and is often already
installed alongside a TeX distribution).

## Abilities implemented

- **Push / Push+** (Knight) -- Moving-trigger; see "Designing abilities" above.
- **Swap / Swap+** (Mage) -- Moving-trigger; see above. (A separate Active, click-to-target adjacent-only "Swap" also still exists in the catalog for anything that wants a manually-armed version.)
- **Pull / Pull+** (Guardian) -- Moving-trigger; see above.
- **Kick / Kick+** (Brawler) -- Moving-trigger; see above.
- **Throw** (Slinger) -- Moving-trigger; see above and "Jump landings."
- **Push All** -- Active; shoves every adjacent pawn (and any chain behind them) outward. Not on a default PC right now, but still in the catalog.
- **Drag** -- Active; pull a pawn one tile toward you, range 3, needs a clear line. Not on a default PC right now, but still in the catalog.
- **Guard** (Guardian) -- Active, keybound to **G**; absorbs the next push or halves the next hit against you.
- **Fire Beam** (Turret, Wraith) / **Acid Spit** (Spitter) / **Treant Slam** (Treant) -- Active, AI-driven; see "Enemies" above.

## Sprites

Placeholder retro pixel-art PNGs, in `images/`. Every PC and enemy kind has
**4 directional sprites** (`_down`/`_up`/`_left`/`_right`, e.g.
`pc_knight_down.png`) -- `pawnDplyr` swaps the displayed sprite to match
`pawn.facing` whenever it changes (see `pawnDplyr:_applySprite`), so there's
no separate facing indicator overlay anymore. Non-directional pawns
(stones/crates/gears, which never move under their own power) still use a
single static `image`. Terrain overlays (wall/gear/goal/hazard/jail
bars/wall hole/tunnel) and the selection ring round out the set. Generated
procedurally -- easy to swap for hand-drawn art later since every reference
is just a path string in `pawnDplyr.KIND_INFO` / `chessMap`'s overlay table.

## Known simplifications (mockup scope)

- No turn-order/initiative system within a phase -- PCs act in any order, then all enemies act.
- No AP/action economy beyond "one ability or move per activation" -- nothing stops you from moving a pawn and also using its ability in the same activation right now.
- A pawn's facing only updates on its own moves (arrow key / tile tap), not when it's displaced by someone else's push/pull/swap/kick/throw.
- Only one Moving ability can be equipped per pawn at a time (see "Designing abilities" above).
- Enemies never move on their own -- Treant "standing where it is" is true of every enemy right now, not a special behavior unique to it.
- Directional sprites vary a small weapon/face marker per direction on a shared body silhouette, rather than fully redrawn art per facing.

