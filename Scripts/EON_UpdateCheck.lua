-- EON_UpdateCheck.lua
-- Startup action — dormant until Swing heartbeat detected in gmem.
-- Handles update checks and "open URL" requests from Swing.
--
-- First manual run self-registers as a REAPER startup action.
-- After that, auto-runs every REAPER launch with no user intervention.
--
-- gmem layout (shared with Swing via "Swing_Media_Transfer"):
--   1711  GS_SWING_ALIVE       counter incremented every @block (0 = no Swing)
--   1712  GS_UPDATE_REQUEST    0=none, 1=check, 2=open URL
--   1713  GS_UPDATE_STATE      0=idle, 1=checking, 2=up-to-date, 3=available
--   1714–1718  GS_LATEST_VER   5-char version string (e.g. "2.1.1")

---------------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------------
local SCRIPT_NAME       = "EON_UpdateCheck"
local GMEM_SECTION      = "Swing_Media_Transfer"
-- GitHub Releases API for the public Swing-2 repo. Returns JSON with
-- tag_name (e.g. "2.1.3") and html_url (release page). Switched from
-- eon-studios.com/updates/swing.json so we have a single source of truth
-- alongside the ReaPack distribution -- bumping the GitHub release also
-- bumps the available-update notification.
local UPDATE_URL        = "https://api.github.com/repos/mequaz-sudo/Swing-2/releases/latest"
-- Must match the latest released ReaPack index.xml <version> AND the
-- JSFX version (Swing_ReaKit.jsfx: version: 2.1). Compared against the
-- GitHub tag_name (stripped of leading "v" if present).
local CURRENT_VERSION   = "2.1.3"
local POLL_INTERVAL     = 5.0        -- seconds between heartbeat polls
local HEARTBEAT_TIMEOUT = 2.0        -- seconds of stale counter = Swing gone

-- gmem slots
local GS_SWING_ALIVE       = 1711
local GS_UPDATE_REQUEST    = 1712
local GS_UPDATE_STATE      = 1713
local GS_LATEST_VER_BASE   = 1714  -- 5 slots: 1714–1718

---------------------------------------------------------------------------
-- SELF-REGISTER AS STARTUP ACTION (one-time).
--
-- The block written to __startup.lua is SELF-CLEANING: when the script
-- file is removed (e.g. via ReaPack uninstall), the block detects that
-- its registered command ID can no longer be resolved, strips itself
-- out of __startup.lua, and clears the registered_v3 ExtState so a
-- future reinstall registers fresh. No manual cleanup needed.
--
-- Bumped registered_v2 -> registered_v3 to force existing installs
-- (which have the old single-line format) to re-register and pick up
-- the new self-cleaning block on next script run.
---------------------------------------------------------------------------
local function self_register()
  local _, script_path = reaper.get_action_context()
  local key = SCRIPT_NAME .. "_registered_v3"
  if reaper.GetExtState(SCRIPT_NAME, key) == "1" then return end

  -- Register in action list (so manual invocation still works)
  local cmd_id = reaper.AddRemoveReaScript(true, 0, script_path, true)
  if not cmd_id or cmd_id <= 0 then return end

  local res_path = reaper.GetResourcePath()
  local startup_path = res_path .. "/Scripts/__startup.lua"

  local existing = ""
  local fr = io.open(startup_path, "r")
  if fr then existing = fr:read("*a"); fr:close() end

  -- Strip ALL prior versions of our block so re-registration is idempotent:
  --   v3+: BEGIN...END block (new self-cleaning format)
  --   v1/v2: single-line format ("-- EON:NAME" marker + next line)
  local marker = "-- EON:" .. SCRIPT_NAME
  local esc = marker:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
  existing = existing:gsub("\n?" .. esc .. " BEGIN.-" .. esc .. " END\n?", "")
  existing = existing:gsub("\n?" .. esc .. "\n[^\n]*\n?", "")

  -- Resolve a stable command token. Named command IDs ("_RSxxxxx") survive
  -- action-list rebuilds; the raw int can change.
  local named_id = reaper.ReverseNamedCommandLookup(cmd_id)
  local cmd_token = named_id
    and ('reaper.NamedCommandLookup("_' .. named_id .. '")')
    or tostring(cmd_id)

  -- Self-cleaning block. When `id` resolves (script file present), runs
  -- the script as usual. When `id == 0` (file removed via ReaPack uninstall),
  -- strips this block from __startup.lua and clears the registered_v3
  -- ExtState. The cleanup runs at most once per uninstall -- once the block
  -- is gone, this code never executes again.
  local block =
    "\n" .. marker .. " BEGIN\n" ..
    "do local id=" .. cmd_token .. "\n" ..
    "if id~=0 then reaper.Main_OnCommand(id,0) else\n" ..
    "  local p=reaper.GetResourcePath()..\"/Scripts/__startup.lua\"\n" ..
    "  local f=io.open(p,'r'); if f then local c=f:read('*a'); f:close()\n" ..
    "    c=c:gsub('\\n?%-%- EON:" .. SCRIPT_NAME .. " BEGIN.-%-%- EON:" .. SCRIPT_NAME .. " END\\n?','')\n" ..
    "    local fw=io.open(p,'w'); if fw then fw:write(c); fw:close() end end\n" ..
    "  reaper.SetExtState('" .. SCRIPT_NAME .. "','" .. SCRIPT_NAME .. "_registered_v3','',true)\n" ..
    "end end\n" ..
    marker .. " END\n"

  local fw = io.open(startup_path, "w")
  if fw then
    fw:write(existing .. block)
    fw:close()
  end

  reaper.SetExtState(SCRIPT_NAME, key, "1", true)
  reaper.ShowConsoleMsg("[EON] " .. SCRIPT_NAME .. " registered as startup action (auto-cleans on uninstall).\n")
end

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
local last_heartbeat   = 0     -- last seen counter value
local last_poll_time   = 0     -- time of last heartbeat read
local swing_alive      = false
local checking_update  = false

---------------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------------
local function gmem_read(slot)
  return reaper.gmem_read(slot)
end

local function gmem_write(slot, val)
  reaper.gmem_write(slot, val)
end

local function write_version_string(str)
  for i = 0, 4 do
    local ch = (i < #str) and string.byte(str, i + 1) or 0
    gmem_write(GS_LATEST_VER_BASE + i, ch)
  end
end

local function open_url(url)
  local os_name = reaper.GetOS()
  if os_name:match("Win") then
    os.execute('start "" "' .. url .. '"')
  elseif os_name:match("OSX") or os_name:match("macOS") then
    os.execute('open "' .. url .. '"')
  else
    os.execute('xdg-open "' .. url .. '"')
  end
end

---------------------------------------------------------------------------
-- UPDATE CHECK (non-blocking via ExecProcess)
---------------------------------------------------------------------------
local function start_update_check()
  if checking_update then return end
  checking_update = true
  gmem_write(GS_UPDATE_STATE, 1) -- checking

  -- Fetch version JSON via curl (available on all platforms)
  local os_name = reaper.GetOS()
  local cmd
  if os_name:match("Win") then
    cmd = 'cmd /c curl -s -m 5 "' .. UPDATE_URL .. '"'
  else
    cmd = 'curl -s -m 5 "' .. UPDATE_URL .. '"'
  end

  -- ExecProcess returns "0\n<stdout>" prefix on success. Skip it before
  -- parsing JSON. On Windows we also get whatever stderr leaks through.
  local retval = reaper.ExecProcess(cmd, 6000) -- 6s timeout
  if retval and retval ~= "" then
    -- GitHub Releases API JSON structure (only the fields we care about):
    --   {"tag_name":"2.1.3","html_url":"https://github.com/.../releases/tag/2.1.3", ...}
    -- tag_name may start with "v" depending on how the release was tagged;
    -- strip it before comparison.
    local ver = retval:match('"tag_name"%s*:%s*"([^"]+)"')
    local dl  = retval:match('"html_url"%s*:%s*"([^"]+)"')
    if ver then
      ver = ver:gsub("^v", "")
    end

    if ver then
      write_version_string(ver:sub(1, 5))  -- gmem slot is 5 chars
      -- Compare with current version. Numeric semver compare so we don't
      -- false-fire "available" when the user is AHEAD of GitHub (e.g. a
      -- dev build with a higher version than the latest release).
      local function parse_semver(v)
        local a, b, c = v:match("^(%d+)%.(%d+)%.?(%d*)")
        return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
      end
      local ga, gb, gc = parse_semver(ver)
      local la, lb, lc = parse_semver(CURRENT_VERSION)
      local github_newer = (ga > la) or
                           (ga == la and gb > lb) or
                           (ga == la and gb == lb and gc > lc)
      if github_newer then
        gmem_write(GS_UPDATE_STATE, 3) -- available
        if dl then
          reaper.SetExtState(SCRIPT_NAME, "download_url", dl, false)
        end
      else
        gmem_write(GS_UPDATE_STATE, 2) -- up-to-date (or ahead)
      end
    else
      gmem_write(GS_UPDATE_STATE, 0) -- failed silently → idle
    end
  else
    gmem_write(GS_UPDATE_STATE, 0) -- network error → idle
  end

  checking_update = false
end

---------------------------------------------------------------------------
-- HANDLE REQUESTS FROM SWING
---------------------------------------------------------------------------
local function handle_requests()
  local req = gmem_read(GS_UPDATE_REQUEST)

  if req == 1 then
    -- Check for updates
    gmem_write(GS_UPDATE_REQUEST, 0)
    start_update_check()

  elseif req == 2 then
    -- Open download URL
    gmem_write(GS_UPDATE_REQUEST, 0)
    local url = reaper.GetExtState(SCRIPT_NAME, "download_url")
    if url and url ~= "" then
      open_url(url)
    end
  end
end

---------------------------------------------------------------------------
-- HEARTBEAT DETECTION
---------------------------------------------------------------------------
local function check_heartbeat()
  local now = reaper.time_precise()
  if now - last_poll_time < POLL_INTERVAL then return end
  last_poll_time = now

  local beat = gmem_read(GS_SWING_ALIVE)

  if beat ~= last_heartbeat and beat > 0 then
    -- Counter changed → Swing is alive
    last_heartbeat = beat
    if not swing_alive then
      swing_alive = true
      -- Swing just appeared — reset update state
      gmem_write(GS_UPDATE_STATE, 0)
    end
  elseif beat == last_heartbeat then
    -- Counter stale → Swing removed or no Swing
    if swing_alive then
      swing_alive = false
    end
  end
end

---------------------------------------------------------------------------
-- MAIN LOOP
---------------------------------------------------------------------------
local function main()
  check_heartbeat()

  if swing_alive then
    handle_requests()
  end

  reaper.defer(main)
end

---------------------------------------------------------------------------
-- INIT
---------------------------------------------------------------------------
self_register()
reaper.gmem_attach(GMEM_SECTION)
reaper.defer(main)
reaper.atexit(function()
  -- Clean exit — no persistent state to clear
end)
