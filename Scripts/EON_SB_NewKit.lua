-- EON_SB_NewKit.lua
-- Companion script: Clear all unlocked pads and start a new kit
-- (c) EON Studios

reaper.gmem_attach("Swing_Media_Transfer")
local GS_COMPANION_CMD = 1710

-- Only send if no companion command is pending
if math.floor(reaper.gmem_read(GS_COMPANION_CMD)) == 0 then
  reaper.gmem_write(GS_COMPANION_CMD, 4)  -- 4 = new kit
end
