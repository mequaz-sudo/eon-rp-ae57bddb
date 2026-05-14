-- EON_Toggle_Swing_Browser.lua
--
-- Toggles the EON Swing browser open/closed as a standalone REAPER action.
-- No Swing JSFX required — sample preview, search, categories, BPM/key
-- analysis, and recursive scan all work without Swing on a track. Loading
-- samples to a Swing pad still requires the Swing JSFX + bridge running,
-- but otherwise the browser is fully usable as a generic media browser.
--
-- Behaviour:
--   - If browser is closed → open it
--   - If browser is open   → close it (signals the running instance to exit)
--
-- ─── HOW TO INSTALL AS A REAPER ACTION ───────────────────────────────
--   1. REAPER → Actions → Action List…
--   2. Click "ReaScript: Load…" (top-right of the dialog)
--   3. Browse to this file (EON_Toggle_Swing_Browser.lua) → Open
--   4. The action now appears in the action list as
--        "Script: EON_Toggle_Swing_Browser.lua"
--      Bind a keyboard shortcut or add it to a toolbar.

local sep = package.config:sub(1, 1)

local function _get_script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)") or ""
  return path:match("^(.*)[/\\]") or ""
end

local script_dir   = _get_script_dir()
local browser_path = script_dir .. sep .. "Swing_Browser.lua"

-- The browser must live alongside this launcher (both ship inside the
-- EON Scripts folder via the installer). If someone moved the launcher
-- out by hand, fail loudly rather than silently.
local f = io.open(browser_path, "r")
if not f then
  reaper.MB(
    "Swing_Browser.lua not found in:\n" .. script_dir ..
    "\n\nThis launcher must live in the same folder as the browser.",
    "EON Toggle Swing Browser",
    0
  )
  return
end
f:close()

-- If the browser is already running, signal it to close. The browser's
-- defer loop checks the "browser_close" ExtState every frame and exits
-- gracefully when it sees "1" — that hook is at Swing_Browser.lua:~4414.
--
-- Stale-state recovery: cross-check ExtState against gmem[GS_BROWSER_OPEN]
-- (slot 1382). If ExtState says running but gmem disagrees, the previous
-- browser session crashed/died without cleanup. Clear the stale flag and
-- proceed to launch a fresh window.
if reaper.GetExtState("Swing", "browser_running") == "1" then
  reaper.gmem_attach("DrumKit_ReaKit")
  if reaper.gmem_read(1382) == 0 then
    -- Stale: ExtState says running but gmem says closed. Clear and relaunch.
    reaper.SetExtState("Swing", "browser_running", "0", false)
  else
    -- Genuinely running — signal close
    reaper.SetExtState("Swing", "browser_close", "1", false)
    return
  end
end

-- Browser not running → register Swing_Browser.lua as a temporary REAPER
-- action, fire it, then unregister so it doesn't add a duplicate
-- "Script: Swing_Browser" entry to the action list every time we run.
-- The browser itself owns its defer loop — Main_OnCommand returns
-- immediately and the loop keeps spinning in its own context until the
-- user closes the window (or this script is run again to toggle).
local cmd_id = reaper.AddRemoveReaScript(true, 0, browser_path, true)
if cmd_id and cmd_id > 0 then
  reaper.Main_OnCommand(cmd_id, 0)
  reaper.AddRemoveReaScript(false, 0, browser_path, true)
else
  reaper.MB(
    "REAPER could not register Swing_Browser.lua.\n\n" ..
    "Check that the file is readable and not blocked by antivirus.",
    "EON Toggle Swing Browser",
    0
  )
end
