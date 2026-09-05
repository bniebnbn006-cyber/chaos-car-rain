-- ChaosCarRain
-- A tiny, silly BeamNG.drive mod: press a key and a random vehicle drops
-- out of the sky near you. That's the whole mod.
--
-- Built following the official extension docs:
-- https://documentation.beamng.com/modding/programming/extensions/
--
-- A BeamNG Lua extension is just a Lua file that returns a table (M).
-- This file lives at lua/ge/extensions/chaosCarRain.lua, which means the
-- extension's global name is "chaosCarRain" and it runs in the GE
-- (Game Engine) Lua VM.

local M = {}

-- Tell the extension system that core_vehicles must be loaded before us,
-- since we use core_vehicles.spawnNewVehicle() / getModelList(). See
-- "Common extension functions/data" -> M.dependencies in the extensions doc.
M.dependencies = { "core_vehicles" }

-- Fallback list, only used if we can't ask the game what's actually
-- installed (see refreshCarPool below). Kept small and version-stable.
local fallbackPool = {
  "pickup", "covet", "sunburst", "sbr", "citybus", "van", "box",
  "barstow", "bastion", "bolide", "burnside", "etk800",
}

local carPool = {}

-- Shown the instant you hit the key, before anything actually lands --
-- the "heads up" beat of the telegraph.
local warningMessages = {
  "Incoming!",
  "Look up!",
  "Brace yourself!",
  "Something's falling...",
}

-- Shown once the drop(s) actually land.
local funMessages = {
  "Surprise delivery!",
  "Gravity says hi.",
  "Car-mageddon!",
  "Special delivery, no signature required.",
  "Delivered as requested.",
}

-- Shown when a combo streak lands (>1 trigger back-to-back).
local comboMessages = {
  "COMBO x%d!",
  "Chaos streak x%d!",
  "Keep it going! x%d",
}

-- Optional spawn-weight bonus for specific model ids -- purely cosmetic
-- flavor so the flashier/rarer cars in a typical install show up a little
-- more often than plain utility vehicles, without excluding anything.
-- Keyed by model id; unlisted models default to a weight of 1. Safe to
-- leave empty -- if a listed id isn't installed it's simply never picked.
local rareWeights = {
  bolide = 3,
  hopper = 2,
  civetta = 3,
  scintilla = 2,
  wendover = 2,
  legran = 2,
  bastion = 2,
}

-- Tunable settings. Change these from the Lua console, e.g.:
--   chaosCarRain.setDropCount(1)
--   chaosCarRain.setCooldown(5)
local settings = {
  dropCount = 3,          -- how many vehicles fall per trigger (base amount)
  cooldownTime = 4,       -- seconds between triggers (scaled a bit below per dropCount)
  cooldownStep = 1,       -- seconds added/removed per keybind press (see increase/decreaseCooldown)
  cooldownMin = 0,        -- floor for the keybind adjuster -- setCooldown() can still go to 0 directly
  cooldownMax = 60,       -- ceiling for the keybind adjuster -- setCooldown() can still go above this directly
  spread = 10,            -- how far apart (meters) dropped vehicles can land from each other
  dropHeight = 14,        -- meters above the player vehicle
  telegraphDelay = 0.6,   -- seconds of warning between hitting the key and cars landing
  comboWindow = 6,        -- trigger again within this many seconds to build the combo streak
  comboBonusPerHit = 1,   -- extra cars added per streak level
  comboMaxBonus = 6,      -- hard cap on extra cars a combo can add
  includeProps = false,   -- if true, non-car "vehicles" (props) are allowed back into the pool
  focusGuardDuration = 0.6, -- seconds to keep re-asserting player focus after a drop lands.
                             -- Note: if you manually switch vehicles yourself during this
                             -- window, the guard will switch you right back -- keep this
                             -- short rather than generous.
  maxActiveDrops = 20,    -- hard cap on rain-spawned vehicles alive at once (see below --
                           -- this is the main lag fix; nothing despawned before this existed)
}

local cooldown = 0
local timeSinceLastTrigger = math.huge -- drives the combo streak
local comboStreak = 0
local pendingDrops = {}                -- queued drops waiting out their telegraph delay
local totalDropped = 0                 -- session-lifetime counter, just for fun

-- Focus guard: after the last drop in a batch spawns, we hold onto the
-- player's original vehicle ID here and keep forcing focus back to it for
-- a short window (see onUpdate). A single enterVehicle() call right after
-- spawnNewVehicle isn't reliable -- the spawn can still be settling for a
-- frame or two, and the game's own "auto-enter the vehicle I just spawned"
-- behavior can reassert itself after our one-shot call already ran. Holding
-- the guard open for a beat wins that race regardless of exact timing.
local focusGuardVehId = nil
local focusGuardTimer = 0

-- Every vehicle chaosCarRain has spawned and is still tracking, oldest
-- first. This is what makes the drop cap (settings.maxActiveDrops)
-- possible -- without tracking these, there was no way to know what to
-- clean up. Player's own vehicle is never in this list.
local spawnedDrops = {}

local function pickRandom(t)
  return t[math.random(#t)]
end

-- Finds the actual ground height below a given (x, y), instead of assuming
-- it's the same as the player's own elevation.
--
-- This is the fix for cars occasionally spawning already sitting on the
-- ground instead of falling: the drop offset (settings.spread) moves each
-- car sideways from the player, and on any hill, slope, or uneven terrain
-- the ground under that offset point isn't at the same height as the
-- ground under the player. The old code spawned every drop at
-- `player.z + dropHeight`, so on sloped terrain a drop could land at or
-- below the real ground level at its own x/y and never actually fall.
--
-- be:getSurfaceHeightBelow(pos) raycasts straight down from pos and
-- returns the height of whatever's below it (terrain or static geometry).
-- Wrapped in pcall and with a sane fallback (the player's own z) in case
-- that call ever fails or returns something unusable -- better to fall
-- back to the old height-guess than to error out of trigger() entirely.
local function groundHeightAt(x, y, fallbackZ)
  local ok, height = pcall(function()
    return be:getSurfaceHeightBelow(vec3(x, y, fallbackZ + 1000))
  end)

  if ok and type(height) == "number" and height == height then -- last check rejects NaN
    return height
  end

  return fallbackZ
end

-- Weighted pick: models in rareWeights come up more often than the default
-- weight of 1. Falls back to a plain uniform pick if the pool is somehow
-- empty of weight data (it never actually needs to -- every model defaults
-- to weight 1).
local function pickWeighted(pool)
  local totalWeight = 0
  for _, model in ipairs(pool) do
    totalWeight = totalWeight + (rareWeights[model] or 1)
  end

  local roll = math.random() * totalWeight
  local acc = 0
  for _, model in ipairs(pool) do
    acc = acc + (rareWeights[model] or 1)
    if roll <= acc then
      return model
    end
  end

  return pool[#pool] -- floating point fallback, should basically never hit
end

-- Deletes a single tracked vehicle by id. Safe to call on an id that's
-- already gone (e.g. the player reset it or crashed it into the void) --
-- getObjectByID just returns nil and we skip it.
local function deleteTrackedVehicle(vehId)
  local obj = be:getObjectByID(vehId)
  if obj then
    pcall(function() obj:delete() end)
  end
end

-- Drops any tracked entries whose vehicle no longer actually exists (the
-- player deleted/reset it some other way), so the cap logic below isn't
-- wasting budget on ghosts.
local function pruneStaleDrops()
  local alive = {}
  for _, entry in ipairs(spawnedDrops) do
    if be:getObjectByID(entry.id) then
      table.insert(alive, entry)
    end
  end
  spawnedDrops = alive
end

-- This is the actual lag fix: the mod used to just spawn vehicles forever
-- with nothing ever cleaning them up, so a long play session (or a few
-- enthusiastic combo streaks) could leave dozens of permanent soft-body
-- vehicles on the map -- and BeamNG's physics cost scales hard with
-- vehicle count. This keeps the rain-spawned total bounded: oldest drops
-- get deleted, FIFO, to make room for new ones once the cap is hit.
local function makeRoomFor(incomingCount)
  pruneStaleDrops()
  incomingCount = math.min(incomingCount, settings.maxActiveDrops)
  while (#spawnedDrops + incomingCount) > settings.maxActiveDrops and #spawnedDrops > 0 do
    local oldest = table.remove(spawnedDrops, 1)
    deleteTrackedVehicle(oldest.id)
  end
  return incomingCount
end

-- core_vehicles.getModelList() returns every "vehicle" the game knows
-- about -- and in BeamNG's data model, a BeamNGVehicle (the JBeam-based
-- object type) covers more than just cars: traffic cones, hay bales,
-- pallets, shipping containers, etc. are all spawnable the same way a car
-- is. Left unfiltered, the pool would happily rain down props too.
--
-- Small, best-effort blocklist of default prop/decoration ids, used as a
-- safety net alongside the Type-based check below. Not exhaustive --
-- extend it if something non-car keeps showing up, or flip
-- settings.includeProps to true if you'd rather allow props back in.
local knownPropIds = {
  cones = true,
  haybale_round = true,
  haybale_square = true,
  pallet = true,
  shipping_container = true,
  streetlight = true,
  sawhorse = true,
  barrel = true,
  metal_box = true,
  piano = true,
}

-- Best-effort category check: each model entry from getModelList() often
-- carries a Type field (matching the "Cars and Trucks / Trailers / Props"
-- grouping shown in the in-game vehicle selector) as either a string or a
-- list of category strings. If that field is missing we don't exclude the
-- model on that basis alone -- better to risk an occasional prop getting
-- through than to accidentally start excluding real cars because their
-- metadata didn't look the way we expected.
local function looksLikeProp(modelKey, entry)
  if not settings.includeProps and knownPropIds[modelKey] then
    return true
  end

  if type(entry) == "table" then
    local t = entry.Type or entry.type
    if type(t) == "string" and t:lower():find("prop") then
      return true
    elseif type(t) == "table" then
      for _, category in pairs(t) do
        if type(category) == "string" and category:lower():find("prop") then
          return true
        end
      end
    end
  end

  return false
end

-- Ask the game which vehicles are actually installed, so we never try to
-- spawn something the user doesn't own/have installed. Falls back to a
-- small hardcoded list if that API isn't available for any reason.
--
-- core_vehicles.getModelList(true).models can come back either as a dict
-- keyed by model id, OR array-indexed with the real model id living inside
-- each entry. Trusting the loop key unconditionally (the old code here)
-- meant that in the array-indexed case we were inserting the meaningless
-- integer index ("23", "7", "83", ...) into the pool instead of a real
-- vehicle id -- same bug Bounty Mode had, fixed the same way.
local function refreshCarPool()
  carPool = {}
  local skippedProps = 0
  local ok, list = pcall(function()
    return core_vehicles.getModelList(true).models
  end)

  if ok and list then
    for k, v in pairs(list) do
      local modelKey = nil
      if type(k) == "string" then
        modelKey = k
      elseif type(v) == "table" then
        modelKey = v.key or v.Key or v.model or v.Name
      elseif type(v) == "string" then
        modelKey = v
      end
      if type(modelKey) == "string" and modelKey ~= "" then
        if settings.includeProps or not looksLikeProp(modelKey, v) then
          table.insert(carPool, modelKey)
        else
          skippedProps = skippedProps + 1
        end
      end
    end
  end

  if #carPool == 0 then
    log("W", "chaosCarRain", "Could not read any vehicle models from core_vehicles.getModelList() -- falling back to the built-in vehicle list.")
    carPool = fallbackPool
  elseif skippedProps > 0 then
    log("I", "chaosCarRain", "Filtered " .. skippedProps .. " prop/non-car entries out of the spawn pool.")
  end
end

-- Called once when the extension is loaded (see extensions doc)
M.onExtensionLoaded = function()
  refreshCarPool()
  log("I", "chaosCarRain", "Chaos Car Rain loaded (" .. #carPool .. " vehicles in pool). Bind 'Chaos Car Rain: Drop a Car!' in Options > Controls, or run chaosCarRain.trigger() from the Lua console.")
end

-- The extension now persists across level/map changes (see modScript.lua),
-- so without this the mod would otherwise keep trying to drop vehicles
-- from the previous level's car pool (or a stale cooldown) on a fresh map.
-- This was the actual root cause behind "doesn't work on other maps":
-- there was no persistent-load mod script at all, so the extension likely
-- wasn't surviving the level change in the first place.
M.onClientStartMission = function(levelPath)
  cooldown = 0
  comboStreak = 0
  timeSinceLastTrigger = math.huge
  pendingDrops = {}
  focusGuardVehId = nil
  focusGuardTimer = 0
  spawnedDrops = {} -- the vehicles themselves are gone with the level change; don't try to delete stale ids
  refreshCarPool()
end

-- Optional tuning, callable from the Lua console:
--   chaosCarRain.setDropCount(1)
--   chaosCarRain.setCooldown(2)
M.setDropCount = function(n)
  n = tonumber(n)
  if not n or n < 1 then
    ui_message("Drop count must be a number >= 1", 3, "chaosCarRain")
    return
  end
  settings.dropCount = math.floor(n)
  ui_message("Chaos Car Rain: drop count set to " .. settings.dropCount, 2, "chaosCarRain")
end

M.setCooldown = function(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds < 0 then
    ui_message("Cooldown must be a number >= 0", 3, "chaosCarRain")
    return
  end
  settings.cooldownTime = seconds
  ui_message("Chaos Car Rain: cooldown set to " .. settings.cooldownTime .. "s", 2, "chaosCarRain")
end

-- Optional tuning, callable from the Lua console:
--   chaosCarRain.setCooldownStep(2)
-- How many seconds each increase/decreaseCooldown() keybind press adds or
-- removes. Kept separate from cooldownTime itself so you can bind a coarse
-- or fine adjustment step independent of whatever the cooldown currently is.
M.setCooldownStep = function(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds <= 0 then
    ui_message("Cooldown step must be a number > 0", 3, "chaosCarRain")
    return
  end
  settings.cooldownStep = seconds
  ui_message("Chaos Car Rain: cooldown step set to " .. settings.cooldownStep .. "s", 2, "chaosCarRain")
end

-- Live keybind adjusters -- bound to keys via the input action file so the
-- cooldown can be tuned on the fly, mid-session, without opening the Lua
-- console. Clamped to [cooldownMin, cooldownMax] (defaults 0-60s); go
-- through setCooldown() directly instead if you deliberately want something
-- outside that range. Adjusting settings.cooldownTime here does NOT touch
-- the cooldown timer already in progress -- it only changes how long the
-- *next* recharge takes, so you never lose (or gain) time already banked
-- toward the current cooldown by tweaking the step mid-recharge.
M.increaseCooldown = function()
  settings.cooldownTime = math.min(settings.cooldownMax, settings.cooldownTime + settings.cooldownStep)
  ui_message("Chaos Car Rain: cooldown set to " .. settings.cooldownTime .. "s", 1, "chaosCarRain")
end

M.decreaseCooldown = function()
  settings.cooldownTime = math.max(settings.cooldownMin, settings.cooldownTime - settings.cooldownStep)
  ui_message("Chaos Car Rain: cooldown set to " .. settings.cooldownTime .. "s", 1, "chaosCarRain")
end

M.setTelegraphDelay = function(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds < 0 then
    ui_message("Telegraph delay must be a number >= 0", 3, "chaosCarRain")
    return
  end
  settings.telegraphDelay = seconds
  ui_message("Chaos Car Rain: telegraph delay set to " .. settings.telegraphDelay .. "s", 2, "chaosCarRain")
end

M.setComboWindow = function(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds < 0 then
    ui_message("Combo window must be a number >= 0 (0 disables combos)", 3, "chaosCarRain")
    return
  end
  settings.comboWindow = seconds
  ui_message("Chaos Car Rain: combo window set to " .. settings.comboWindow .. "s", 2, "chaosCarRain")
end

-- Props (traffic cones, hay bales, etc.) are excluded from the pool by
-- default -- flip this on if you actually want them raining down too.
M.setIncludeProps = function(enabled)
  settings.includeProps = enabled and true or false
  refreshCarPool()
  ui_message("Chaos Car Rain: props are now " .. (settings.includeProps and "included" or "excluded")
    .. " (" .. #carPool .. " vehicles in pool)", 2, "chaosCarRain")
end

-- Spawns a single queued drop -- pulled out of trigger() so both the
-- immediate path and the delayed/telegraphed path share one code path.
-- autoEnterVehicle = false is a best-effort hint to spawnNewVehicle not to
-- switch control to this vehicle; the focus guard in onUpdate is what
-- actually guarantees it, in case that option isn't honored.
-- Returns ok, vehId -- vehId is nil if we couldn't determine it (spawn
-- still succeeds either way, it just won't be tracked for the drop cap).
local function spawnOneDrop(model, spawnPos)
  local ok, result = pcall(function()
    return core_vehicles.spawnNewVehicle(model, {
      pos = spawnPos,
      rot = quat(0, 0, 0, 1),
      autoEnterVehicle = false,
    })
  end)

  if not ok then
    log("E", "chaosCarRain", "spawnNewVehicle failed for '" .. tostring(model) .. "': " .. tostring(result))
    return false, nil
  end

  local vehId = nil
  if type(result) == "table" and result.getID then
    local idOk, id = pcall(function() return result:getID() end)
    if idOk then vehId = id end
  elseif type(result) == "number" then
    vehId = result
  end

  return true, vehId
end

-- Forces focus back onto the given vehicle id if it isn't already the
-- active one. Returns true if a switch was made.
local function reclaimFocus(vehId)
  local playerVeh = be:getPlayerVehicle(0)
  if playerVeh and playerVeh:getID() == vehId then
    return false
  end

  local originalVeh = be:getObjectByID(vehId)
  if originalVeh then
    be:enterVehicle(0, originalVeh)
    return true
  end

  return false
end

-- Called once per GFX frame (see extensions doc). Ticks the cooldown timer,
-- tracks time since the last trigger (for combo streaks), resolves any
-- queued drops once their telegraph delay has elapsed, and -- while the
-- focus guard is active -- keeps forcing control back onto the player's
-- original vehicle in case a spawn reclaims it after the fact.
M.onUpdate = function(dtReal, dtSim, dtRaw)
  if cooldown > 0 then
    cooldown = math.max(0, cooldown - dtReal)
  end

  timeSinceLastTrigger = timeSinceLastTrigger + dtReal

  if #pendingDrops > 0 then
    local stillPending = {}

    for _, drop in ipairs(pendingDrops) do
      drop.timeLeft = drop.timeLeft - dtReal
      if drop.timeLeft <= 0 then
        local ok, vehId = spawnOneDrop(drop.model, drop.spawnPos)
        if ok then
          totalDropped = totalDropped + 1
          if vehId then
            table.insert(spawnedDrops, { id = vehId })
          end
        end

        -- Immediately try to reclaim focus, then open the guard window so
        -- we keep re-asserting it for a bit -- covers the case where the
        -- spawn (or the game's own auto-enter behavior) steals control a
        -- frame or two after this point rather than exactly on spawn.
        reclaimFocus(drop.playerVehId)
        focusGuardVehId = drop.playerVehId
        focusGuardTimer = settings.focusGuardDuration

        if drop.isLastInBatch then
          if drop.comboLevel > 1 then
            ui_message(string.format(pickRandom(comboMessages), drop.comboLevel), 3, "chaosCarRain")
          else
            ui_message(pickRandom(funMessages), 3, "chaosCarRain")
          end
        end
      else
        table.insert(stillPending, drop)
      end
    end

    pendingDrops = stillPending
  end

  if focusGuardTimer > 0 then
    focusGuardTimer = math.max(0, focusGuardTimer - dtReal)
    if focusGuardVehId then
      reclaimFocus(focusGuardVehId)
    end
  end
end

-- The actual "fun button". Bound to a keypress via the input action file,
-- but you can also call it directly from the Lua console:
--   chaosCarRain.trigger()
M.trigger = function()
  if cooldown > 0 then
    ui_message(string.format("Chaos Car Rain recharging... %.1fs", cooldown), 1, "chaosCarRain")
    return
  end

  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then
    ui_message("Get in a vehicle first!", 3, "chaosCarRain")
    return
  end

  if #carPool == 0 then
    refreshCarPool()
  end

  -- Combo streak: triggering again inside comboWindow seconds builds the
  -- streak and adds a couple of extra cars (capped); waiting it out, or
  -- setting comboWindow to 0, resets it back to a plain single-hit drop.
  if settings.comboWindow > 0 and timeSinceLastTrigger <= settings.comboWindow then
    comboStreak = comboStreak + 1
  else
    comboStreak = 1
  end
  timeSinceLastTrigger = 0

  local comboBonus = math.min(
    (comboStreak - 1) * settings.comboBonusPerHit,
    settings.comboMaxBonus
  )
  local dropCountThisTrigger = settings.dropCount + comboBonus

  -- Make room in the drop cap *before* queuing anything, so the pool
  -- never has more than maxActiveDrops rain-spawned vehicles alive at
  -- once -- this is what actually keeps the mod from snowballing into
  -- unplayable framerates over a play session. If a single trigger would
  -- ask for more than the cap allows, it's clamped down to the cap.
  dropCountThisTrigger = makeRoomFor(dropCountThisTrigger)

  if dropCountThisTrigger <= 0 then
    ui_message("Chaos Car Rain: max active drops is 0, nothing to spawn.", 2, "chaosCarRain")
    return
  end

  local pos = playerVeh:getPosition()
  local playerVehId = playerVeh:getID()

  ui_message(pickRandom(warningMessages), 2, "chaosCarRain")

  for i = 1, dropCountThisTrigger do
    local model = pickWeighted(carPool)

    -- Random-ish offset so cars don't land exactly on top of each other
    -- (or exactly on your roof every time -- though sometimes they will,
    -- and that's the fun part).
    local offsetX = (math.random() - 0.5) * settings.spread
    local offsetY = (math.random() - 0.5) * settings.spread
    local spawnX = pos.x + offsetX
    local spawnY = pos.y + offsetY

    -- Ground height *at this drop's own x/y*, not the player's -- see
    -- groundHeightAt() above. This is what actually fixes cars occasionally
    -- spawning already on the ground on sloped/uneven terrain.
    local groundZ = groundHeightAt(spawnX, spawnY, pos.z)
    local offsetZ = settings.dropHeight + (i - 1) * 3 -- stagger height a bit so they don't all spawn stacked
    local spawnPos = vec3(spawnX, spawnY, groundZ + offsetZ)

    -- Queued instead of spawned immediately -- onUpdate() resolves each
    -- entry once its telegraphDelay has elapsed, giving the warning
    -- message above a beat to land before cars actually appear. A little
    -- per-drop stagger keeps a multi-car drop from landing in one
    -- perfectly simultaneous thud.
    table.insert(pendingDrops, {
      model = model,
      spawnPos = spawnPos,
      timeLeft = settings.telegraphDelay + (i - 1) * 0.12,
      playerVehId = playerVehId,
      isLastInBatch = (i == dropCountThisTrigger),
      comboLevel = comboStreak,
    })
  end

  -- Scale cooldown with the *actual* drop count (base + combo bonus), so
  -- bigger combo drops recharge a bit slower too.
  cooldown = settings.cooldownTime + (dropCountThisTrigger - 1) * 0.5
end

-- Read-only session stat, callable from the Lua console:
--   chaosCarRain.getTotalDropped()
M.getTotalDropped = function()
  ui_message("Chaos Car Rain: " .. totalDropped .. " vehicles dropped this session.", 3, "chaosCarRain")
  return totalDropped
end

-- The main performance lever. Lower this if things are still chuggy, or
-- call it with 0 to effectively disable rain-spawned vehicles piling up
-- at all (each new drop will immediately clear out the previous ones).
M.setMaxActiveDrops = function(n)
  n = tonumber(n)
  if not n or n < 0 then
    ui_message("Max active drops must be a number >= 0", 3, "chaosCarRain")
    return
  end
  settings.maxActiveDrops = math.floor(n)
  makeRoomFor(0) -- trim immediately if the new cap is lower than what's currently out there
  ui_message("Chaos Car Rain: max active drops set to " .. settings.maxActiveDrops, 2, "chaosCarRain")
end

-- Instantly deletes every vehicle this mod has spawned and is still
-- tracking -- handy for clawing back framerate mid-session without
-- waiting for the cap to catch up naturally, or just to clean up before
-- you're done messing around.
M.clearDropped = function()
  pruneStaleDrops()
  local count = #spawnedDrops
  for _, entry in ipairs(spawnedDrops) do
    deleteTrackedVehicle(entry.id)
  end
  spawnedDrops = {}
  ui_message("Chaos Car Rain: cleared " .. count .. " dropped vehicle(s).", 3, "chaosCarRain")
end

return M
