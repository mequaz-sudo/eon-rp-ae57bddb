-- EON_SB_LoadSelectedPads.lua
-- Companion script: Open the EON Sample Browser targeting the selected pad
-- (c) EON Studios

reaper.gmem_attach("Swing_Media_Transfer")
local CMD = 0
local GS_BROWSE_PAD = 1437

local BRIDGE_ALIVE = 99

-- Read the currently selected pad from JSFX
local pad = math.floor(reaper.gmem_read(GS_BROWSE_PAD))
if pad < 0 then pad = 0 end
if pad > 15 then pad = 15 end

-- Open browser targeting this pad (CMD 60 = open/toggle browser)
if reaper.gmem_read(BRIDGE_ALIVE) > 0 and math.floor(reaper.gmem_read(CMD)) == 0 then
  reaper.gmem_write(1, pad)   -- PARAM1 = target pad
  reaper.gmem_write(CMD, 60)  -- CMD 60 = open browser
end
