# Chaos Car Rain
by minimalmotion — MIT licensed (see LICENSE.md)

A tiny BeamNG.drive mod: press a key, and random vehicles drop out of the
sky near you. Repeat until the map looks like a demolition derby.

## Changelog — fix: some cars spawning on the ground instead of falling

Root cause: every drop's spawn height was computed as
`player's z + dropHeight` -- using the *player's own* elevation for every
car in the batch. But `settings.spread` also moves each drop sideways from
the player, and on any hill, slope, or uneven terrain, the ground under
that sideways offset isn't at the same height as the ground under the
player. When the offset landed somewhere higher than the player (a nearby
rise, an incline, a curb), the computed spawn point could be at or below
the real ground level there, so the car never actually fell -- it just
appeared already sitting on the ground.

Fixed by sampling the real terrain/surface height under each drop's own
(x, y) via `be:getSurfaceHeightBelow()` and building `dropHeight` on top of
*that*, instead of the player's z. Wrapped in `pcall` with a fallback to
the old player-relative guess if the call ever fails, so a spawn can't
error out entirely over this. Flat ground behaves exactly as before; this
only changes anything on sloped or uneven terrain.

## Changelog — adjustable cooldown keybinds

The cooldown was already tunable from the Lua console
(`chaosCarRain.setCooldown(seconds)`), but that meant tabbing out of
gameplay to change it. Added two bindable keys so it can be raised or
lowered on the fly instead:

- **Increase/Decrease Cooldown.** Two new actions, "Chaos Car Rain:
  Increase Cooldown" and "Chaos Car Rain: Decrease Cooldown", bindable in
  `Options > Controls` same as the drop trigger. Each press adjusts
  `settings.cooldownTime` by `settings.cooldownStep` (default 1s) and shows
  the new value on screen. Clamped to `settings.cooldownMin`/`cooldownMax`
  (default 0-60s) so mashing the key can't send it negative or absurdly
  high — `chaosCarRain.setCooldown()` still works unclamped if you
  deliberately want a value outside that range.
- **Adjustable step size.** `chaosCarRain.setCooldownStep(n)` sets how many
  seconds each keybind press changes, independent of the cooldown value
  itself.
- Changing the cooldown mid-recharge only affects the *next* cooldown timer
  — the one currently counting down isn't retroactively lengthened or
  shortened.

## Changelog — performance pass

The actual lag report: nothing the mod spawned was ever cleaned up. A long
session, or a couple of enthusiastic combo streaks, could leave dozens of
permanent soft-body vehicles sitting on the map, and BeamNG's physics cost
scales hard with vehicle count.

- **Drop cap.** `settings.maxActiveDrops` (default 20) bounds how many
  rain-spawned vehicles can be alive at once. Once you're at the cap, new
  drops delete the oldest ones first (FIFO) to make room -- the mod can no
  longer snowball into an unplayable framerate over a session. Tune with
  `chaosCarRain.setMaxActiveDrops(n)`.
- **Manual clear.** `chaosCarRain.clearDropped()` instantly deletes every
  vehicle the mod is still tracking, for when you want your FPS back right
  now instead of waiting for the cap to catch up naturally.
- **Stale-entry pruning.** If you delete/reset a dropped vehicle yourself
  some other way, the tracker notices next time it runs instead of holding
  onto a ghost entry.
- Slightly wider per-drop spawn stagger (0.08s → 0.12s) inside a batch, to
  spread the cost of spawning several vehicles across a couple more frames
  instead of loading them all in one hitch.

**Note:** this addresses the "cars pile up forever" case, which is almost
certainly what you're hitting during normal play. It won't fix lag that's
just from BeamNG generally struggling with vehicle count on your specific
hardware/map — if it's still rough, try `chaosCarRain.setMaxActiveDrops(10)`
or lower.

## Changelog — feature pass, round 2

Two real bugs found in the round 1 feature pass, fixed here:

- **Still got switched into the spawned vehicle.** The one-shot
  `enterVehicle()` call right after spawning lost the race against the
  game's own "auto-enter the vehicle I just spawned" behavior, which can
  fire a frame or two later than our call. Replaced with a short focus
  guard (`settings.focusGuardDuration`, default 0.6s) that keeps
  re-asserting your original vehicle every frame for a beat after a drop
  lands, instead of trying once and hoping. Also passes
  `autoEnterVehicle = false` to `spawnNewVehicle()` as a best-effort hint,
  though the guard is what actually guarantees it.
  **Trade-off:** if you manually switch vehicles yourself during that
  window, the guard will switch you back — that's why it's kept short
  rather than generous.
- **Props were spawning alongside cars.** `core_vehicles.getModelList()`
  returns every spawnable "vehicle" BeamNG knows about, and in BeamNG's
  data model that includes props (traffic cones, hay bales, pallets,
  shipping containers, etc.), not just cars — a BeamNGVehicle object
  covers both. The pool now filters those out using a best-effort category
  check (see `looksLikeProp` in `chaosCarRain.lua`) plus a small blocklist
  of known default prop ids. Not guaranteed exhaustive for every mod's
  content — extend `knownPropIds` if something non-car keeps sneaking in,
  or run `chaosCarRain.setIncludeProps(true)` if you'd rather have them
  back.

## Changelog — feature pass, round 1

Added on top of the bugfix pass below:

- **Telegraph beat.** Hitting the key now shows an immediate "Incoming!"
  style warning, then the actual vehicle(s) land `telegraphDelay` seconds
  later (default 0.6s) instead of appearing instantly. Reads as an event
  instead of a random thump. Tune with `chaosCarRain.setTelegraphDelay(s)`.
- **Combo streak.** Trigger again within `comboWindow` seconds (default 6)
  of the last trigger and the streak builds, adding extra cars per hit
  (capped) and landing with a "COMBO x3!"-style message. Let the window
  lapse, or set it to 0, to go back to plain single drops. Tune with
  `chaosCarRain.setComboWindow(s)`.
- **Weighted rarity pool.** A handful of flashier/rarer vehicle ids (see
  `rareWeights` in `chaosCarRain.lua`) come up a bit more often than plain
  utility vehicles — pure flavor, nothing is excluded, and ids that aren't
  installed simply never get picked.
- **Session drop counter.** Tracks vehicles dropped since launch. Check it
  any time with `chaosCarRain.getTotalDropped()`.

## Changelog — bugfix pass

The zip previously in circulation was missing the fixes described for this
mod in the project handoff notes; this pass actually applies them:

- Added `scripts/chaosCarRain/modScript.lua` (persistent load via
  `setExtensionUnloadMode(..., "manual")` + `loadManualUnloadExtensions()`)
  and an `M.onClientStartMission` reset. This was the real root cause of
  "doesn't work on other maps" — there was no persistent-load script at
  all, so the extension likely wasn't surviving a level change.
- Fixed `refreshCarPool()` to pull the real model id out of each pool entry
  instead of trusting the loop key — the old version silently inserted
  meaningless array indices into the pool when `getModelList()` returned an
  array-indexed list, same bug Bounty Mode had.
- Removed the invalid `config = "random"` passed to `spawnNewVehicle()`
  (not a real config value — spawns now use each vehicle's default config).
- Fixed a player-control hijack: `spawnNewVehicle()` switches control to
  the vehicle it just spawned, so dropping several cars in a loop could
  yank you into the last one. Focus is now forced back to your original
  vehicle after all drops finish.
- Aligned the keybind action with the lazy-load pattern (`isExtensionLoaded`
  check + `extensions.load`) used by the rest of the pack.

**Not yet retested in-game** — these are code-level fixes matching the
pattern already confirmed working in Bounty Mode/Black Box, but this
specific zip hasn't been through a live playtest since.

## What's actually in here (and why)

This follows the official docs almost line for line:

- `lua/ge/extensions/chaosCarRain.lua` — a Lua **extension**
  (docs: https://documentation.beamng.com/modding/programming/extensions/).
  An extension is just a `.lua` file that `return`s a table. Anything placed
  in `lua/ge/extensions/` is loadable in the GE (Game Engine) Lua VM as
  `chaosCarRain`. It declares `M.dependencies = {"core_vehicles"}`, defines
  `M.onExtensionLoaded` / `M.onUpdate`, and exposes `M.trigger()`, plus two
  small settings functions (`M.setDropCount`, `M.setCooldown`).

  On load, it asks the game (`core_vehicles.getModelList(true)`) which
  vehicles are actually installed and builds its spawn pool from that —
  so it never tries to spawn a DLC car you don't own. If that call ever
  fails for any reason, it falls back to a small hardcoded list of default
  vehicles.

- `lua/ge/extensions/core/input/actions/chaosCarRain_actions.json` — a
  bindable **action**
  (docs: https://documentation.beamng.com/modding/input/actions/) called
  "Chaos Car Rain: Drop a Car!" that shows up automatically in
  `Options > Controls`. It's a "regular action" (`ctx: "tlua"`), triggered
  `onDown`, using the same lazy-load-then-call pattern as the rest of the
  pack.

- `scripts/chaosCarRain/modScript.lua` — registers the extension as
  persistent (`setExtensionUnloadMode(..., "manual")` +
  `loadManualUnloadExtensions()`), so it auto-starts at game launch and
  survives level/map changes.

## Installing

Drag `chaoscarrain_minimalmotion.zip` straight into your `mods` folder —
**no need to unzip it.** Typically:

`Documents\BeamNG.drive\<version>\mods\`

Then launch BeamNG.drive and enable it in the in-game Mods menu.

(If you'd rather edit the source while testing, unzip the contents — `lua/`
should be the top-level folder — into `mods\unpacked\ChaosCarRain\` instead.)

## Binding a key

1. `Options > Controls`
2. Search "Chaos Car Rain"
3. Bind "Drop a Car!" to whatever key you like, and optionally bind
   "Increase Cooldown" / "Decrease Cooldown" too if you want to tune the
   recharge time on the fly

## Using it

Get in any vehicle, hit your bound key, and 3 random vehicles fall out of
the sky near you. There's a short cooldown so you can't spam the sim into a
slideshow.

You can also trigger it, or tweak it, from the built-in Lua console
(docs: https://documentation.beamng.com/modding/programming/console/):

```
chaosCarRain.trigger()             -- drop cars right now
chaosCarRain.setDropCount(1)       -- base cars per trigger, before combo bonus (default 3)
chaosCarRain.setCooldown(2)        -- cooldown in seconds (default 4)
chaosCarRain.setCooldownStep(2)    -- seconds per Increase/Decrease Cooldown keypress (default 1)
chaosCarRain.increaseCooldown()    -- same as pressing the keybind once
chaosCarRain.decreaseCooldown()    -- same as pressing the keybind once
chaosCarRain.setTelegraphDelay(1)  -- warning-to-landing delay in seconds (default 0.6)
chaosCarRain.setComboWindow(0)     -- combo window in seconds; 0 disables combos (default 6)
chaosCarRain.setIncludeProps(true) -- allow props (cones, hay bales, etc.) back into the pool
chaosCarRain.setMaxActiveDrops(10) -- cap on rain-spawned vehicles alive at once (default 20)
chaosCarRain.clearDropped()        -- instantly delete every vehicle the mod has spawned
chaosCarRain.getTotalDropped()     -- how many vehicles you've dropped this session
```

## Repository submission checklist

Notes to self before/when posting this to the official BeamNG resources
repository (per https://go.beamng.com/ModdingGuidelines and
https://documentation.beamng.com/modding/mod-support/mod_packing/):

- [x] Works with drag-and-drop, no manual setup steps
- [x] Doesn't overwrite any official game files
- [x] Zip is packed correctly — `lua/` is the first thing visible when the
      zip is opened, not wrapped in a `ChaosCarRain/` folder
- [x] Unique, author-suffixed zip filename: `chaoscarrain_minimalmotion.zip`
- [x] Vehicle pool is built dynamically from installed content, not
      hardcoded to specific DLC
- [x] License included (MIT)
- [ ] Take an actual in-game screenshot (a car mid-fall looks great) and use
      it as the resource page's preview image — this can't be generated
      here, needs to come from your own gameplay
- [ ] Write the resource page description/title on the site itself
- [ ] Playtest on a couple of different levels/vehicle configs before
      posting, just to be safe

## Making it your own

- `fallbackPool` in `chaosCarRain.lua` — only used if the dynamic vehicle
  list fails to load.
- `settings.dropCount` / `settings.cooldownTime` / `settings.cooldownStep` /
  `settings.cooldownMin` / `settings.cooldownMax` / `settings.spread` /
  `settings.dropHeight` / `settings.telegraphDelay` / `settings.comboWindow`
  / `settings.comboBonusPerHit` / `settings.comboMaxBonus` — tune drop
  behavior, or expose more of them as console-settable values (dropCount,
  cooldown, cooldown step, telegraphDelay, and comboWindow already are).
- `rareWeights` — model ids that should spawn a bit more (or less, if you
  set a weight below 1) often than the default weight of 1.
- `knownPropIds` — best-effort blocklist of non-car model ids to keep out
  of the pool; extend it if a prop from some other mod sneaks through.
- `warningMessages` / `funMessages` / `comboMessages` — the on-screen
  messages shown at each stage of a drop.
