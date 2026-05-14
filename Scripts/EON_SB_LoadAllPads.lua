-- EON_SB_LoadAllPads.lua
-- Companion script: Open file dialog to load a .swing kit file
-- (c) EON Studios

reaper.gmem_attach("Swing_Media_Transfer")
local CMD = 0
local BRIDGE_ALIVE = 99

-- Need bridge alive to handle kit loading
if reaper.gmem_read(BRIDGE_ALIVE) > 0 and math.floor(reaper.gmem_read(CMD)) == 0 then
  reaper.gmem_write(CMD, 2)  -- CMD 2 = import kit (opens file browser via bridge)
end
