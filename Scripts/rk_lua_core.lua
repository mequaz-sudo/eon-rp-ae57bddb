-- ReaKit Lua Core — Shared Utilities
-- (c) EON Studios — All Rights Reserved
--
-- Shared constants, path helpers, gmem I/O, color conversion, and file
-- utilities for all EON Lua scripts (Swing Browser, Kit Bridge, etc.).
--
-- Usage:
--   local core = dofile(script_dir .. sep .. "rk_lua_core.lua")

local core = {}

-- ═══════════════════════════════════════════════════════════════════════════════
-- OS / PATH
-- ═══════════════════════════════════════════════════════════════════════════════

core.sep = package.config:sub(1,1)
core.is_windows = core.sep == "\\"

function core.get_script_dir(stack_level)
  local info = debug.getinfo(stack_level or 2, "S")
  local path = info.source:match("@?(.*)")
  return path:match("^(.*)[/\\]") or ""
end

function core.get_extension(filename)
  return (filename:match("%.([^%.]+)$") or ""):lower()
end

function core.get_parent_dir(path)
  if not path or path == "" then return "" end
  path = path:gsub("[/\\]+$", "")
  -- Handle UNC paths (\\server\share)
  local unc = path:match("^(\\\\[^\\]+\\[^\\]+)$")
  if unc then return unc end
  local parent = path:match("^(.*)[/\\]")
  if not parent or parent == "" then
    return core.is_windows and path:match("^(%a:)") or "/"
  end
  return parent
end

function core.get_folder_name(path)
  if not path or path == "" then return "" end
  path = path:gsub("[/\\]+$", "")
  return path:match("[/\\]([^/\\]+)$") or path
end

function core.get_kits_dir()
  local resource = reaper.GetResourcePath()
  local dir = resource .. core.sep .. "Data" .. core.sep .. "Swing_Kits"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir
end

-- Persistent analysis cache (BPM/key short-circuit data, see Swing_Browser.lua).
-- Lives next to Swing_Kits so it ships+backs-up with the rest of Swing's data.
function core.get_cache_dir()
  local resource = reaper.GetResourcePath()
  local dir = resource .. core.sep .. "Data" .. core.sep .. "Swing_Cache"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- FORMAT HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════

function core.format_size(bytes)
  if not bytes or bytes < 0 then return "\xE2\x80\x94" end
  if bytes >= 1048576 then
    return string.format("%.1f MB", bytes / 1048576)
  elseif bytes >= 1024 then
    return string.format("%.0f KB", bytes / 1024)
  else
    return string.format("%d B", bytes)
  end
end

function core.format_duration(sec)
  if not sec or sec <= 0 then return "\xE2\x80\x94" end
  if sec < 60 then
    return string.format("0:%04.1f", sec)
  else
    local m = math.floor(sec / 60)
    local s = sec - m * 60
    return string.format("%d:%04.1f", m, s)
  end
end

function core.lua_quote(s)
  -- Escape backslash first (so it doesn't double up on subsequent escapes),
  -- then quote, newline, AND carriage return. CR appears in pasted Windows
  -- text and would otherwise terminate a "..." literal at load-time.
  return '"' .. s
    :gsub('\\', '\\\\')
    :gsub('"',  '\\"')
    :gsub('\n', '\\n')
    :gsub('\r', '\\r')
    .. '"'
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- AUDIO FILE EXTENSIONS
-- ═══════════════════════════════════════════════════════════════════════════════

core.NATIVE_EXT = {
  wav=true, aif=true, aiff=true, flac=true, mp3=true, ogg=true,
  bwf=true, w64=true, wv=true, caf=true
}

-- Kit formats Swing can import. SFZ only — multi-format support via
-- ConvertWithMoss was removed because it was unreliable and not part of
-- the v1 tutorial scope.
core.KIT_EXT = { sfz = true }

core.ALL_AUDIO_EXT = {}
for k in pairs(core.NATIVE_EXT) do core.ALL_AUDIO_EXT[k] = true end
for k in pairs(core.KIT_EXT)    do core.ALL_AUDIO_EXT[k] = true end

function core.is_audio_file(filename)
  return core.ALL_AUDIO_EXT[core.get_extension(filename)] or false
end

function core.is_native_audio(filename)
  return core.NATIVE_EXT[core.get_extension(filename)] or false
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- GMEM LAYOUT CONSTANTS (must match JSFX)
-- ═══════════════════════════════════════════════════════════════════════════════

core.GMEM = {
  CMD           = 0,
  PARAM1        = 1,
  PARAM2        = 2,
  PARAM3        = 3,
  NAMELEN       = 3,
  NAME_BASE     = 4,
  UNDO_ACK      = 95,
  UNDO_DESC     = 96,
  LOCK          = 97,
  INSTANCE      = 98,
  BRIDGE_ALIVE  = 99,
  META_BASE     = 100,
  META_PP       = 80,
  PADNAME_BASE  = 1720,
  PADNAME_LEN   = 32,
  AUDIOLEN_BASE = 2256,
  AUDIO_BASE    = 3000,

  NUM_PADS      = 16,
  MAX_LAYERS    = 4,
  SLOT_SIZE     = 4000000,
  LAYER_SIZE    = 1000000,

  -- Global state addresses
  GS_LOCK_BITMASK     = 1380,
  GS_BROWSER_VISIBLE  = 1381,
  GS_BROWSER_OPEN     = 1382,
  GS_KIT_NAME_BASE    = 1383,
  GS_KIT_NAME_LEN     = 16,
  GS_PAD_BPM_BASE     = 1400,
  GS_PAD_KEY_BASE     = 1416,
  GS_COL_EFFECTIVE_S  = 1432,   -- effective saturation = theme S × intensity
  GS_COL_EFFECTIVE_L  = 1433,   -- effective lightness  = theme L
  GS_WINDOW_W          = 1435,
  GS_WINDOW_H          = 1436,
  GS_BROWSE_PAD        = 1437,
  GS_BROWSER_PATH_LEN  = 1439,
  GS_PAD_SELECT_REQ    = 1440,
  GS_BROWSE_LAYER      = 1441,   -- layer index for CMD 64 (browser layer load)
  GS_TRACK_NUM         = 1442,
  GS_PAD_TRIGGER       = 1443,
  GS_KIT_LOAD_REQ      = 1444,   -- browser kit load: 0=idle, 1=request, 2=data ready
  GS_AUDIO_REPAIR_REQ  = 1434,   -- JSFX → bridge: instance_id needs sidecar reload (audio truncated by chunk size limit on Undo/chunk restore); 0 = no request
  GS_BROWSER_PATH      = 1450,
  GS_BROWSER_PATH_MAX  = 260,
  GS_PAD_OFFSET_BASE   = 2232,   -- per-pad sample offset (16 floats)
  GS_COMPANION_CMD     = 1710,
  GS_MEDIA_EXPLORER_OPEN = 1719, -- bridge → JSFX: 1 if REAPER Media Explorer is open
  -- Header-bar UNDO/REDO buttons: bridge polls REAPER's undo stack
  -- and publishes next-action descriptions + availability flags here.
  GS_UNDO_DESC         = 2276,   -- 128-char string: next-undo description
  GS_UNDO_DESC_LEN     = 128,
  GS_REDO_DESC         = 2406,   -- 128-char string: next-redo description
  GS_REDO_DESC_LEN     = 128,
  GS_UNDO_AVAIL        = 2536,   -- 1 = undo available, 0 = stack empty
  GS_REDO_AVAIL        = 2537,   -- 1 = redo available, 0 = stack empty
  -- Live per-pad effective-mute state (mute OR muted-by-solo). JSFX writes
  -- every frame from the active browser-target instance; browser reads to
  -- dim muted pads to mirror the JSFX UI. 16 slots: 2282..2297.
  GS_PAD_MUTED_BASE    = 2538,
  -- Pending kit-load target — JSFX writes its instance_id when triggering
  -- a kit load (e.g. CMD 22 auto-load) so the receive handler routes the
  -- kit data only to that instance. Decoupled from INSTANCE (browser target)
  -- so an auto-load can't clobber the user's manual browser pick.
  GS_PENDING_LOAD_INST = 2554,
  -- Bridge → browser: 0-based FX-chain index of the active target. Paired
  -- with GS_TRACK_NUM so the browser can disambiguate stacked Swings on
  -- the same track (track_num collides; fx_index doesn't).
  GS_TARGET_FX_IDX     = 1438,
  -- ─── Instance Registry (mirrors layout in Swing_ReaKit.jsfx) ────────
  -- Each Swing instance owns a slot, written EVERY @block. The browser
  -- reads this to know which Swings are alive, then does its own one-
  -- shot track scan to map inst_id → track/fx for picker display. No
  -- bridge involvement.
  GS_INST_REG_BASE     = 2556,
  GS_INST_REG_STRIDE   = 4,
  GS_INST_REG_MAX      = 16,
  GS_INST_REG_TIMEOUT  = 3.0,
  -- Per-slot field offsets (slot_base + offset)
  GS_INST_REG_OFF_ID         = 0,
  GS_INST_REG_OFF_HEARTBEAT  = 1,
  GS_INST_REG_OFF_PAD_COUNT  = 2,
  GS_INST_REG_OFF_KIT_HASH   = 3,
  -- ─── Per-pad action channel (browser → JSFX) ───────────────────────
  -- Used by the browser's note-per-pad selector and right-click menu to
  -- drive per-pad state changes. Only the browser-target Swing acts.
  -- target = -1 idle, 0..15 pad index. code: 1=mute, 2=solo, 3=reverse,
  -- 4=set note (value=MIDI note 0..127), 5=set output (value=output 0..15).
  GS_PAD_ACTION_TARGET = 2620,
  GS_PAD_ACTION_CODE   = 2621,
  GS_PAD_ACTION_VALUE  = 2622,
  -- Action codes (semantic names — keep in sync with JSFX)
  PAD_ACTION_MUTE      = 1,
  PAD_ACTION_SOLO      = 2,
  PAD_ACTION_REVERSE   = 3,
  PAD_ACTION_SET_NOTE  = 4,
  PAD_ACTION_SET_OUT   = 5,
  -- JSFX → bridge: pad-click → MCP/TCP track select. 1-indexed pad
  -- (1..16), 0 = no request (bridge writes 0 back after consuming).
  -- Gated on JSFX side by pad_click_selects_track preference (off
  -- by default; opt-in via Colors right-click menu).
  GS_PAD_TRACK_SELECT  = 2623,
  -- Swing_Browser.lua → JSFX: set to 1 when the user clicked BROWSE
  -- but ReaImGui isn't installed. JSFX shows a banner in the LCD area
  -- (rk_swing_ui_state.jsfx-inc, alongside the bridge-not-running
  -- overlay). Cleared on next successful browser launch.
  GS_REAIMGUI_MISSING  = 2624,
}

core.GMEM_NAME = "Swing_Media_Transfer"

-- ═══════════════════════════════════════════════════════════════════════════════
-- GMEM STRING I/O
-- ═══════════════════════════════════════════════════════════════════════════════

function core.gmem_read_string(base, len_addr, max_len)
  local slen = math.min(math.floor(reaper.gmem_read(len_addr)), max_len)
  local chars = {}
  for i = 0, slen - 1 do
    local c = math.floor(reaper.gmem_read(base + i))
    if c > 0 then chars[#chars + 1] = string.char(c) end
  end
  return table.concat(chars)
end

function core.gmem_write_string(str, base, len_addr, max_len)
  local len = math.min(#str, max_len)
  reaper.gmem_write(len_addr, len)
  for i = 0, max_len - 1 do
    reaper.gmem_write(base + i, i < len and string.byte(str, i + 1) or 0)
  end
end

function core.read_pad_name(pad)
  local G = core.GMEM
  local base = G.PADNAME_BASE + pad * G.PADNAME_LEN
  local chars = {}
  for i = 0, G.PADNAME_LEN - 1 do
    local c = math.floor(reaper.gmem_read(base + i))
    if c <= 0 or c > 127 then break end  -- 0 = terminator, >127 = stale/misaligned gmem
    chars[#chars + 1] = string.char(c)
  end
  return table.concat(chars)
end

-- Read the MIDI trigger note for a given pad (0-15) from gmem.
-- The JSFX writes this to META_BASE + pad*META_PP + 10 via sync_note_names().
function core.read_pad_note(pad)
  local G = core.GMEM
  return math.floor(reaper.gmem_read(G.META_BASE + pad * G.META_PP + 10) or 0)
end

local NOTE_NAMES = { "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" }
function core.midi_to_note_name(n)
  if not n or n < 0 or n > 127 then return "—" end
  return NOTE_NAMES[(n % 12) + 1] .. (math.floor(n / 12) - 1)
end

-- Browser → JSFX per-pad action helper. The JSFX reads target/code/value
-- in @block (gated by _is_browser_target) and applies, then writes
-- target=-1 to consume.
function core.send_pad_action(pad, code, value)
  local G = core.GMEM
  reaper.gmem_write(G.GS_PAD_ACTION_CODE,   code or 0)
  reaper.gmem_write(G.GS_PAD_ACTION_VALUE,  value or 0)
  reaper.gmem_write(G.GS_PAD_ACTION_TARGET, pad)  -- write LAST so JSFX sees a complete record
end

function core.write_pad_name(pad, name)
  local G = core.GMEM
  local base = G.PADNAME_BASE + pad * G.PADNAME_LEN
  for i = 0, G.PADNAME_LEN - 1 do
    local c = 0
    if i < #name then c = name:byte(i + 1) end
    reaper.gmem_write(base + i, c)
  end
end

function core.pad_has_audio(pad)
  return reaper.gmem_read(core.GMEM.AUDIOLEN_BASE + pad) > 0
end

function core.get_pad_layer_count(pad)
  -- META offset +32 = p_layer_cnt (0=legacy/single, 1-4=loaded layers)
  return math.floor(reaper.gmem_read(core.GMEM.META_BASE + pad * core.GMEM.META_PP + 32))
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- COLOR UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════════

core.PAD_COLOR_S = 0.75
core.PAD_COLOR_L = 0.55

function core.hsl_to_rgb(h, s, l)
  if s == 0 then return l, l, l end
  local function hue2rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
  end
  local q = l < 0.5 and (l * (1 + s)) or (l + s - l * s)
  local p = 2 * l - q
  return hue2rgb(p, q, h + 1/3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1/3)
end

-- RGB → hue (0..1). Inputs in 0..255. Used by the bridge's reverse-direction
-- sync to convert REAPER track colors (I_CUSTOMCOLOR) back into hue values
-- the JSFX understands. Saturation/lightness are intentionally discarded —
-- Swing's color system separates hue (per-pad) from S/L (theme-derived).
function core.rgb_to_hue(r, g, b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  if mx == mn then return 0 end  -- grayscale → arbitrary hue, use 0
  local d = mx - mn
  local h
  if mx == r then
    h = ((g - b) / d) % 6
  elseif mx == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h / 6
end

function core.hsl_to_rgba(h, s, l, a)
  local r, g, b = core.hsl_to_rgb(h, s, l)
  return math.floor(r * 255 + 0.5) * 0x1000000
       + math.floor(g * 255 + 0.5) * 0x10000
       + math.floor(b * 255 + 0.5) * 0x100
       + (a or 0xFF)
end

function core.get_pad_color(pad)
  local G = core.GMEM
  local hue = reaper.gmem_read(G.META_BASE + pad * G.META_PP + 12)
  -- Read effective S/L from gmem so browser pads match the JSFX face's
  -- theme + intensity dial. JSFX writes these from swing_color_rebuild()
  -- whenever palette/intensity/theme changes.
  --
  -- Initialization probe: use eff_l (theme lightness) as the "JSFX has
  -- written" sentinel because every valid theme has L > 0 (smallest is
  -- 0.35 = Dark). eff_s CAN legitimately be 0 (intensity dial at 0% =
  -- full grayscale), so checking eff_s would clobber that valid case
  -- and snap pads back to default 0.75 saturation.
  local eff_s = reaper.gmem_read(G.GS_COL_EFFECTIVE_S)
  local eff_l = reaper.gmem_read(G.GS_COL_EFFECTIVE_L)
  if eff_l <= 0 or eff_l > 1 then
    eff_s = core.PAD_COLOR_S
    eff_l = core.PAD_COLOR_L
  else
    -- Clamp eff_s to [0,1] but DO honor 0 (grayscale via intensity=0)
    if eff_s < 0 then eff_s = 0 end
    if eff_s > 1 then eff_s = 1 end
  end
  -- B/W sentinel values from overlay color picker: -2 = black, -1 = white
  if hue <= -1.5 then
    return 0x333338FF  -- black (0.20, 0.20, 0.22)
  elseif hue < 0 then
    return 0xD1D1D9FF  -- white (0.82, 0.82, 0.85)
  end
  return core.hsl_to_rgba(hue, eff_s, eff_l)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- DRUM TYPE DETECTION
-- ═══════════════════════════════════════════════════════════════════════════════

core.DRUM_COLORS = {
  kick=0.00, kik=0.00, ["808"]=0.00, sub=0.76,
  snare=0.12, snr=0.12, rim=0.06, clap=0.30, clp=0.30,
  hat=0.49, hh=0.49, oh=0.72, ch=0.52, closed=0.52, hihat=0.49,
  tom=0.03, perc=0.40, shaker=0.35, tamb=0.33,
  cymbal=0.21, ride=0.17, crash=0.19,
  fx=0.82, vox=0.62, stab=0.66, pad=0.58, loop=0.86,
  cowbell=0.25, click=0.27, snap=0.40, stomp=0.03,
  conga=0.95, bongo=0.97, ["909"]=0.00
}

function core.guess_drum_type(filename)
  local name = filename:lower()
  -- Strip common audio extensions
  name = name:gsub("%.wav$",""):gsub("%.aif[f]?$",""):gsub("%.mp3$","")
             :gsub("%.flac$",""):gsub("%.ogg$","")
  -- Clean up for matching
  name = name:gsub("%d+",""):gsub("^%s+",""):gsub("%s+$",""):gsub("[_%-]"," ")
  for keyword, hue in pairs(core.DRUM_COLORS) do
    if name:find(keyword, 1, true) then return keyword, hue end
  end
  return nil, 0.5  -- no match → neutral hue
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- TRACK HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════

-- Iterate every track in the project — master FIRST, then regular tracks.
-- Use this anywhere you'd otherwise write
--     for i = 0, reaper.CountTracks(0) - 1 do
--       local tr = reaper.GetTrack(0, i)
-- because that pattern silently skips the master track. A Swing instance on
-- the master track is valid, and any code that searches for Swing must see
-- it (otherwise actions like multi-out build, kit dispatch, FX picker, and
-- ensure_32ch all fail with a confusing "Could not find Swing" message).
function core.iter_all_tracks()
  local i = -1  -- -1 = haven't yielded master yet; 0..n-1 = regular tracks
  return function()
    if i == -1 then
      i = 0
      return reaper.GetMasterTrack(0)
    end
    if i >= reaper.CountTracks(0) then return nil end
    local tr = reaper.GetTrack(0, i)
    i = i + 1
    return tr
  end
end

return core
