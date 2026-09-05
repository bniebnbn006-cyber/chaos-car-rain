-- Chaos Car Rain mod script
--
-- Same fix applied to the other mods in the pack: BeamNG doesn't reliably
-- auto-load a custom GE extension just because it's discovered, and by
-- default any extension that IS loaded gets unloaded again on every level
-- change. This was the actual root cause of the "doesn't work on other
-- maps" report -- without this, the extension likely wasn't surviving the
-- level change at all. Marking this as a "manual unload" extension makes
-- the engine load it once at startup and keep it loaded across level/map
-- changes, so chaosCarRain.trigger() and the keybind work immediately
-- without needing extensions.load('chaosCarRain') typed manually first.
--
-- Docs: https://documentation.beamng.com/modding/programming/extensions/

setExtensionUnloadMode("chaosCarRain", "manual")
loadManualUnloadExtensions()
