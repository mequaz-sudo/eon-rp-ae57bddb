-- Swing Kit Bridge v4 — Full Companion ReaScript
-- (c) EON Studios — All Rights Reserved
--
-- Bridges Swing JSFX ↔ filesystem + REAPER API via gmem shared memory.
-- Features: Kit save/load (.swing), multi-out track builder, batch import,
--           chop-to-pads, auto-color, media explorer toggle.
-- v4: Instance lock system for multi-instance support.
--
-- INSTALLATION:
--   Actions → Show action list → ReaScript: Load → select this file.
--   Run once — stays in the background until REAPER closes.
--   Add to SWS Startup Actions for auto-start.
--
-- FILE FORMATS:
--   .swing v1 (binary, legacy — kept for read-only backwards compat):
--     Header:   magic(8B) + version(8B) + num_pads(8B)
--               + name_len(8B) + name(32×8B)
--               + author_len(8B) + author(32×8B)
--               + desc_len(8B) + desc(64×8B)
--               + timestamp(8B)
--     Per pad:  80 doubles metadata + 16 doubles pad name
--     Audio:    per-pad: length(8B) + sample_rate(8B) + 16-bit PCM data (2B each)
--
--   .swing v2 (Lua text, legacy — path-only, kept for read-only backwards compat):
--     Plain Lua `return { ... }` table with per-pad `path` referring to external
--     sample files. Not self-contained; breaks if source files move.
--
--   .swing v3 (hybrid, CURRENT — self-contained, written on every new save):
--     Bytes  0..7  : ASCII magic "SWINGv03"
--     Bytes  8..15 : lua_len (double) — byte length of the Lua text section
--     Bytes 16..15+lua_len : Lua table text (same shape as v2 + version = 3)
--     Bytes 16+lua_len..EOF: per-pad audio blobs, for each of 16 pads:
--                            [len:8B double][sr:8B double][int16 PCM × len]
--     The Lua section is still human-readable and extensible; the audio section
--     is baked into the same file so the kit works anywhere with no external
--     dependencies.

local SCRIPT_NAME = "Swing Kit Bridge"
local FORMAT_VER  = 22  -- v22: pad names widened from 16 to 32 chars
local MAGIC       = 0x5357494E  -- "SWIN"

-- ═══════════════════════════════════════════════════════════════════════════════
-- SHARED MODULES (ReaKit Lua library)
-- ═══════════════════════════════════════════════════════════════════════════════
local function _get_script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)")
  return path:match("^(.*)[/\\]") or ""
end
local _SCRIPT_DIR = _get_script_dir()
local _sep = package.config:sub(1,1)

package.path = _SCRIPT_DIR .. _sep .. "?.lua;" .. (package.path or "")
local core = require("rk_lua_core")

-- ═══════════════════════════════════════════════════════════════════════════════
-- v5 KIT BUNDLE FORMAT  (Phase 2 scaffolding)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Self-contained zip-STORE bundle: kit.json manifest + pad_NN.wav files.
-- Loaded but not yet wired into the save path; Phase 1 AUDIOLEN fix unblocks
-- v4 saves meanwhile. Wiring happens next session — see plan:
--   C:\Users\quaz\.claude\plans\sharded-baking-pancake.md
--
-- Inlined here (single-file bridge) rather than a separate module so install
-- stays one file. Self-test via ExtState EON_Swing/v5_selftest = "1".
local swing_kit_v5 = (function()
  local M = {}

  -- ── JSON  (encode + decode, no external dependencies) ────────────────────
  local json = {}

  local function _json_escape_str(s)
    s = s:gsub("\\", "\\\\")
         :gsub('"',  '\\"')
         :gsub("\b", "\\b")
         :gsub("\f", "\\f")
         :gsub("\n", "\\n")
         :gsub("\r", "\\r")
         :gsub("\t", "\\t")
    s = s:gsub("[%z\1-\31]", function(c)
      return string.format("\\u%04x", c:byte())
    end)
    return s
  end

  local function _json_is_array(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for k, _ in pairs(t) do
      n = n + 1
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        return false
      end
    end
    for i = 1, n do
      if t[i] == nil then return false end
    end
    return true, n
  end

  local function _json_encode(v, depth)
    depth = depth or 0
    if depth > 64 then error("json.encode: max depth exceeded") end
    local tv = type(v)
    if v == nil then
      return "null"
    elseif tv == "boolean" then
      return v and "true" or "false"
    elseif tv == "number" then
      if v ~= v then return "null" end
      if v == math.huge or v == -math.huge then return "null" end
      if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%d", v)
      end
      return string.format("%.17g", v)
    elseif tv == "string" then
      return '"' .. _json_escape_str(v) .. '"'
    elseif tv == "table" then
      local is_arr, n = _json_is_array(v)
      if is_arr then
        if n == 0 then return "[]" end
        local parts = {}
        for i = 1, n do
          parts[i] = _json_encode(v[i], depth + 1)
        end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        local keys = {}
        for k, _ in pairs(v) do
          if type(k) == "string" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        if #keys == 0 then return "{}" end
        local parts = {}
        for i, k in ipairs(keys) do
          parts[i] = '"' .. _json_escape_str(k) .. '":' .. _json_encode(v[k], depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    else
      error("json.encode: unsupported type " .. tv)
    end
  end

  function json.encode(v)
    local ok, res = pcall(_json_encode, v, 0)
    if not ok then return nil, res end
    return res
  end

  local _json_decode

  local function _json_skip_ws(s, i)
    while i <= #s do
      local c = s:byte(i)
      if c == 32 or c == 9 or c == 10 or c == 13 then
        i = i + 1
      else
        return i
      end
    end
    return i
  end

  local function _json_parse_string(s, i)
    i = i + 1
    local out = {}
    while i <= #s do
      local c = s:sub(i, i)
      if c == '"' then
        return table.concat(out), i + 1
      elseif c == "\\" then
        local nc = s:sub(i + 1, i + 1)
        if nc == "n" then out[#out+1] = "\n"; i = i + 2
        elseif nc == "t" then out[#out+1] = "\t"; i = i + 2
        elseif nc == "r" then out[#out+1] = "\r"; i = i + 2
        elseif nc == "b" then out[#out+1] = "\b"; i = i + 2
        elseif nc == "f" then out[#out+1] = "\f"; i = i + 2
        elseif nc == '"' then out[#out+1] = '"';  i = i + 2
        elseif nc == "\\" then out[#out+1] = "\\"; i = i + 2
        elseif nc == "/" then out[#out+1] = "/"; i = i + 2
        elseif nc == "u" then
          local hex = s:sub(i + 2, i + 5)
          if not hex:match("^%x%x%x%x$") then
            error("json.decode: bad \\u escape at " .. i)
          end
          local code = tonumber(hex, 16)
          if code < 0x80 then
            out[#out+1] = string.char(code)
          elseif code < 0x800 then
            out[#out+1] = string.char(0xC0 + math.floor(code / 0x40),
                                     0x80 + (code % 0x40))
          else
            out[#out+1] = string.char(0xE0 + math.floor(code / 0x1000),
                                     0x80 + math.floor((code % 0x1000) / 0x40),
                                     0x80 + (code % 0x40))
          end
          i = i + 6
        else
          error("json.decode: bad escape \\" .. nc .. " at " .. i)
        end
      else
        out[#out+1] = c
        i = i + 1
      end
    end
    error("json.decode: unterminated string")
  end

  local function _json_parse_number(s, i)
    local j = i
    if s:sub(j, j) == "-" then j = j + 1 end
    while j <= #s do
      local c = s:byte(j)
      if (c >= 48 and c <= 57) or c == 46 or c == 43 or c == 45 or c == 69 or c == 101 then
        j = j + 1
      else
        break
      end
    end
    local num = tonumber(s:sub(i, j - 1))
    if not num then error("json.decode: bad number at " .. i) end
    return num, j
  end

  local function _json_parse_array(s, i)
    i = _json_skip_ws(s, i + 1)
    local arr = {}
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while i <= #s do
      local v
      v, i = _json_decode(s, i)
      arr[#arr + 1] = v
      i = _json_skip_ws(s, i)
      local c = s:sub(i, i)
      if c == "," then
        i = _json_skip_ws(s, i + 1)
      elseif c == "]" then
        return arr, i + 1
      else
        error("json.decode: expected , or ] at " .. i)
      end
    end
    error("json.decode: unterminated array")
  end

  local function _json_parse_object(s, i)
    i = _json_skip_ws(s, i + 1)
    local obj = {}
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while i <= #s do
      if s:sub(i, i) ~= '"' then
        error("json.decode: expected string key at " .. i)
      end
      local key
      key, i = _json_parse_string(s, i)
      i = _json_skip_ws(s, i)
      if s:sub(i, i) ~= ":" then
        error("json.decode: expected : at " .. i)
      end
      i = _json_skip_ws(s, i + 1)
      local val
      val, i = _json_decode(s, i)
      obj[key] = val
      i = _json_skip_ws(s, i)
      local c = s:sub(i, i)
      if c == "," then
        i = _json_skip_ws(s, i + 1)
      elseif c == "}" then
        return obj, i + 1
      else
        error("json.decode: expected , or } at " .. i)
      end
    end
    error("json.decode: unterminated object")
  end

  _json_decode = function(s, i)
    i = _json_skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "{" then return _json_parse_object(s, i)
    elseif c == "[" then return _json_parse_array(s, i)
    elseif c == '"' then return _json_parse_string(s, i)
    elseif c == "-" or (c >= "0" and c <= "9") then return _json_parse_number(s, i)
    elseif s:sub(i, i + 3) == "true"  then return true,  i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null"  then return nil,   i + 4
    end
    error("json.decode: unexpected char '" .. c .. "' at " .. i)
  end

  function json.decode(text)
    if type(text) ~= "string" then return nil, "expected string" end
    local ok, val_or_err = pcall(function()
      local v, ni = _json_decode(text, 1)
      return v, ni
    end)
    if not ok then return nil, tostring(val_or_err) end
    return val_or_err
  end

  M.json = json

  -- ── WAV  (RIFF 16-bit PCM read/write) ────────────────────────────────────
  local wav = {}

  local function _le16(n)
    n = n & 0xFFFF
    return string.char(n & 0xFF, (n >> 8) & 0xFF)
  end

  local function _le32(n)
    n = n & 0xFFFFFFFF
    return string.char(n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF)
  end

  local function _read_le16(s, i)
    local b1, b2 = s:byte(i, i + 1)
    local v = b1 | (b2 << 8)
    if v >= 0x8000 then v = v - 0x10000 end
    return v
  end

  local function _read_u16(s, i)
    local b1, b2 = s:byte(i, i + 1)
    return b1 | (b2 << 8)
  end

  local function _read_u32(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
  end

  -- samples: array of int16 (-32768..32767), interleaved if stereo
  function wav.write_int16(samples, sample_rate, channels)
    if type(samples) ~= "table" then return nil, "samples must be a table" end
    channels = channels or 2
    sample_rate = math.floor(sample_rate or 44100)
    local n = #samples
    local data_size = n * 2
    local byte_rate = sample_rate * channels * 2
    local block_align = channels * 2

    local parts = {}
    local chunk = {}
    for i = 1, n do
      local s = samples[i]
      if s < -32768 then s = -32768 elseif s > 32767 then s = 32767 end
      if s < 0 then s = s + 0x10000 end
      chunk[#chunk + 1] = string.char(s & 0xFF, (s >> 8) & 0xFF)
      if #chunk >= 8192 then
        parts[#parts + 1] = table.concat(chunk)
        chunk = {}
      end
    end
    if #chunk > 0 then parts[#parts + 1] = table.concat(chunk) end
    local pcm = table.concat(parts)

    local header =
      "RIFF" .. _le32(36 + data_size) .. "WAVE" ..
      "fmt " .. _le32(16) ..
        _le16(1) ..
        _le16(channels) ..
        _le32(sample_rate) ..
        _le32(byte_rate) ..
        _le16(block_align) ..
        _le16(16) ..
      "data" .. _le32(data_size)
    return header .. pcm
  end

  -- Returns: samples, sample_rate, channels, err. PCM 16-bit only.
  function wav.read(bytes)
    if type(bytes) ~= "string" or #bytes < 44 then
      return nil, nil, nil, "wav: too short"
    end
    if bytes:sub(1, 4) ~= "RIFF" or bytes:sub(9, 12) ~= "WAVE" then
      return nil, nil, nil, "wav: not RIFF/WAVE"
    end
    local i = 13
    local fmt_found, data_off, data_len = false, nil, nil
    local channels, sample_rate, bits_per_sample, format_code
    while i + 8 <= #bytes do
      local id = bytes:sub(i, i + 3)
      local sz = _read_u32(bytes, i + 4)
      local body = i + 8
      if id == "fmt " then
        format_code     = _read_u16(bytes, body)
        channels        = _read_u16(bytes, body + 2)
        sample_rate     = _read_u32(bytes, body + 4)
        bits_per_sample = _read_u16(bytes, body + 14)
        fmt_found = true
      elseif id == "data" then
        data_off, data_len = body, sz
        break
      end
      i = body + sz
      if sz % 2 == 1 then i = i + 1 end
    end
    if not fmt_found then return nil, nil, nil, "wav: no fmt chunk" end
    if not data_off  then return nil, nil, nil, "wav: no data chunk" end
    if format_code ~= 1 then
      return nil, nil, nil, "wav: not PCM (format " .. tostring(format_code) .. ")"
    end
    if bits_per_sample ~= 16 then
      return nil, nil, nil, "wav: only 16-bit supported (got " .. tostring(bits_per_sample) .. ")"
    end
    if channels ~= 1 and channels ~= 2 then return nil, nil, nil, "wav: unsupported channels" end

    local frames = math.floor(data_len / (channels * 2))
    local total  = frames * channels
    local samples = {}
    for k = 0, total - 1 do
      samples[k + 1] = _read_le16(bytes, data_off + k * 2)
    end
    return samples, sample_rate, channels, nil
  end

  M.wav = wav

  -- ── ZIP-STORE  (no compression — STORE method only) ──────────────────────
  -- Format: PKZIP appnote.txt sections 4.3.6–4.4. Little-endian throughout.
  -- Method 0 (STORE). CRC-32 computed over uncompressed data.
  local zip = {}

  local _crc_tbl = {}
  do
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if c & 1 == 1 then
          c = (c >> 1) ~ 0xEDB88320
        else
          c = c >> 1
        end
      end
      _crc_tbl[i] = c
    end
  end

  local function _crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
      c = (c >> 8) ~ _crc_tbl[((c ~ s:byte(i)) & 0xFF)]
    end
    return (c ~ 0xFFFFFFFF) & 0xFFFFFFFF
  end

  zip.crc32 = _crc32

  -- Hard-coded DOS time/date (2026-01-01 00:00) — metadata only.
  local _DOS_TIME = 0
  local _DOS_DATE = ((2026 - 1980) << 9) | (1 << 5) | 1

  -- entries = { {name="kit.json", data="..."}, {name="pad_01.wav", data="..."}, ... }
  function zip.write(entries)
    if type(entries) ~= "table" then return nil, "entries must be a table" end

    local parts = {}
    local cdir  = {}
    local offset = 0

    for _, e in ipairs(entries) do
      local name = e.name
      local data = e.data or ""
      if type(name) ~= "string" or name == "" then
        return nil, "entry missing name"
      end
      local name_bytes = #name
      local size = #data
      local crc = _crc32(data)

      local lfh =
        "\x50\x4B\x03\x04" ..
        _le16(20) .. _le16(0) .. _le16(0) ..
        _le16(_DOS_TIME) .. _le16(_DOS_DATE) ..
        _le32(crc) .. _le32(size) .. _le32(size) ..
        _le16(name_bytes) .. _le16(0) ..
        name

      parts[#parts + 1] = lfh
      parts[#parts + 1] = data

      cdir[#cdir + 1] =
        "\x50\x4B\x01\x02" ..
        _le16(20) .. _le16(20) .. _le16(0) .. _le16(0) ..
        _le16(_DOS_TIME) .. _le16(_DOS_DATE) ..
        _le32(crc) .. _le32(size) .. _le32(size) ..
        _le16(name_bytes) .. _le16(0) .. _le16(0) ..
        _le16(0) .. _le16(0) .. _le32(0) .. _le32(offset) ..
        name

      offset = offset + #lfh + size
    end

    local cdir_offset = offset
    local cdir_concat = table.concat(cdir)
    parts[#parts + 1] = cdir_concat

    local eocd =
      "\x50\x4B\x05\x06" ..
      _le16(0) .. _le16(0) ..
      _le16(#cdir) .. _le16(#cdir) ..
      _le32(#cdir_concat) .. _le32(cdir_offset) ..
      _le16(0)
    parts[#parts + 1] = eocd

    return table.concat(parts)
  end

  -- Returns: { {name=..., data=...}, ... }, err. STORE only.
  function zip.read(bytes)
    if type(bytes) ~= "string" or #bytes < 22 then
      return nil, "zip: too short"
    end

    local eocd_off
    for i = #bytes - 21, math.max(1, #bytes - 65557), -1 do
      if bytes:sub(i, i + 3) == "\x50\x4B\x05\x06" then
        eocd_off = i
        break
      end
    end
    if not eocd_off then return nil, "zip: no EOCD record" end

    local total_entries = _read_u16(bytes, eocd_off + 10)
    local cdir_size     = _read_u32(bytes, eocd_off + 12)
    local cdir_off      = _read_u32(bytes, eocd_off + 16)

    if cdir_off + cdir_size > #bytes then
      return nil, "zip: truncated central directory"
    end

    local entries = {}
    local p = cdir_off + 1

    for _ = 1, total_entries do
      if bytes:sub(p, p + 3) ~= "\x50\x4B\x01\x02" then
        return nil, "zip: bad central directory entry signature"
      end
      local method   = _read_u16(bytes, p + 10)
      local size     = _read_u32(bytes, p + 24)
      local name_len = _read_u16(bytes, p + 28)
      local extra    = _read_u16(bytes, p + 30)
      local comment  = _read_u16(bytes, p + 32)
      local lfh_off  = _read_u32(bytes, p + 42)
      local name     = bytes:sub(p + 46, p + 46 + name_len - 1)

      if method ~= 0 then
        return nil, "zip: entry '" .. name .. "' uses unsupported compression (method " .. method .. "); STORE only"
      end

      local lp = lfh_off + 1
      if bytes:sub(lp, lp + 3) ~= "\x50\x4B\x03\x04" then
        return nil, "zip: bad local file header signature for '" .. name .. "'"
      end
      local lname_len = _read_u16(bytes, lp + 26)
      local lextra    = _read_u16(bytes, lp + 28)
      local data_off  = lp + 30 + lname_len + lextra
      local data = bytes:sub(data_off, data_off + size - 1)

      entries[#entries + 1] = { name = name, data = data }

      p = p + 46 + name_len + extra + comment
    end

    return entries, nil
  end

  M.zip = zip

  -- ── write_kit / load_kit  (STUBS — wired next session) ───────────────────
  -- Interface contract:
  --   manifest = {
  --     version = 5, kit_name = "Chops", author=..., description=...,
  --     timestamp = ..., globals = {...},
  --     pads = {
  --       [1] = { params={...}, audio="pad_01.wav", layers=nil },
  --       [2] = { params={...}, audio=nil, layers={
  --                 [1]={ params={...}, audio="pad_02_layer_01.wav" }, ... } },
  --       ...
  --     },
  --   }
  --   pad_buffers = {
  --     ["pad_01.wav"] = { samples={...}, sample_rate=44100, channels=2 }, ...
  --   }
  -- Choppa pads land in pad_buffers the same way bridge-loaded ones do —
  -- no special case at the file-format layer.

  function M.write_kit(filepath, manifest, pad_buffers)
    if type(filepath) ~= "string" or filepath == "" then
      return false, "write_kit: bad filepath"
    end
    if type(manifest) ~= "table" then
      return false, "write_kit: manifest must be a table"
    end
    if type(pad_buffers) ~= "table" then
      return false, "write_kit: pad_buffers must be a table"
    end

    manifest.version = 5

    local mtext, mjerr = json.encode(manifest)
    if not mtext then return false, "write_kit: json encode failed: " .. tostring(mjerr) end

    local entries = { { name = "kit.json", data = mtext } }
    local buf_names = {}
    for name, _ in pairs(pad_buffers) do
      if type(name) == "string" then buf_names[#buf_names + 1] = name end
    end
    table.sort(buf_names)
    for _, name in ipairs(buf_names) do
      local b = pad_buffers[name]
      if type(b) == "table" and type(b.samples) == "table" then
        local wbytes, werr = wav.write_int16(b.samples, b.sample_rate or 44100, b.channels or 2)
        if not wbytes then return false, "write_kit: wav encode for '" .. name .. "': " .. tostring(werr) end
        entries[#entries + 1] = { name = name, data = wbytes }
      end
    end

    local zbytes, zerr = zip.write(entries)
    if not zbytes then return false, "write_kit: zip write: " .. tostring(zerr) end

    local f, ferr = io.open(filepath, "wb")
    if not f then return false, "write_kit: cannot open '" .. filepath .. "' for write: " .. tostring(ferr) end
    f:write(zbytes)
    f:close()
    return true, nil
  end

  function M.load_kit(filepath)
    if type(filepath) ~= "string" or filepath == "" then
      return nil, nil, "load_kit: bad filepath"
    end
    local f, ferr = io.open(filepath, "rb")
    if not f then return nil, nil, "load_kit: cannot open '" .. filepath .. "': " .. tostring(ferr) end
    local bytes = f:read("*a")
    f:close()
    if not bytes or #bytes == 0 then return nil, nil, "load_kit: empty file" end

    local entries, zerr = zip.read(bytes)
    if not entries then return nil, nil, "load_kit: zip read: " .. tostring(zerr) end

    local manifest, pad_buffers = nil, {}
    for _, e in ipairs(entries) do
      if e.name == "kit.json" then
        local m, jerr = json.decode(e.data)
        if not m then return nil, nil, "load_kit: bad kit.json: " .. tostring(jerr) end
        manifest = m
      elseif e.name:match("%.wav$") then
        local samples, sr, ch, werr = wav.read(e.data)
        if not samples then
          return nil, nil, "load_kit: bad wav '" .. e.name .. "': " .. tostring(werr)
        end
        pad_buffers[e.name] = { samples = samples, sample_rate = sr, channels = ch }
      end
    end

    if not manifest then return nil, nil, "load_kit: no kit.json in archive" end
    return manifest, pad_buffers, nil
  end

  function M._selftest()
    -- JSON round-trip
    local obj = { name = "Chops", bpm = 120.5, tags = { "808", "trap" }, on = true, off = false }
    local txt = assert(json.encode(obj))
    local dec, derr = json.decode(txt)
    assert(dec, derr)
    assert(dec.name == "Chops")
    assert(dec.bpm == 120.5)
    assert(dec.on == true and dec.off == false)
    assert(dec.tags[1] == "808" and dec.tags[2] == "trap")

    -- WAV round-trip
    local samples = { 100, -200, 32767, -32768, 0, 0, 1, -1 }
    local wb = assert(wav.write_int16(samples, 44100, 2))
    local s2, sr2, ch2, werr = wav.read(wb)
    assert(s2, werr)
    assert(sr2 == 44100 and ch2 == 2)
    for i = 1, #samples do assert(s2[i] == samples[i], "wav sample mismatch at " .. i) end

    -- ZIP round-trip
    local entries = {
      { name = "kit.json", data = txt },
      { name = "pad_01.wav", data = wb },
      { name = "pad_02.wav", data = "small data" },
    }
    local zb = assert(zip.write(entries))
    local e2, zerr = zip.read(zb)
    assert(e2, zerr)
    assert(#e2 == 3)
    assert(e2[1].name == "kit.json" and e2[1].data == txt)
    assert(e2[2].name == "pad_01.wav" and e2[2].data == wb)
    assert(e2[3].name == "pad_02.wav" and e2[3].data == "small data")

    return true
  end

  return M
end)()

-- Optional self-test on bridge start. Enable via:
--   reaper.SetExtState("EON_Swing", "v5_selftest", "1", false)
-- Console prints "swing_kit_v5 selftest OK" or the specific failure.
if reaper.GetExtState and reaper.GetExtState("EON_Swing", "v5_selftest") == "1" then
  local ok, err = pcall(swing_kit_v5._selftest)
  reaper.ShowConsoleMsg(
    ok and "swing_kit_v5 selftest OK\n"
        or ("swing_kit_v5 selftest FAILED: " .. tostring(err) .. "\n"))
end

-- ── gmem layout (aliases from core) ──────────────────────────────────────────
local G = core.GMEM
local CMD           = G.CMD
local PARAM1        = G.PARAM1
local PARAM2        = G.PARAM2
local PARAM3        = G.PARAM3
local NAMELEN       = G.NAMELEN
local NAME_BASE     = G.NAME_BASE
local UNDO_ACK      = G.UNDO_ACK
local UNDO_DESC     = G.UNDO_DESC
local LOCK          = G.LOCK
local INSTANCE      = G.INSTANCE
local BRIDGE_ALIVE  = G.BRIDGE_ALIVE
local META_BASE     = G.META_BASE
local META_PP       = G.META_PP
local PADNAME_BASE  = G.PADNAME_BASE
local PADNAME_LEN   = G.PADNAME_LEN
local AUDIOLEN_BASE = G.AUDIOLEN_BASE
local AUDIO_BASE    = G.AUDIO_BASE
local NUM_PADS   = G.NUM_PADS
local MAX_LAYERS = G.MAX_LAYERS
local SLOT_SIZE  = G.SLOT_SIZE
local LAYER_SIZE = G.LAYER_SIZE
local GS_KIT_LOAD_REQ = G.GS_KIT_LOAD_REQ
local GS_PAD_OFFSET_BASE = G.GS_PAD_OFFSET_BASE
local GMEM_NAME  = core.GMEM_NAME
local GMEM_AUDIO_MAX = NUM_PADS * SLOT_SIZE  -- 64M max total audio in gmem

-- AUTO-KIT-SIDECAR — kit_sources tracks which file each instance was loaded
-- from, so on project save we can simply COPY the source file to the
-- project's sidecar location instead of rebuilding the kit from gmem
-- (which is racy across multi-window @gfx mirrors). Hook is in
-- load_swing_dispatch — every kit-load route ends up there. Declared at
-- top of file so the lexical scope sees it before the function definition.
local kit_sources = {}

-- Register a saved kit file as the kit source for the LOCK-holding instance.
-- Called after every successful kit save so that:
--   1. auto_save_all_sidecars() copies the right file on project save
--   2. P_EXT:swing_kit_src survives REAPER restarts for sidecar recovery
-- Without this, Choppa-applied kits and any save-without-prior-load would
-- have no source path → no sidecar → blank pads after chunk truncation.
local function register_kit_source_after_save(filepath)
  if not filepath or filepath == "" then return end
  local lock_id = math.floor(reaper.gmem_read(97) or 0)  -- LOCK slot
  if lock_id <= 0 then return end
  kit_sources[lock_id] = filepath
  -- Persist to track ExtState so it survives bridge restarts
  for tr_idx = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, tr_idx)
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
      if inst_id == lock_id then
        reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:swing_kit_src", filepath, true)
        return
      end
    end
  end
end

-- ── CMD protocol ───────────────────────────────────────────────────────────
-- Kit ops (10-19):
--   10 = JSFX → Lua: export — prompt for name
--   11 = Lua → JSFX: name ready, proceed with data copy
--   1  = JSFX → Lua: data ready, write file
--   2  = JSFX → Lua: import — show browser, load file
--   3  = Lua → JSFX: import data ready in gmem
--   15 = JSFX → Lua: save to custom path (full PC browse)
--   16 = JSFX → Lua: load from custom path (full PC browse)
--   17 = JSFX → Lua: import SFZ kit (file dialog)
--   18 = JSFX → Lua: import SFZ kit from gmem path (drag-drop on pad grid)
--   22 = JSFX → Lua: auto-load default 808 kit (fires once per fresh instance)
-- Sample ops (20-29):
--   20 = JSFX → Lua: batch import folder to pads
--   23 = JSFX → Lua: auto-color pads by drum type
-- Arrangement ops (30-39):
--   30 = JSFX → Lua: chop selected item to pads
-- Routing ops (40-49):
--   40 = JSFX → Lua: build multi-out tracks
--   45 = JSFX → Lua: toggle Media Explorer
--   46 = JSFX → Lua: open undo block (phase 1 — bridge sets ACK=1)
--   48 = JSFX → Lua: close undo block (phase 2 — action complete)
-- Pad naming (50-59):
--   50 = JSFX → Lua: rename pad (PARAM1=pad index, name in PADNAME area)
--   51 = Lua → JSFX: rename done (new name in PADNAME area)
--   52 = JSFX → Lua: sync MIDI note names to REAPER piano roll
-- Browser (60-62):
--   60 = JSFX → Lua: toggle Swing Browser open/close
--   61 = Browser → JSFX: sample assigned (path via ExtState)
--   62 = JSFX → Lua: close browser
-- Status:
--   98 = cancel / error
--   99 = success
-- LOCK: gmem[97] = instance_id of requesting JSFX (0=free)

-- ═════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═════════════════════════════════════════════════════════════════════════════

local GS_BROWSE_PAD    = G.GS_BROWSE_PAD
local GS_BROWSER_OPEN    = G.GS_BROWSER_OPEN
local GS_BROWSER_VISIBLE = G.GS_BROWSER_VISIBLE
local GS_MEDIA_EXPLORER_OPEN = G.GS_MEDIA_EXPLORER_OPEN
local GS_TRACK_NUM     = G.GS_TRACK_NUM
local GS_COL_EFFECTIVE_S = G.GS_COL_EFFECTIVE_S
local GS_COL_EFFECTIVE_L = G.GS_COL_EFFECTIVE_L

-- Function aliases from core
local sep = core.sep
local get_kits_dir     = core.get_kits_dir
local format_size      = core.format_size
local lua_quote        = core.lua_quote
local guess_drum_type  = core.guess_drum_type
local gmem_read_string = core.gmem_read_string
local gmem_write_string = core.gmem_write_string

local pending_export = nil
-- Undo state stack (LIFO). REAPER's Undo_BeginBlock supports nesting,
-- so when two Swing instances issue CMD 46 between bridge polls, both
-- blocks open and the second instance's CMD 48 closes the inner block.
-- Storing descriptions + timestamps as a stack ensures each EndBlock
-- pops the description matching the block being closed (not the most-
-- recently-set description, which would label the wrong block).
local pending_undo_descs  = {}  -- LIFO of descriptions (push on CMD 46, pop on CMD 48)
local undo_block_times    = {}  -- LIFO of os.time() per open block (leak protection)

-- Global parameter keys for v2 kit format (shared between read and write)
local KIT_GLOBAL_KEYS = {
  "repeat_div", "vel_curve", "swing_amt", "hpf_freq", "lpf_freq",
  "sat_drv", "dly_div", "dly_fb", "dly_mix", "dly_hpf_hz",
  "dly_lpf_hz", "dly_ping", "rvb_size", "rvb_damp", "rvb_mix",
  "rvb_width", "eq_lo", "eq_mid", "eq_hi", "lim_on",
  "lim_thr", "lim_rel", "eq_lo_freq", "eq_mid_freq", "eq_hi_freq",
  "meq_lo_bell", "meq_hi_bell", "note_map", "multi_out", "color_palette",
  "meq_bypass", "cmp_thresh", "cmp_ratio", "cmp_attack", "cmp_release",
  "cmp_knee", "cmp_makeup", "cmp_mix", "cmp_bypass", "rvb_predelay",
  "rvb_hpf", "oneshot_global",
}
local KIT_GMEM_GLOBALS = 40  -- gmem base for global settings

local function pack_double(val)
  return string.pack("<d", val)
end

local function unpack_double(bytes, pos)
  if pos + 7 > #bytes then return 0, pos + 8 end
  return string.unpack("<d", bytes, pos)
end

local function pack_s16(val)
  local clamped = math.max(-1.0, math.min(1.0, val))
  local i = math.floor(clamped * 32767 + 0.5)
  return string.pack("<i2", math.max(-32768, math.min(32767, i)))
end

local function unpack_s16(bytes, pos)
  if pos + 1 > #bytes then return 0.0, pos + 2 end
  local i
  i, pos = string.unpack("<i2", bytes, pos)
  return i / 32767.0, pos
end

local function write_string_field(f, str, max_len)
  local len = math.min(#str, max_len)
  f:write(pack_double(len))
  for i = 1, max_len do
    f:write(pack_double(i <= len and string.byte(str, i) or 0))
  end
end

local function read_string_field(content, pos, max_len)
  local slen
  slen, pos = unpack_double(content, pos)
  slen = math.min(math.floor(slen), max_len)
  local chars = {}
  for i = 1, max_len do
    local c
    c, pos = unpack_double(content, pos)
    if i <= slen and c > 0 then
      chars[#chars + 1] = string.char(math.floor(c))
    end
  end
  return table.concat(chars), pos
end

local function write_gmem_string(f, gmem_base, gmem_len_addr, max_len)
  local len = math.min(math.floor(reaper.gmem_read(gmem_len_addr)), max_len)
  f:write(pack_double(len))
  for i = 0, max_len - 1 do
    f:write(pack_double(reaper.gmem_read(gmem_base + i)))
  end
end

local function read_string_to_gmem(content, pos, gmem_base, gmem_len_addr, max_len)
  local slen
  slen, pos = unpack_double(content, pos)
  slen = math.min(math.floor(slen), max_len)
  reaper.gmem_write(gmem_len_addr, slen)
  for i = 0, max_len - 1 do
    local c
    c, pos = unpack_double(content, pos)
    reaper.gmem_write(gmem_base + i, c)
  end
  return pos
end

local function enumerate_kits()
  local kits_dir = get_kits_dir()
  local kits = {}
  local idx = 0
  while true do
    local fname = reaper.EnumerateFiles(kits_dir, idx)
    if not fname then break end
    if fname:match("%.swing$") then
      local fpath = kits_dir .. sep .. fname
      local f = io.open(fpath, "rb")
      local fsize = 0
      if f then fsize = f:seek("end"); f:close() end
      kits[#kits + 1] = {
        name = fname:gsub("%.swing$", ""),
        filename = fname,
        path = fpath,
        size = fsize
      }
    end
    idx = idx + 1
  end
  table.sort(kits, function(a, b) return a.name:lower() < b.name:lower() end)
  return kits, kits_dir
end

local function validate_swing(filepath)
  local f = io.open(filepath, "rb")
  if not f then return nil, "Cannot open file" end
  local header = f:read(32)
  f:close()
  if not header or #header < 8 then return nil, "File too small" end

  -- Check for v5 (zip bundle — kit.json + pad_NN.wav files inside)
  if header:sub(1, 4) == "\x50\x4B\x03\x04" or header:sub(1, 4) == "\x50\x4B\x05\x06" then
    return true, "v5"
  end

  -- Check for v4 (hybrid w/ per-pad multi-layer audio, ASCII magic)
  if header:sub(1, 8) == "SWINGv04" then
    return true, "v4"
  end

  -- Check for v3 (hybrid: ASCII magic + lua_len + lua + binary audio)
  if header:sub(1, 8) == "SWINGv03" then
    return true, "v3"
  end

  -- Check for v2 (Lua table format — path-only, legacy)
  if header:match("^%-%- Swing") or header:match("^return {") or header:match("^return%s*{") then
    return true, "v2"
  end

  -- Check for v1 (binary format — legacy)
  local magic = string.unpack("<d", header, 1)
  if math.floor(magic) ~= MAGIC then return nil, "Not a .swing file" end
  return true, "v1"
end

-- Write default pad metadata + name + audio length to gmem for a single pad
local function write_default_pad_meta(pad_idx, interleaved_len, sr, hue, pad_name)
  local mb = META_BASE + pad_idx * META_PP
  reaper.gmem_write(mb + 0, 0.707)    -- gain (default -3dB)
  reaper.gmem_write(mb + 1, 0.0)      -- pan
  reaper.gmem_write(mb + 2, 0.0)      -- tune
  reaper.gmem_write(mb + 3, 0.001)    -- attack
  reaper.gmem_write(mb + 4, 0.0)      -- decay
  reaper.gmem_write(mb + 5, 1.0)      -- sustain
  reaper.gmem_write(mb + 6, 0.02)     -- release
  reaper.gmem_write(mb + 7, 0)        -- mute
  reaper.gmem_write(mb + 8, 0)        -- solo
  reaper.gmem_write(mb + 9, 0)        -- output
  reaper.gmem_write(mb + 10, 36 + pad_idx) -- note (C2 + pad index)
  reaper.gmem_write(mb + 11, 0)       -- note_lock
  reaper.gmem_write(mb + 12, hue or (pad_idx / 16.0)) -- color
  reaper.gmem_write(mb + 13, 0)       -- choke
  reaper.gmem_write(mb + 14, -1)      -- oneshot (-1 = follow global)
  reaper.gmem_write(mb + 15, 0)       -- reverse
  reaper.gmem_write(mb + 16, 20)      -- hpf (off)
  reaper.gmem_write(mb + 17, 20000)   -- lpf (off)
  reaper.gmem_write(mb + 18, 0)       -- eq_lo
  reaper.gmem_write(mb + 19, 0)       -- eq_mid
  reaper.gmem_write(mb + 20, 0)       -- eq_hi
  reaper.gmem_write(mb + 21, 0)       -- sat_drv
  reaper.gmem_write(mb + 22, 0)       -- drv_mode
  reaper.gmem_write(mb + 23, 0)       -- bc_rate (0 = off)
  reaper.gmem_write(mb + 24, 16)      -- bc_bits
  reaper.gmem_write(mb + 25, 0)       -- snd_dly
  reaper.gmem_write(mb + 26, 0)       -- snd_rvb
  reaper.gmem_write(mb + 27, 200)     -- eq_lo_freq
  reaper.gmem_write(mb + 28, 1000)    -- eq_mid_freq
  reaper.gmem_write(mb + 29, 5000)    -- eq_hi_freq
  reaper.gmem_write(mb + 30, 0)       -- sum_tight
  reaper.gmem_write(mb + 31, 0)       -- rpt_div
  reaper.gmem_write(mb + 32, 0)       -- layer_cnt (non-layered)
  reaper.gmem_write(mb + 33, 0)       -- layer_mode
  reaper.gmem_write(mb + 34, interleaved_len) -- s_len (interleaved)
  reaper.gmem_write(mb + 35, 0.0)     -- s_start
  reaper.gmem_write(mb + 36, 1.0)     -- s_end
  reaper.gmem_write(mb + 37, sr)      -- s_sr
  reaper.gmem_write(mb + 38, 0)       -- s_norm
  reaper.gmem_write(mb + 39, 1.0)     -- s_norm_gain
  reaper.gmem_write(AUDIOLEN_BASE + pad_idx, interleaved_len)
  local pname = pad_name:sub(1, PADNAME_LEN)
  local pbase = PADNAME_BASE + pad_idx * PADNAME_LEN
  for j = 0, PADNAME_LEN - 1 do
    reaper.gmem_write(pbase + j, j < #pname and string.byte(pname, j + 1) or 0)
  end
end

-- ── Scratch-track helpers ───────────────────────────────────────────────────
-- AudioAccessor requires a media item, which requires a track. Earlier
-- versions used reaper.GetTrack(0, 0) — the user's first track — which
-- briefly polluted it with a temp item and produced a stray undo step.
-- Instead, insert a dedicated scratch track at the END of the project,
-- run the work on it, and delete it. Wrapped in PreventUIRefresh so the
-- TCP/arrange doesn't flicker.
--
-- Always pair acquire / release; release is safe to call with nil (no-op
-- on the track but still decrements the PreventUIRefresh counter).
local function acquire_scratch_track()
  reaper.PreventUIRefresh(1)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)  -- false = no auto-envelopes
  return reaper.GetTrack(0, idx)
end

local function release_scratch_track(tr)
  if tr then
    -- DeleteTrack also destroys any items still on the track.
    reaper.DeleteTrack(tr)
  end
  reaper.PreventUIRefresh(-1)
end

-- ── Shared audio loader (AudioAccessor — correct PCM, with bounds check) ────
-- Loads audio from a file path onto a pad in gmem. Returns true on success.
-- Uses CreateTakeAudioAccessor for real sample data (not GetPeaks).
local function load_audio_to_pad(filepath, pad_idx)
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return false end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  if nch < 1 then nch = 1 end
  local total_samples = math.floor(length * sr)

  -- Cap at SLOT_SIZE/2 (each mono frame → 2 interleaved)
  local num_samples = math.min(total_samples, math.floor(SLOT_SIZE / 2))

  -- Calculate gmem audio offset for this pad (sum prior pad lengths)
  local audio_off = 0
  for p = 0, pad_idx - 1 do
    audio_off = audio_off + math.floor(reaper.gmem_read(AUDIOLEN_BASE + p))
  end

  -- Bounds check: ensure we don't exceed GMEM_AUDIO_MAX
  local interleaved_len = num_samples * 2
  if audio_off + interleaved_len > GMEM_AUDIO_MAX then
    num_samples = math.floor((GMEM_AUDIO_MAX - audio_off) / 2)
    interleaved_len = num_samples * 2
    if num_samples <= 0 then
      reaper.PCM_Source_Destroy(src)
      return false
    end
  end

  -- Create a temporary item+take on a dedicated scratch track to get an
  -- AudioAccessor — never touches the user's first track.
  local tr = acquire_scratch_track()
  if not tr then reaper.PCM_Source_Destroy(src); release_scratch_track(nil); return false end

  local temp_item = reaper.AddMediaItemToTrack(tr)
  local temp_take = reaper.AddTakeToMediaItem(temp_item)
  reaper.SetMediaItemTake_Source(temp_take, src)
  reaper.SetMediaItemInfo_Value(temp_item, "D_LENGTH", length)

  local aa = reaper.CreateTakeAudioAccessor(temp_take)
  if not aa then
    -- release_scratch_track tears down the track + item + take + the
    -- take's source reference. The source was attached via
    -- SetMediaItemTake_Source above so the take owns it now —
    -- calling PCM_Source_Destroy(src) afterward would be a use-after-
    -- free. Just release the scratch track and bail.
    release_scratch_track(tr)
    return false
  end

  -- Read samples in chunks and write interleaved stereo to gmem
  local chunk_size = math.min(num_samples, 1000000)
  local sample_buf = reaper.new_array(chunk_size * nch)
  local samples_read = 0

  while samples_read < num_samples do
    local to_read = math.min(chunk_size, num_samples - samples_read)
    sample_buf.clear()
    reaper.GetAudioAccessorSamples(aa, sr, nch, samples_read / sr, to_read, sample_buf)

    -- Write into the JSFX's interleaved L/R audio buffer.
    -- Mono source: duplicate the single channel into both L and R slots so
    --   the JSFX (which always reads buf[i*2] and buf[i*2+1] as L and R)
    --   plays mono samples symmetrically across both outputs.
    -- Stereo source: write channel 0 to L slot, channel 1 to R slot —
    --   preserves the source's L/R separation so the pad waveform display
    --   and any future stereo-aware mixing reads real channel data.
    -- 3+ channels (rare — surround sources): take ch0 → L, ch1 → R and
    --   discard the rest. Approximation, but better than mono-mixing.
    for j = 0, to_read - 1 do
      local valL, valR
      if nch == 1 then
        valL = sample_buf[j + 1]
        valR = valL
      else
        valL = sample_buf[j * nch + 1] or 0
        valR = sample_buf[j * nch + 2] or 0
      end
      local dst = AUDIO_BASE + audio_off + (samples_read + j) * 2
      reaper.gmem_write(dst,     valL)
      reaper.gmem_write(dst + 1, valR)
    end
    samples_read = samples_read + to_read
  end

  reaper.DestroyAudioAccessor(aa)
  release_scratch_track(tr)

  -- Write audio length + basic metadata
  reaper.gmem_write(AUDIOLEN_BASE + pad_idx, interleaved_len)
  local base = META_BASE + pad_idx * META_PP
  reaper.gmem_write(base + 0, 1.0)   -- gain
  reaper.gmem_write(base + 34, interleaved_len) -- s_len
  reaper.gmem_write(base + 37, sr)    -- sample rate

  -- Write pad name from filename
  local fname = filepath:match("[/\\]([^/\\]+)$") or ""
  fname = fname:gsub("%.%w+$", "")
  if #fname > PADNAME_LEN then fname = fname:sub(1, PADNAME_LEN) end
  for ci = 0, PADNAME_LEN - 1 do
    local c = ci < #fname and string.byte(fname, ci + 1) or 0
    reaper.gmem_write(PADNAME_BASE + pad_idx * PADNAME_LEN + ci, c)
  end

  -- Store path in ExtState for kit save
  reaper.SetExtState("Swing", "pad_path_" .. pad_idx, filepath, false)

  return true
end

-- HSL to RGB (returns 0-255 ints for REAPER ColorToNative)
-- Handles B/W sentinel values: -2 = black, -1 = white (from overlay color picker)
local function hsl_to_rgb(h, s, l)
  if h <= -1.5 then return 51, 51, 56 end   -- black  (matches JSFX 0.20, 0.20, 0.22)
  if h < 0     then return 209, 209, 217 end -- white  (matches JSFX 0.82, 0.82, 0.85)
  local r, g, b = core.hsl_to_rgb(h, s, l)
  return math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)
end

-- Check if an FX slot is a Swing instance
local function is_swing_fx(tr, fx)
  local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
  local retval, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if retval and ident:find("DrumKit_ReaKit") then return true end
  if fname:find("DrumKit_ReaKit") then return true end
  if fname:match("^JS: Swing") or fname:match("Swing %— 16%-Pad") then return true end
  return false
end

-- Find the Swing instance that currently holds the gmem lock (slider4 = instance_id)
-- Falls back to first Swing found if no lock or lock doesn't match
local function find_swing_track()
  local lock_id = math.floor(reaper.gmem_read(LOCK))
  local first_tr, first_fx = nil, nil

  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        -- Check if this instance's slider4 matches the lock
        if lock_id > 0 then
          local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
          if inst_id == lock_id then
            if reaper.GetMediaTrackInfo_Value(tr, "I_NCHAN") < 32 then
              reaper.SetMediaTrackInfo_Value(tr, "I_NCHAN", 32)
            end
            return tr, fx
          end
        end
        if not first_tr then first_tr, first_fx = tr, fx end
      end
    end
  end
  -- Ensure 32 channels on the Swing track for multi-out routing
  if first_tr and reaper.GetMediaTrackInfo_Value(first_tr, "I_NCHAN") < 32 then
    reaper.SetMediaTrackInfo_Value(first_tr, "I_NCHAN", 32)
  end
  return first_tr, first_fx
end

-- ═════════════════════════════════════════════════════════════════════════════
-- FOLDER TRACK HELPERS
-- ═════════════════════════════════════════════════════════════════════════════

-- Find the folder track that parents the Swing track (if multi-out was built)
local function find_folder_track(swing_track)
  if not swing_track then return nil end
  local sw_idx = math.floor(reaper.GetMediaTrackInfo_Value(swing_track, "IP_TRACKNUMBER")) - 1
  if sw_idx < 1 then return nil end
  local above = reaper.GetTrack(0, sw_idx - 1)
  if not above then return nil end
  local depth = reaper.GetMediaTrackInfo_Value(above, "I_FOLDERDEPTH")
  if depth == 1 then return above end
  return nil
end

-- Read current kit name from gmem
local function read_kit_name_from_gmem()
  return gmem_read_string(NAME_BASE, NAMELEN, 32)
end

-- Update folder track name to kit name (or "Sampler" if no kit)
local function update_folder_track_name(swing_track)
  local folder = find_folder_track(swing_track)
  if not folder then return end
  local kit_name = read_kit_name_from_gmem()
  local folder_name = (kit_name ~= "" and kit_name) or "Sampler"
  reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", folder_name, true)
end

-- Sync pad names from gmem to MIDI piano roll + multi-out child tracks.
-- Shared by CMD 48 (post-undo) and CMD 52 (explicit sync_note_names).
local function sync_names_and_tracks(swing_track)
  if not swing_track then return end
  local pad_names_l = {}
  local pad_notes_l = {}
  for i = 0, NUM_PADS - 1 do
    local name = ""
    for j = 0, PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(PADNAME_BASE + i * PADNAME_LEN + j))
      if c > 0 then name = name .. string.char(c) end
    end
    pad_names_l[i] = name
    pad_notes_l[i] = math.floor(reaper.gmem_read(META_BASE + i * META_PP + 10))
  end
  for n = 0, 127 do
    reaper.SetTrackMIDINoteNameEx(0, swing_track, n, 0, "")
  end
  for i = 0, NUM_PADS - 1 do
    local note = pad_notes_l[i]
    if note >= 0 and note <= 127 and #pad_names_l[i] > 0 then
      reaper.SetTrackMIDINoteNameEx(0, swing_track, note, 0, pad_names_l[i])
    end
  end
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends >= NUM_PADS then
    reaper.PreventUIRefresh(1)
    for s = 0, sends - 1 do
      local src_chan = math.floor(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
      if src_chan >= 0 and (src_chan % 2) == 0 then
        local pad = src_chan / 2
        if pad >= 0 and pad < NUM_PADS then
          local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
          if dest_tr then
            local pname = pad_names_l[pad]
            if pname == "" or pname == string.format("Pad %d", pad + 1) then
              pname = string.format("%02d", pad + 1)
            end
            reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", pname, true)
          end
        end
      end
    end
    reaper.PreventUIRefresh(-1)
  end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- KIT EXPORT (CMD 10 → 11 → 1)
-- ═════════════════════════════════════════════════════════════════════════════

local function do_export_name_prompt()
  local retval, csv = reaper.GetUserInputs(
    "Save Swing Kit", 3,
    "Kit Name:,Author (optional):,Description (optional):,extrawidth=220",
    "My Kit,,"
  )
  if not retval then
    reaper.gmem_write(CMD, 98)
    return
  end

  local fields = {}
  for field in (csv .. ","):gmatch("(.-),") do
    fields[#fields + 1] = field
  end
  local kit_name = (fields[1] or ""):match("^%s*(.-)%s*$")
  local author   = (fields[2] or ""):match("^%s*(.-)%s*$")
  local desc     = (fields[3] or ""):match("^%s*(.-)%s*$")

  if kit_name == "" then
    reaper.ShowMessageBox("Kit name cannot be empty.", SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local filename = kit_name:gsub('[<>:"/\\|%?%*]', '_')
  local kits_dir = get_kits_dir()
  local filepath = kits_dir .. sep .. filename .. ".swing"

  local f_check = io.open(filepath, "rb")
  if f_check then
    f_check:close()
    if reaper.ShowMessageBox('"' .. filename .. '.swing" exists. Overwrite?', SCRIPT_NAME, 4) ~= 6 then
      reaper.gmem_write(CMD, 98)
      return
    end
  end

  gmem_write_string(kit_name, NAME_BASE, NAMELEN, 32)

  pending_export = {
    filepath = filepath, kit_name = kit_name,
    author = author, desc = desc, filename = filename
  }

  reaper.gmem_write(CMD, 11)
end

-- CMD 15: Save to custom path (full PC browse)
local function do_export_browse()
  local kits_dir = get_kits_dir()
  local retval, filepath = reaper.JS_Dialog_BrowseForSaveFile(
    "Save Swing Kit", kits_dir, "My Kit.swing", "Swing Kit Files (*.swing)\0*.swing\0All Files (*.*)\0*.*\0"
  )
  if not retval or filepath == "" then
    reaper.gmem_write(CMD, 98)
    return
  end
  -- Ensure .swing extension
  if not filepath:match("%.swing$") then filepath = filepath .. ".swing" end

  local kit_name = filepath:match("([^/\\]+)%.swing$") or "Kit"

  -- Check overwrite
  local f_check = io.open(filepath, "rb")
  if f_check then
    f_check:close()
    if reaper.ShowMessageBox('"' .. kit_name .. '.swing" exists. Overwrite?', SCRIPT_NAME, 4) ~= 6 then
      reaper.gmem_write(CMD, 98)
      return
    end
  end

  gmem_write_string(kit_name, NAME_BASE, NAMELEN, 32)

  pending_export = {
    filepath = filepath, kit_name = kit_name,
    author = "", desc = "", filename = kit_name
  }

  reaper.gmem_write(CMD, 11)
end

local function write_kit_v2(filepath, info)
  local f = io.open(filepath, "w")
  if not f then
    reaper.ShowMessageBox("Could not create file:\n" .. filepath, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local write_ok, write_err = pcall(function()
  f:write("-- Swing Kit v2 — EON Studios — proprietary\n")
  f:write("return {\n")
  f:write('  version  = 2,\n')
  f:write('  kit_name = ' .. lua_quote(info.kit_name) .. ',\n')
  f:write('  author   = ' .. lua_quote(info.author or "") .. ',\n')
  f:write('  created  = ' .. lua_quote(os.date("%Y-%m-%d")) .. ',\n')
  f:write('  modified = ' .. lua_quote(os.date("%Y-%m-%d")) .. ',\n')
  f:write('\n')

  -- Global settings
  f:write('  globals = {\n')
  for i, name in ipairs(KIT_GLOBAL_KEYS) do
    f:write('    ' .. name .. ' = ' .. reaper.gmem_read(KIT_GMEM_GLOBALS + i - 1) .. ',\n')
  end
  f:write('  },\n\n')

  -- Per-pad data
  f:write('  pads = {\n')
  for pad = 0, NUM_PADS - 1 do
    local base = META_BASE + pad * META_PP
    -- Read path from ExtState (reliable source — gmem audio area may be overwritten)
    local path = reaper.GetExtState("Swing", "pad_path_" .. pad) or ""

    -- Read pad name
    local name_base = PADNAME_BASE + pad * PADNAME_LEN
    local name_chars = {}
    for i = 0, PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(name_base + i))
      if c > 0 then name_chars[#name_chars + 1] = string.char(c) end
    end
    local name = table.concat(name_chars)

    f:write('    [' .. (pad + 1) .. '] = {\n')
    f:write('      path   = ' .. lua_quote(path) .. ',\n')
    f:write('      name   = ' .. lua_quote(name) .. ',\n')
    f:write('      gain   = ' .. reaper.gmem_read(base + 0) .. ',\n')
    f:write('      pan    = ' .. reaper.gmem_read(base + 1) .. ',\n')
    f:write('      pitch  = ' .. reaper.gmem_read(base + 2) .. ',\n')
    f:write('      attack = ' .. reaper.gmem_read(base + 3) .. ',\n')
    f:write('      decay  = ' .. reaper.gmem_read(base + 4) .. ',\n')
    f:write('      sustain = ' .. reaper.gmem_read(base + 5) .. ',\n')
    f:write('      release = ' .. reaper.gmem_read(base + 6) .. ',\n')
    f:write('      mute   = ' .. reaper.gmem_read(base + 7) .. ',\n')
    f:write('      solo   = ' .. reaper.gmem_read(base + 8) .. ',\n')
    f:write('      output = ' .. reaper.gmem_read(base + 9) .. ',\n')
    f:write('      note   = ' .. reaper.gmem_read(base + 10) .. ',\n')
    f:write('      note_lock = ' .. reaper.gmem_read(base + 11) .. ',\n')
    f:write('      color  = ' .. reaper.gmem_read(base + 12) .. ',\n')
    f:write('      choke  = ' .. reaper.gmem_read(base + 13) .. ',\n')
    f:write('      oneshot = ' .. reaper.gmem_read(base + 14) .. ',\n')
    f:write('      reverse = ' .. reaper.gmem_read(base + 15) .. ',\n')
    f:write('      fx_hpf = ' .. reaper.gmem_read(base + 16) .. ',\n')
    f:write('      fx_lpf = ' .. reaper.gmem_read(base + 17) .. ',\n')
    f:write('      fx_eq_lo = ' .. reaper.gmem_read(base + 18) .. ',\n')
    f:write('      fx_eq_mid = ' .. reaper.gmem_read(base + 19) .. ',\n')
    f:write('      fx_eq_hi = ' .. reaper.gmem_read(base + 20) .. ',\n')
    f:write('      fx_sat = ' .. reaper.gmem_read(base + 21) .. ',\n')
    f:write('      fx_drv_mode = ' .. reaper.gmem_read(base + 22) .. ',\n')
    f:write('      fx_bc_rate = ' .. reaper.gmem_read(base + 23) .. ',\n')
    f:write('      fx_bc_bits = ' .. reaper.gmem_read(base + 24) .. ',\n')
    f:write('      fx_snd_dly = ' .. reaper.gmem_read(base + 25) .. ',\n')
    f:write('      fx_snd_rvb = ' .. reaper.gmem_read(base + 26) .. ',\n')
    f:write('      fx_eq_lo_freq = ' .. reaper.gmem_read(base + 27) .. ',\n')
    f:write('      fx_eq_mid_freq = ' .. reaper.gmem_read(base + 28) .. ',\n')
    f:write('      fx_eq_hi_freq = ' .. reaper.gmem_read(base + 29) .. ',\n')
    f:write('      sum_tight = ' .. reaper.gmem_read(base + 30) .. ',\n')
    f:write('      rpt_div = ' .. reaper.gmem_read(base + 31) .. ',\n')
    f:write('      layer_cnt = ' .. reaper.gmem_read(base + 32) .. ',\n')
    f:write('      layer_mode = ' .. reaper.gmem_read(base + 33) .. ',\n')
    f:write('      s_len   = ' .. reaper.gmem_read(base + 34) .. ',\n')
    f:write('      s_start = ' .. reaper.gmem_read(base + 35) .. ',\n')
    f:write('      s_end   = ' .. reaper.gmem_read(base + 36) .. ',\n')
    f:write('      s_sr    = ' .. reaper.gmem_read(base + 37) .. ',\n')
    f:write('      s_norm  = ' .. reaper.gmem_read(base + 38) .. ',\n')
    f:write('      s_norm_gain = ' .. reaper.gmem_read(base + 39) .. ',\n')
    f:write('      sample_offset = ' .. reaper.gmem_read(GS_PAD_OFFSET_BASE + pad) .. ',\n')
    f:write('    },\n')
  end
  f:write('  },\n')
  f:write('}\n')
  end) -- pcall write block
  f:close()

  if not write_ok then
    reaper.ShowMessageBox("Error writing kit file (disk full?):\n" .. tostring(write_err), SCRIPT_NAME, 0)
    os.remove(filepath)
    reaper.gmem_write(CMD, 98)
    return
  end

  reaper.gmem_write(CMD, 99)
  -- Signal browser to refresh kit list
  reaper.SetExtState("Swing", "kit_saved", "1", false)
  reaper.ShowMessageBox(
    'Kit saved (v2)!\n\n' ..
    'Name: ' .. info.kit_name .. '\n' ..
    'Location: ' .. filepath,
    SCRIPT_NAME, 0
  )
end

-- ═════════════════════════════════════════════════════════════════════════════
-- v3 HYBRID SAVE — Lua text + baked 16-bit PCM audio per pad (self-contained)
-- ═════════════════════════════════════════════════════════════════════════════

-- Read a NUL-terminated path written by the JSFX into the path area of gmem
-- (AUDIO_BASE + pad * 260 — see Swing_ReaKit.jsfx state 11, line ~219).
-- Falls back to empty string on missing / invalid data.
local function read_pad_path_from_gmem(pad)
  local pbase = AUDIO_BASE + pad * 260
  local plen = math.floor(reaper.gmem_read(pbase))
  if plen <= 0 or plen >= 259 then return "" end
  local chars = {}
  for i = 0, plen - 1 do
    local c = math.floor(reaper.gmem_read(pbase + 1 + i))
    if c > 0 and c < 256 then
      chars[#chars + 1] = string.char(c)
    end
  end
  return table.concat(chars)
end

-- v4: per-layer paths region in gmem starts after the pad-paths block.
--   layout: AUDIO_BASE + NUM_PADS*260 + (pad*MAX_LAYERS + layer)*260
-- The JSFX writes these in state 11 (rk_swing_ui_state.jsfx-inc, after pad paths).
local LAYER_PATH_BASE = AUDIO_BASE + NUM_PADS * 260
local function read_layer_path_from_gmem(pad, layer)
  local lbase = LAYER_PATH_BASE + (pad * MAX_LAYERS + layer) * 260
  local plen = math.floor(reaper.gmem_read(lbase))
  if plen <= 0 or plen >= 259 then return "" end
  local chars = {}
  for i = 0, plen - 1 do
    local c = math.floor(reaper.gmem_read(lbase + 1 + i))
    if c > 0 and c < 256 then
      chars[#chars + 1] = string.char(c)
    end
  end
  return table.concat(chars)
end

-- Stream a sample file to an already-open binary-mode file handle as
-- [interleaved_len:double][sr:double][int16 × interleaved_len] (stereo, L=R for mono).
-- Uses PCM_Source + AudioAccessor (same approach as load_audio_to_pad) but writes
-- directly to disk in chunks so we don't hold the full audio buffer in Lua memory.
--
-- max_frames (optional): cap source samples in *frames* (mono frame count, NOT
-- interleaved samples). Defaults to SLOT_SIZE/2 (matches v3 single-blob-per-pad
-- behaviour). v4 layered save passes LAYER_SIZE/2 so each layer fits in its
-- per-pad slot exactly the way the JSFX expects (see load_layer_from_path).
--
-- Returns (interleaved_len, sr). On failure, writes zero-length placeholder and returns 0, 0.
--
-- Gmem fallback for Choppa-applied slices (no source file on disk):
-- Reads interleaved int16 PCM from the JSFX's gmem audio dump instead of from
-- a file. Called by write_kit_v4 when pad_path is empty but AUDIOLEN > 0.
-- Per-pad audio dump region — JSFX state 11 writes internal s_audio_start[]
-- here so the bridge can reliably read pad audio for kits whose pads have
-- no disk source (Choppa slices, gmem-imported, etc.). Without this region,
-- the bridge was reading from AUDIO_BASE + 0 which state 11 overwrites with
-- path strings — that's the "blank kit" / "wrong pad" bug.
--
-- Layout: AUDIO_BASE + AUDIO_DUMP_OFFSET + cumulative s_len, in pad order.
-- Layered pads dump each layer in sequence.
local AUDIO_DUMP_OFFSET = NUM_PADS * 260 + NUM_PADS * MAX_LAYERS * 260  -- 20800 for 16 pads × 4 layers

local function stream_gmem_pcm_to_file(f, pad)
  local alen = math.floor(reaper.gmem_read(AUDIOLEN_BASE + pad) or 0)
  local pad_sr = reaper.gmem_read(META_BASE + pad * META_PP + 37)  -- s_sr
  if alen <= 0 then
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end
  -- Compute audio offset in gmem dump region (sum of all previous pads' lengths)
  local audio_off = 0
  for p = 0, pad - 1 do
    audio_off = audio_off + math.floor(reaper.gmem_read(AUDIOLEN_BASE + p) or 0)
  end
  if audio_off + alen > GMEM_AUDIO_MAX then
    alen = math.max(0, GMEM_AUDIO_MAX - audio_off)
  end
  -- Header: interleaved length + sample rate
  f:write(pack_double(alen))
  f:write(pack_double(pad_sr))
  -- Write samples as int16 — read from the dump region the JSFX just wrote
  for j = 0, alen - 1 do
    f:write(pack_s16(reaper.gmem_read(AUDIO_BASE + AUDIO_DUMP_OFFSET + audio_off + j)))
  end
  return alen, pad_sr
end

local function stream_pcm_to_file(f, filepath, max_frames)
  max_frames = max_frames or math.floor(SLOT_SIZE / 2)
  if not filepath or filepath == "" then
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  if nch < 1 then nch = 1 end
  local total_samples = math.floor(length * sr)
  local num_samples = math.min(total_samples, max_frames)
  if num_samples <= 0 then
    reaper.PCM_Source_Destroy(src)
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end

  local tr = acquire_scratch_track()
  if not tr then
    release_scratch_track(nil)
    reaper.PCM_Source_Destroy(src)
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end

  local temp_item = reaper.AddMediaItemToTrack(tr)
  local temp_take = reaper.AddTakeToMediaItem(temp_item)
  reaper.SetMediaItemTake_Source(temp_take, src)
  reaper.SetMediaItemInfo_Value(temp_item, "D_LENGTH", length)

  local aa = reaper.CreateTakeAudioAccessor(temp_take)
  if not aa then
    -- Take owns src after SetMediaItemTake_Source above; release_scratch
    -- _track destroys the track which drops the take's source ref.
    -- Calling PCM_Source_Destroy(src) here would be a use-after-free.
    release_scratch_track(tr)
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end

  -- interleaved stereo (mono duplicated L=R) — matches what gmem expects
  local interleaved_len = num_samples * 2

  -- Header for this pad
  f:write(pack_double(interleaved_len))
  f:write(pack_double(sr))

  local chunk_size = math.min(num_samples, 250000)
  local sample_buf = reaper.new_array(chunk_size * nch)
  local samples_read = 0
  local write_buf = {}

  while samples_read < num_samples do
    local to_read = math.min(chunk_size, num_samples - samples_read)
    sample_buf.clear()
    reaper.GetAudioAccessorSamples(aa, sr, nch, samples_read / sr, to_read, sample_buf)

    for j = 0, to_read - 1 do
      local val
      if nch == 1 then
        val = sample_buf[j + 1] or 0
      else
        val = 0
        for ch = 0, nch - 1 do val = val + (sample_buf[j * nch + ch + 1] or 0) end
        val = val / nch
      end
      -- Pack as interleaved stereo int16 (L, R)
      local s = pack_s16(val)
      write_buf[#write_buf + 1] = s
      write_buf[#write_buf + 1] = s
    end

    -- Flush to disk periodically to avoid holding huge Lua tables
    if #write_buf >= 20000 then
      f:write(table.concat(write_buf))
      write_buf = {}
    end

    samples_read = samples_read + to_read
  end

  if #write_buf > 0 then f:write(table.concat(write_buf)) end

  reaper.DestroyAudioAccessor(aa)
  release_scratch_track(tr)

  return interleaved_len, sr
end

local function write_kit_v3(filepath, info)
  -- 1. Collect per-pad paths from gmem (JSFX writes them in state 11) with
  --    ExtState as a fallback. These are used to re-read audio from disk
  --    so it can be baked into the .swing file.
  local pad_paths = {}
  for pad = 0, NUM_PADS - 1 do
    local p = read_pad_path_from_gmem(pad)
    if p == "" then
      p = reaper.GetExtState("Swing", "pad_path_" .. pad) or ""
    end
    pad_paths[pad] = p
  end

  -- 2. Build the Lua text section (same shape as v2, version = 3, path kept
  --    for human-readable reference only — audio itself is appended below).
  local lua_buf = {}
  local function w(s) lua_buf[#lua_buf + 1] = s end

  w("-- Swing Kit v3 — EON Studios — self-contained\n")
  w("return {\n")
  w('  version  = 3,\n')
  w('  kit_name = ' .. lua_quote(info.kit_name) .. ',\n')
  w('  author   = ' .. lua_quote(info.author or "") .. ',\n')
  w('  created  = ' .. lua_quote(os.date("%Y-%m-%d")) .. ',\n')
  w('  modified = ' .. lua_quote(os.date("%Y-%m-%d")) .. ',\n')
  w('\n')

  -- Global settings
  w('  globals = {\n')
  for i, name in ipairs(KIT_GLOBAL_KEYS) do
    w('    ' .. name .. ' = ' .. reaper.gmem_read(KIT_GMEM_GLOBALS + i - 1) .. ',\n')
  end
  w('  },\n\n')

  -- Per-pad data
  w('  pads = {\n')
  for pad = 0, NUM_PADS - 1 do
    local base = META_BASE + pad * META_PP
    -- Pad name
    local name_base = PADNAME_BASE + pad * PADNAME_LEN
    local name_chars = {}
    for i = 0, PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(name_base + i))
      if c > 0 then name_chars[#name_chars + 1] = string.char(c) end
    end
    local name = table.concat(name_chars)

    w('    [' .. (pad + 1) .. '] = {\n')
    w('      path   = ' .. lua_quote(pad_paths[pad] or "") .. ',  -- original source, informational only in v3\n')
    w('      name   = ' .. lua_quote(name) .. ',\n')
    w('      gain   = ' .. reaper.gmem_read(base + 0) .. ',\n')
    w('      pan    = ' .. reaper.gmem_read(base + 1) .. ',\n')
    w('      pitch  = ' .. reaper.gmem_read(base + 2) .. ',\n')
    w('      attack = ' .. reaper.gmem_read(base + 3) .. ',\n')
    w('      decay  = ' .. reaper.gmem_read(base + 4) .. ',\n')
    w('      sustain = ' .. reaper.gmem_read(base + 5) .. ',\n')
    w('      release = ' .. reaper.gmem_read(base + 6) .. ',\n')
    w('      mute   = ' .. reaper.gmem_read(base + 7) .. ',\n')
    w('      solo   = ' .. reaper.gmem_read(base + 8) .. ',\n')
    w('      output = ' .. reaper.gmem_read(base + 9) .. ',\n')
    w('      note   = ' .. reaper.gmem_read(base + 10) .. ',\n')
    w('      note_lock = ' .. reaper.gmem_read(base + 11) .. ',\n')
    w('      color  = ' .. reaper.gmem_read(base + 12) .. ',\n')
    w('      choke  = ' .. reaper.gmem_read(base + 13) .. ',\n')
    w('      oneshot = ' .. reaper.gmem_read(base + 14) .. ',\n')
    w('      reverse = ' .. reaper.gmem_read(base + 15) .. ',\n')
    w('      fx_hpf = ' .. reaper.gmem_read(base + 16) .. ',\n')
    w('      fx_lpf = ' .. reaper.gmem_read(base + 17) .. ',\n')
    w('      fx_eq_lo = ' .. reaper.gmem_read(base + 18) .. ',\n')
    w('      fx_eq_mid = ' .. reaper.gmem_read(base + 19) .. ',\n')
    w('      fx_eq_hi = ' .. reaper.gmem_read(base + 20) .. ',\n')
    w('      fx_sat = ' .. reaper.gmem_read(base + 21) .. ',\n')
    w('      fx_drv_mode = ' .. reaper.gmem_read(base + 22) .. ',\n')
    w('      fx_bc_rate = ' .. reaper.gmem_read(base + 23) .. ',\n')
    w('      fx_bc_bits = ' .. reaper.gmem_read(base + 24) .. ',\n')
    w('      fx_snd_dly = ' .. reaper.gmem_read(base + 25) .. ',\n')
    w('      fx_snd_rvb = ' .. reaper.gmem_read(base + 26) .. ',\n')
    w('      fx_eq_lo_freq = ' .. reaper.gmem_read(base + 27) .. ',\n')
    w('      fx_eq_mid_freq = ' .. reaper.gmem_read(base + 28) .. ',\n')
    w('      fx_eq_hi_freq = ' .. reaper.gmem_read(base + 29) .. ',\n')
    w('      sum_tight = ' .. reaper.gmem_read(base + 30) .. ',\n')
    w('      rpt_div = ' .. reaper.gmem_read(base + 31) .. ',\n')
    w('      layer_cnt = ' .. reaper.gmem_read(base + 32) .. ',\n')
    w('      layer_mode = ' .. reaper.gmem_read(base + 33) .. ',\n')
    w('      s_len   = ' .. reaper.gmem_read(base + 34) .. ',\n')
    w('      s_start = ' .. reaper.gmem_read(base + 35) .. ',\n')
    w('      s_end   = ' .. reaper.gmem_read(base + 36) .. ',\n')
    w('      s_sr    = ' .. reaper.gmem_read(base + 37) .. ',\n')
    w('      s_norm  = ' .. reaper.gmem_read(base + 38) .. ',\n')
    w('      s_norm_gain = ' .. reaper.gmem_read(base + 39) .. ',\n')
    w('      sample_offset = ' .. reaper.gmem_read(GS_PAD_OFFSET_BASE + pad) .. ',\n')
    w('    },\n')
  end
  w('  },\n')
  w('}\n')

  local lua_text = table.concat(lua_buf)
  local lua_len = #lua_text

  -- 3. Open file and write: magic(8B) + lua_len(8B) + lua_text + per-pad audio
  local f = io.open(filepath, "wb")
  if not f then
    reaper.ShowMessageBox("Could not create file:\n" .. filepath, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local write_ok, write_err = pcall(function()
    f:write("SWINGv03")             -- 8 bytes ASCII magic
    f:write(pack_double(lua_len))   -- 8 bytes (double) = byte length of Lua section
    f:write(lua_text)               -- Lua table text

    -- 4. Per-pad audio blobs: [len:double][sr:double][int16 × len]
    --    stream_pcm_to_file writes the header itself and returns the actual
    --    interleaved length + sr written.
    for pad = 0, NUM_PADS - 1 do
      stream_pcm_to_file(f, pad_paths[pad])
    end
  end)
  f:close()

  if not write_ok then
    reaper.ShowMessageBox("Error writing kit file (disk full?):\n" .. tostring(write_err), SCRIPT_NAME, 0)
    os.remove(filepath)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- 5. Report result
  local fcheck = io.open(filepath, "rb")
  local fsize = 0
  if fcheck then fsize = fcheck:seek("end"); fcheck:close() end

  reaper.gmem_write(CMD, 99)
  reaper.SetExtState("Swing", "kit_saved", "1", false)
  reaper.ShowMessageBox(
    'Kit saved (self-contained)!\n\n' ..
    'Name: ' .. info.kit_name .. '\n' ..
    'Size: ' .. format_size(fsize) .. '\n' ..
    'Location: ' .. filepath,
    SCRIPT_NAME, 0
  )
  update_folder_track_name(find_swing_track())
end

-- ═════════════════════════════════════════════════════════════════════════════
-- v4 HYBRID SAVE — same as v3 plus per-pad multi-layer audio (velocity layers,
-- round-robin, vel-split kits all round-trip cleanly).
-- ═════════════════════════════════════════════════════════════════════════════
--
-- File format:
--   Bytes 0..7   : "SWINGv04"
--   Bytes 8..15  : lua_len (double)
--   Bytes 16..   : Lua text (return { version=4, …, pads={[i]={…, layers={[1]={…},…}}} })
--   Then per pad 0..NUM_PADS-1 (TAGGED UNION based on num_layers):
--     [num_layers : 8B double]                         -- 0..MAX_LAYERS
--     If num_layers == 0:  (non-layered pad — drag-drop, single sample)
--       [s_len : 8B][s_sr : 8B][int16 PCM × s_len]
--     If num_layers > 0:   (layered pad — RR, VelSplit, Sum)
--       For each layer 0..num_layers-1:
--         [l_len : 8B][l_sr : 8B][int16 PCM × l_len]
--
-- This tagged layout matches the JSFX's kit_import_state==3 copy loop
-- (rk_swing_ui_state.jsfx-inc lines 515-565) which reads EITHER s_len[pad]
-- bytes OR sum(l_len[pad,layer]) bytes per pad — never both. Writing a
-- pad-main blob ahead of layer blobs would shift the layered audio out of
-- alignment and make the JSFX reproduce noise.
--
-- The JSFX writes per-layer paths to gmem in state 11 (rk_swing_ui_state
-- jsfx-inc, after the pad-paths block) so this writer can re-stream each
-- layer's audio from its source file.
local function write_kit_v4(filepath, info, silent)
  -- Empty-kit refusal. Sum AUDIOLEN_BASE across all pads; if every pad
  -- reports zero audio, the resulting file would be a 27KB metadata-only
  -- shell. That's almost never what the user wants — and destructive
  -- when the destination is an existing real kit (e.g. they typed "808"
  -- into the SAVE name field on a fresh-but-not-yet-loaded instance and
  -- nuke the bundled 808_v2.swing).
  --
  -- Allow it only if the destination doesn't yet exist (legit "save an
  -- empty template" workflow). If overwriting, abort with a dialog so
  -- the user can decide whether to clear pads explicitly.
  do
    local total_audio = 0
    for pad = 0, NUM_PADS - 1 do
      total_audio = total_audio + math.floor(reaper.gmem_read(AUDIOLEN_BASE + pad) or 0)
    end
    if total_audio == 0 then
      local existing = io.open(filepath, "rb")
      if existing then
        existing:close()
        reaper.ShowMessageBox(
          "This kit has no audio loaded — saving would overwrite the existing file " ..
          "with a metadata-only shell.\n\n" ..
          "If you really want to clear this kit, delete the .swing file manually " ..
          "and re-save. Otherwise, load samples or a kit first, then save.",
          SCRIPT_NAME, 0
        )
        reaper.gmem_write(CMD, 98)
        return
      end
    end
  end

  -- Auto-backup before overwrite. If the destination already exists AND
  -- no .bak file exists yet, rename the current file to .bak first. This
  -- protects users from accidentally overwriting a system kit (e.g. saving
  -- a partial-state kit over the bundled "808_v2.swing") with a corrupted
  -- version. The backup is preserved across multiple bad saves: we only
  -- create .bak if it doesn't already exist, so the first known-good
  -- version survives even if subsequent saves are also broken. To recover,
  -- delete the corrupted .swing and rename .bak back to .swing.
  do
    local existing = io.open(filepath, "rb")
    if existing then
      existing:close()
      local bak_path = filepath .. ".bak"
      local bak_check = io.open(bak_path, "rb")
      if bak_check then
        bak_check:close()
        -- .bak already exists — preserve it (don't overwrite the original
        -- known-good version with a potentially-bad recent version).
      else
        os.rename(filepath, bak_path)
      end
    end
  end

  -- 1. Collect paths + per-pad layer counts from gmem
  local pad_paths = {}
  local layer_paths = {}
  local layer_cnts  = {}
  for pad = 0, NUM_PADS - 1 do
    local pp = read_pad_path_from_gmem(pad)
    if pp == "" then
      pp = reaper.GetExtState("Swing", "pad_path_" .. pad) or ""
    end
    pad_paths[pad] = pp

    layer_paths[pad] = {}
    for layer = 0, MAX_LAYERS - 1 do
      layer_paths[pad][layer] = read_layer_path_from_gmem(pad, layer)
    end
    -- Layer 0 fallback: drag-drop sets pad path = layer 0 path; if the JSFX
    -- didn't push a separate layer-0 path, use the pad path.
    if layer_paths[pad][0] == "" then layer_paths[pad][0] = pp end

    local lc = math.floor(reaper.gmem_read(META_BASE + pad * META_PP + 32))
    layer_cnts[pad] = math.max(0, math.min(MAX_LAYERS, lc))
  end

  -- 2. Build Lua text (kit metadata + per-pad layer descriptions)
  local lua_buf = {}
  local function w(s) lua_buf[#lua_buf + 1] = s end

  w("-- Swing Kit v4 — EON Studios — self-contained, multi-layer\n")
  w("return {\n")
  w('  version  = 4,\n')
  w('  kit_name = ' .. lua_quote(info.kit_name) .. ',\n')
  w('  author   = ' .. lua_quote(info.author or "") .. ',\n')
  w('  created  = ' .. lua_quote(os.date("%Y-%m-%d")) .. ',\n')
  w('  modified = ' .. lua_quote(os.date("%Y-%m-%d")) .. ',\n')
  w('\n')

  -- Globals
  w('  globals = {\n')
  for i, name in ipairs(KIT_GLOBAL_KEYS) do
    w('    ' .. name .. ' = ' .. reaper.gmem_read(KIT_GMEM_GLOBALS + i - 1) .. ',\n')
  end
  w('  },\n\n')

  -- Per-pad data
  w('  pads = {\n')
  for pad = 0, NUM_PADS - 1 do
    local base = META_BASE + pad * META_PP

    local name_base = PADNAME_BASE + pad * PADNAME_LEN
    local name_chars = {}
    for i = 0, PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(name_base + i))
      if c > 0 then name_chars[#name_chars + 1] = string.char(c) end
    end
    local name = table.concat(name_chars)

    w('    [' .. (pad + 1) .. '] = {\n')
    w('      path   = ' .. lua_quote(pad_paths[pad] or "") .. ',  -- informational; audio is baked\n')
    w('      name   = ' .. lua_quote(name) .. ',\n')
    w('      gain   = ' .. reaper.gmem_read(base + 0) .. ',\n')
    w('      pan    = ' .. reaper.gmem_read(base + 1) .. ',\n')
    w('      pitch  = ' .. reaper.gmem_read(base + 2) .. ',\n')
    w('      attack = ' .. reaper.gmem_read(base + 3) .. ',\n')
    w('      decay  = ' .. reaper.gmem_read(base + 4) .. ',\n')
    w('      sustain = ' .. reaper.gmem_read(base + 5) .. ',\n')
    w('      release = ' .. reaper.gmem_read(base + 6) .. ',\n')
    w('      mute   = ' .. reaper.gmem_read(base + 7) .. ',\n')
    w('      solo   = ' .. reaper.gmem_read(base + 8) .. ',\n')
    w('      output = ' .. reaper.gmem_read(base + 9) .. ',\n')
    w('      note   = ' .. reaper.gmem_read(base + 10) .. ',\n')
    w('      note_lock = ' .. reaper.gmem_read(base + 11) .. ',\n')
    w('      color  = ' .. reaper.gmem_read(base + 12) .. ',\n')
    w('      choke  = ' .. reaper.gmem_read(base + 13) .. ',\n')
    w('      oneshot = ' .. reaper.gmem_read(base + 14) .. ',\n')
    w('      reverse = ' .. reaper.gmem_read(base + 15) .. ',\n')
    w('      fx_hpf = ' .. reaper.gmem_read(base + 16) .. ',\n')
    w('      fx_lpf = ' .. reaper.gmem_read(base + 17) .. ',\n')
    w('      fx_eq_lo = ' .. reaper.gmem_read(base + 18) .. ',\n')
    w('      fx_eq_mid = ' .. reaper.gmem_read(base + 19) .. ',\n')
    w('      fx_eq_hi = ' .. reaper.gmem_read(base + 20) .. ',\n')
    w('      fx_sat = ' .. reaper.gmem_read(base + 21) .. ',\n')
    w('      fx_drv_mode = ' .. reaper.gmem_read(base + 22) .. ',\n')
    w('      fx_bc_rate = ' .. reaper.gmem_read(base + 23) .. ',\n')
    w('      fx_bc_bits = ' .. reaper.gmem_read(base + 24) .. ',\n')
    w('      fx_snd_dly = ' .. reaper.gmem_read(base + 25) .. ',\n')
    w('      fx_snd_rvb = ' .. reaper.gmem_read(base + 26) .. ',\n')
    w('      fx_eq_lo_freq = ' .. reaper.gmem_read(base + 27) .. ',\n')
    w('      fx_eq_mid_freq = ' .. reaper.gmem_read(base + 28) .. ',\n')
    w('      fx_eq_hi_freq = ' .. reaper.gmem_read(base + 29) .. ',\n')
    w('      sum_tight = ' .. reaper.gmem_read(base + 30) .. ',\n')
    w('      rpt_div = ' .. reaper.gmem_read(base + 31) .. ',\n')
    w('      layer_cnt = ' .. layer_cnts[pad] .. ',\n')
    w('      layer_mode = ' .. reaper.gmem_read(base + 33) .. ',\n')
    w('      s_len   = ' .. reaper.gmem_read(base + 34) .. ',\n')
    w('      s_start = ' .. reaper.gmem_read(base + 35) .. ',\n')
    w('      s_end   = ' .. reaper.gmem_read(base + 36) .. ',\n')
    w('      s_sr    = ' .. reaper.gmem_read(base + 37) .. ',\n')
    w('      s_norm  = ' .. reaper.gmem_read(base + 38) .. ',\n')
    w('      s_norm_gain = ' .. reaper.gmem_read(base + 39) .. ',\n')
    w('      sample_offset = ' .. reaper.gmem_read(GS_PAD_OFFSET_BASE + pad) .. ',\n')

    -- Per-layer metadata (only if pad has layers)
    if layer_cnts[pad] > 0 then
      w('      layers = {\n')
      for layer = 0, layer_cnts[pad] - 1 do
        local lo = base + 40 + layer * 10  -- 10 doubles per layer in meta region
        w('        [' .. (layer + 1) .. '] = {\n')
        w('          path = ' .. lua_quote(layer_paths[pad][layer] or "") .. ',\n')
        w('          len = ' .. reaper.gmem_read(lo + 0) .. ',\n')
        w('          start = ' .. reaper.gmem_read(lo + 1) .. ',\n')
        w('          ["end"] = ' .. reaper.gmem_read(lo + 2) .. ',\n')
        w('          sr = ' .. reaper.gmem_read(lo + 3) .. ',\n')
        w('          norm = ' .. reaper.gmem_read(lo + 4) .. ',\n')
        w('          norm_gain = ' .. reaper.gmem_read(lo + 5) .. ',\n')
        w('          vel_lo = ' .. reaper.gmem_read(lo + 6) .. ',\n')
        w('          vel_hi = ' .. reaper.gmem_read(lo + 7) .. ',\n')
        w('          rr_order = ' .. reaper.gmem_read(lo + 8) .. ',\n')
        w('          gain = ' .. reaper.gmem_read(lo + 9) .. ',\n')
        w('        },\n')
      end
      w('      },\n')
    end

    w('    },\n')
  end
  w('  },\n')
  w('}\n')

  local lua_text = table.concat(lua_buf)
  local lua_len = #lua_text

  -- 3. Open file and write: magic + lua_len + lua + per-pad audio
  local f = io.open(filepath, "wb")
  if not f then
    reaper.ShowMessageBox("Could not create file:\n" .. filepath, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local layer_max_frames = math.floor(LAYER_SIZE / 2)
  local pad_max_frames   = math.floor(SLOT_SIZE / 2)
  local write_ok, write_err = pcall(function()
    f:write("SWINGv04")
    f:write(pack_double(lua_len))
    f:write(lua_text)

    for pad = 0, NUM_PADS - 1 do
      local lc = layer_cnts[pad]
      f:write(pack_double(lc))
      if lc > 0 then
        -- Layered pad: write only the layer blobs. The JSFX reads exactly
        -- sum(l_len) bytes for this pad in its layered copy branch.
        for layer = 0, lc - 1 do
          stream_pcm_to_file(f, layer_paths[pad][layer], layer_max_frames)
        end
      else
        -- Non-layered pad: ALWAYS read from the JSFX state-11 gmem dump.
        -- The dump is fresh and authoritative (whatever the JSFX is currently
        -- playing). The old "use disk path if available" fallback was
        -- producing empty saves for Choppa pads because ExtState retained
        -- stale paths from previously-loaded kits (e.g. 808 source files),
        -- which then failed PCM_Source_CreateFromFileEx. Self-contained kits
        -- means: trust the JSFX dump, never trust external disk paths.
        local alen = math.floor(reaper.gmem_read(AUDIOLEN_BASE + pad) or 0)
        if alen > 0 then
          stream_gmem_pcm_to_file(f, pad)
        else
          -- Pad genuinely empty — write the zero-blob header
          f:write(pack_double(0)); f:write(pack_double(0))
        end
      end
    end
  end)
  f:close()

  if not write_ok then
    reaper.ShowMessageBox("Error writing kit file (disk full?):\n" .. tostring(write_err), SCRIPT_NAME, 0)
    os.remove(filepath)
    reaper.gmem_write(CMD, 98)
    return
  end

  local fcheck = io.open(filepath, "rb")
  local fsize = 0
  if fcheck then fsize = fcheck:seek("end"); fcheck:close() end

  -- Silent mode (auto-sidecar): skip CMD=99 write AND the success dialog.
  -- CMD=99 is the kit-import-completion ACK that triggers a global pad-name
  -- re-read in every Swing's @gfx (rk_swing_ui_state.jsfx-inc:614). Setting
  -- it on a SAVE event causes other instances' pad names to get clobbered
  -- by gmem state. The dialog also creates a yield window where @gfx fires
  -- before our cleanup writes CMD=0. Skipping both keeps auto-save invisible
  -- to the JSFX side and prevents cross-instance state pollution.
  -- Register saved file as kit source for sidecar system
  register_kit_source_after_save(filepath)

  if silent then
    reaper.gmem_write(CMD, 0)
  else
    reaper.gmem_write(CMD, 99)
    reaper.SetExtState("Swing", "kit_saved", "1", false)
    reaper.ShowMessageBox(
      'Kit saved (self-contained, multi-layer)!\n\n' ..
      'Name: ' .. info.kit_name .. '\n' ..
      'Size: ' .. format_size(fsize) .. '\n' ..
      'Location: ' .. filepath,
      SCRIPT_NAME, 0
    )
  end
  update_folder_track_name(find_swing_track())
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- v5 KIT BUNDLE — self-contained zip (kit.json + pad_NN.wav files)
-- ═══════════════════════════════════════════════════════════════════════════════
-- File format: zip-STORE archive containing
--     kit.json                       — manifest (all metadata)
--     pad_NN.wav                     — non-layered pad audio, 16-bit PCM
--     pad_NN_layer_LL.wav            — layered pad audio per layer
-- Audio inside the bundle is OWNED by the kit (copied at save time), so source
-- files can move/be deleted with no effect on the kit. Choppa pads materialize
-- to wav at save just like any other pad — no special case at format level.
--
-- Round-trip uses the swing_kit_v5 IIFE defined at the top of this file
-- (json / wav / zip / write_kit / load_kit helpers).

-- ── Audio capture: PCM source on disk → int16 samples table ──────────────
-- Mirrors stream_pcm_to_file's behavior: averages multi-channel to mono and
-- duplicates as interleaved stereo (L=R). max_frames caps total mono frames.
local function read_pcm_source_to_int16(filepath, max_frames)
  if not filepath or filepath == "" then return nil, 0 end
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return nil, 0 end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  if nch < 1 then nch = 1 end
  local total_samples = math.floor(length * sr)
  local num_samples = math.min(total_samples, max_frames or total_samples)
  if num_samples <= 0 then
    reaper.PCM_Source_Destroy(src)
    return nil, 0
  end

  local tr = acquire_scratch_track()
  if not tr then
    reaper.PCM_Source_Destroy(src)
    return nil, 0
  end

  local temp_item = reaper.AddMediaItemToTrack(tr)
  local temp_take = reaper.AddTakeToMediaItem(temp_item)
  reaper.SetMediaItemTake_Source(temp_take, src)
  reaper.SetMediaItemInfo_Value(temp_item, "D_LENGTH", length)

  local aa = reaper.CreateTakeAudioAccessor(temp_take)
  if not aa then
    release_scratch_track(tr)
    return nil, 0
  end

  local chunk_size = math.min(num_samples, 250000)
  local sample_buf = reaper.new_array(chunk_size * nch)
  local samples = {}            -- int16 stereo interleaved
  local samples_read = 0

  while samples_read < num_samples do
    local to_read = math.min(chunk_size, num_samples - samples_read)
    sample_buf.clear()
    reaper.GetAudioAccessorSamples(aa, sr, nch, samples_read / sr, to_read, sample_buf)
    for j = 0, to_read - 1 do
      local val
      if nch == 1 then
        val = sample_buf[j + 1] or 0
      else
        val = 0
        for ch = 0, nch - 1 do val = val + (sample_buf[j * nch + ch + 1] or 0) end
        val = val / nch
      end
      -- Clamp + convert to int16 (matches pack_s16 semantics)
      if val < -1.0 then val = -1.0 elseif val > 1.0 then val = 1.0 end
      local i16 = math.floor(val * 32767 + 0.5)
      if i16 < -32768 then i16 = -32768 elseif i16 > 32767 then i16 = 32767 end
      samples[#samples + 1] = i16   -- L
      samples[#samples + 1] = i16   -- R
    end
    samples_read = samples_read + to_read
  end

  reaper.DestroyAudioAccessor(aa)
  release_scratch_track(tr)
  return samples, sr
end

-- ── Audio capture: gmem AUDIO_BASE region for a pad → int16 samples table
-- For Choppa-applied pads (no disk source). Reads -1.0..1.0 floats from gmem
-- and converts to int16. Offset is the running sum of prior pads' lengths.
local function read_gmem_to_int16(pad)
  local alen = math.floor(reaper.gmem_read(AUDIOLEN_BASE + pad) or 0)
  local sr = math.floor(reaper.gmem_read(META_BASE + pad * META_PP + 37) or 0)
  if alen <= 0 then return nil, 0 end

  local audio_off = 0
  for p = 0, pad - 1 do
    audio_off = audio_off + math.floor(reaper.gmem_read(AUDIOLEN_BASE + p) or 0)
  end
  if audio_off + alen > GMEM_AUDIO_MAX then
    alen = math.max(0, GMEM_AUDIO_MAX - audio_off)
  end
  if alen <= 0 then return nil, sr end

  local samples = {}
  for j = 0, alen - 1 do
    local v = reaper.gmem_read(AUDIO_BASE + audio_off + j) or 0
    -- gmem stores either -1.0..1.0 floats (v4 load path) OR raw int16 values
    -- (in some legacy paths). Detect: |v| > 1.5 → treat as int16; else float.
    local i16
    if v > 1.5 or v < -1.5 then
      i16 = math.floor(v + 0.5)
    else
      if v < -1.0 then v = -1.0 elseif v > 1.0 then v = 1.0 end
      i16 = math.floor(v * 32767 + 0.5)
    end
    if i16 < -32768 then i16 = -32768 elseif i16 > 32767 then i16 = 32767 end
    samples[#samples + 1] = i16
  end
  return samples, sr
end

-- Helper: read a string of bytes for the first N from a file (magic detect).
local function read_file_magic(filepath, n)
  local f = io.open(filepath, "rb")
  if not f then return nil end
  local head = f:read(n or 8)
  f:close()
  return head
end

-- ── write_kit_v5 — produce a self-contained zip kit ──────────────────────
local function write_kit_v5(filepath, info, silent)
  -- ── Snapshot gmem state ONCE up front ─────────────────────────────────
  -- The JSFX @gfx mirror is writing AUDIOLEN_BASE/META continuously on a
  -- separate thread. If we read those values in different loops during the
  -- save, two reads of the same slot can return DIFFERENT values, and the
  -- manifest ends up describing one snapshot of gmem while the wav files
  -- come from another. Symptom: manifest says "pads 1-4 have audio" but
  -- the captured wavs are pad_01/pad_07/pad_10. Snapshotting everything
  -- now means the rest of the function works off frozen locals.
  local snap_audiolen = {}    -- AUDIOLEN_BASE per pad
  local snap_meta     = {}    -- full META block per pad (40 + MAX_LAYERS*10 doubles)
  local snap_padname  = {}    -- raw pad name characters per pad
  local snap_offset   = {}    -- sample offset per pad
  for pad = 0, NUM_PADS - 1 do
    snap_audiolen[pad] = math.floor(reaper.gmem_read(AUDIOLEN_BASE + pad) or 0)
    local mb = META_BASE + pad * META_PP
    local row = {}
    for j = 0, META_PP - 1 do
      row[j] = reaper.gmem_read(mb + j)
    end
    snap_meta[pad] = row
    snap_padname[pad] = {}
    for i = 0, PADNAME_LEN - 1 do
      snap_padname[pad][i] = math.floor(reaper.gmem_read(PADNAME_BASE + pad * PADNAME_LEN + i))
    end
    snap_offset[pad] = reaper.gmem_read(GS_PAD_OFFSET_BASE + pad)
  end

  -- Optional gmem-state dump at save time. Enable via:
  --   reaper.SetExtState("EON_Swing", "save_debug", "1", false)
  -- Prints AUDIOLEN, s_len from META, and pad name for every populated pad,
  -- so we can see exactly what gmem says at the moment SAVE fires (vs what
  -- the JSFX UI shows the user). Toggles off by setting to "0" or clearing.
  if reaper.GetExtState and reaper.GetExtState("EON_Swing", "save_debug") == "1" then
    reaper.ShowConsoleMsg("\n=== write_kit_v5 SAVE DEBUG @ " .. os.date() .. " ===\n")
    reaper.ShowConsoleMsg("Filepath: " .. tostring(filepath) .. "\n")
    for pad = 0, NUM_PADS - 1 do
      local alen = snap_audiolen[pad]
      local slen = math.floor(snap_meta[pad][34] or 0)
      local lc = math.floor(snap_meta[pad][32] or 0)
      local pp = read_pad_path_from_gmem(pad)
      local name_chars = {}
      for i = 0, PADNAME_LEN - 1 do
        local c = snap_padname[pad][i]
        if c > 0 then name_chars[#name_chars + 1] = string.char(c) end
      end
      local name = table.concat(name_chars)
      if alen > 0 or slen > 0 or lc > 0 or name ~= "" then
        reaper.ShowConsoleMsg(string.format(
          "  pad %2d (UI %2d): AUDIOLEN=%8d  s_len=%8d  layer_cnt=%d  path=%q  name=%q\n",
          pad, pad + 1, alen, slen, lc, pp, name))
      end
    end
    reaper.ShowConsoleMsg("=== end SAVE DEBUG ===\n")
  end

  -- Empty-kit guard. Uses BOTH META s_len (slot 34) AND AUDIOLEN_BASE — if
  -- either source says any pad has audio, allow the save. Single-source is
  -- fragile because META is written only at JSFX state 11 (by the saving
  -- instance) while AUDIOLEN_BASE is written every @gfx frame (by the
  -- browser-target instance). Multi-instance projects or fast SAVE clicks
  -- can leave one source empty even when the other is populated.
  do
    local total_meta = 0
    local total_audiolen = 0
    for pad = 0, NUM_PADS - 1 do
      total_meta = total_meta + math.floor(snap_meta[pad][34] or 0)
      total_audiolen = total_audiolen + snap_audiolen[pad]
      local lc = math.floor(snap_meta[pad][32] or 0)
      if lc > 0 then
        for layer = 0, lc - 1 do
          total_meta = total_meta + math.floor(snap_meta[pad][40 + layer * 10] or 0)
        end
      end
    end
    local total_audio = math.max(total_meta, total_audiolen)
    -- Console warning when the two sources disagree — points at a state
    -- machine bug (kit_import not done, instance race, etc.)
    if total_meta == 0 and total_audiolen > 0 then
      reaper.ShowConsoleMsg(string.format(
        "Swing SAVE: META s_len shows empty (0) but AUDIOLEN_BASE shows %d total — "
        .. "state 11 didn't write META. Falling back to AUDIOLEN_BASE.\n", total_audiolen))
    elseif total_meta > 0 and total_audiolen == 0 then
      reaper.ShowConsoleMsg(string.format(
        "Swing SAVE: META s_len shows %d total but AUDIOLEN_BASE is 0 — @gfx mirror "
        .. "didn't update AUDIOLEN. Using META for capture.\n", total_meta))
    end
    if total_audio == 0 then
      reaper.ShowMessageBox(
        "This kit has no audio loaded in gmem at the moment SAVE fired — the .swing file " ..
        "would only contain pad names and parameters (no wav data).\n\n" ..
        "Common causes:\n" ..
        "  - Chop was applied but the JSFX state machine didn't fully import before SAVE was clicked\n" ..
        "  - Multiple Swing instances racing on gmem (one cleared what the other wrote)\n" ..
        "  - CLEAR/NEW was clicked between chop and SAVE\n\n" ..
        "Try: redo the chop, wait ~1 second for the audio waveforms to appear on the pads, " ..
        "THEN click SAVE.\n\n" ..
        "Aborting save to avoid creating an empty kit file.",
        SCRIPT_NAME, 0
      )
      reaper.gmem_write(CMD, 98)
      return
    end
  end

  -- Auto-backup before overwrite (same as v4)
  do
    local existing = io.open(filepath, "rb")
    if existing then
      existing:close()
      local bak_path = filepath .. ".bak"
      local bak_check = io.open(bak_path, "rb")
      if bak_check then
        bak_check:close()
      else
        os.rename(filepath, bak_path)
      end
    end
  end

  -- 1. Collect paths and layer counts. Paths/layer paths come from a
  -- different gmem region (KIT_GMEM_AUDIO, populated by state 11) which is
  -- stable across the save cycle, so they don't need the snapshot. Layer
  -- count comes from snap_meta to stay consistent with the rest of the
  -- save.
  local pad_paths = {}
  local layer_paths = {}
  local layer_cnts  = {}
  for pad = 0, NUM_PADS - 1 do
    local pp = read_pad_path_from_gmem(pad)
    if pp == "" then
      pp = reaper.GetExtState("Swing", "pad_path_" .. pad) or ""
    end
    pad_paths[pad] = pp
    layer_paths[pad] = {}
    for layer = 0, MAX_LAYERS - 1 do
      layer_paths[pad][layer] = read_layer_path_from_gmem(pad, layer)
    end
    if layer_paths[pad][0] == "" then layer_paths[pad][0] = pp end
    local lc = math.floor(snap_meta[pad][32])
    layer_cnts[pad] = math.max(0, math.min(MAX_LAYERS, lc))
  end

  -- 2. Build the manifest as a Lua table (encoded to JSON inside swing_kit_v5)
  local manifest = {
    version  = 5,
    kit_name = info.kit_name,
    author   = info.author or "",
    created  = os.date("%Y-%m-%d"),
    modified = os.date("%Y-%m-%d"),
    globals  = {},
    pads     = {},
  }
  for i, name in ipairs(KIT_GLOBAL_KEYS) do
    manifest.globals[name] = reaper.gmem_read(KIT_GMEM_GLOBALS + i - 1)
  end

  -- IMPORTANT: this loop now reads exclusively from the snapshot. The
  -- `audio` field is only set for pads that ACTUALLY have audio (snapshot
  -- says alen > 0 or layer_cnts > 0), so we never advertise a wav filename
  -- that won't appear in the bundle. Pads with no audio leave `audio` nil
  -- and the loader correctly treats them as empty.
  for pad = 0, NUM_PADS - 1 do
    local m = snap_meta[pad]
    local name_chars = {}
    for i = 0, PADNAME_LEN - 1 do
      local c = snap_padname[pad][i]
      if c > 0 then name_chars[#name_chars + 1] = string.char(c) end
    end
    local pad_entry = {
      path          = pad_paths[pad] or "",
      name          = table.concat(name_chars),
      gain          = m[0],
      pan           = m[1],
      pitch         = m[2],
      attack        = m[3],
      decay         = m[4],
      sustain       = m[5],
      release       = m[6],
      mute          = m[7],
      solo          = m[8],
      output        = m[9],
      note          = m[10],
      note_lock     = m[11],
      color         = m[12],
      choke         = m[13],
      oneshot       = m[14],
      reverse       = m[15],
      fx_hpf        = m[16],
      fx_lpf        = m[17],
      fx_eq_lo      = m[18],
      fx_eq_mid     = m[19],
      fx_eq_hi      = m[20],
      fx_sat        = m[21],
      fx_drv_mode   = m[22],
      fx_bc_rate    = m[23],
      fx_bc_bits    = m[24],
      fx_snd_dly    = m[25],
      fx_snd_rvb    = m[26],
      fx_eq_lo_freq = m[27],
      fx_eq_mid_freq= m[28],
      fx_eq_hi_freq = m[29],
      sum_tight     = m[30],
      rpt_div       = m[31],
      layer_cnt     = layer_cnts[pad],
      layer_mode    = m[33],
      s_len         = m[34],
      s_start       = m[35],
      s_end         = m[36],
      s_sr          = m[37],
      s_norm        = m[38],
      s_norm_gain   = m[39],
      sample_offset = snap_offset[pad],
      audio         = nil,    -- set below ONLY when the pad has captured audio
      layers        = nil,    -- set below if layered
    }

    if layer_cnts[pad] > 0 then
      pad_entry.layers = {}
      for layer = 0, layer_cnts[pad] - 1 do
        local lo_offset = 40 + layer * 10
        pad_entry.layers[layer + 1] = {
          path      = layer_paths[pad][layer] or "",
          len       = m[lo_offset + 0],
          start     = m[lo_offset + 1],
          ["end"]   = m[lo_offset + 2],
          sr        = m[lo_offset + 3],
          norm      = m[lo_offset + 4],
          norm_gain = m[lo_offset + 5],
          vel_lo    = m[lo_offset + 6],
          vel_hi    = m[lo_offset + 7],
          rr_order  = m[lo_offset + 8],
          gain      = m[lo_offset + 9],
          -- `audio` is set ONLY after the wav is actually captured (loop 3
          -- below), so a layered pad with a missing layer-source disk file
          -- doesn't end up with a stale audio reference.
          audio     = nil,
        }
      end
    end
    -- Non-layered pads: pad_entry.audio gets set in loop 3 if and only if
    -- the audio capture succeeds.

    manifest.pads[pad + 1] = pad_entry
  end

  -- 3. Gather pad audio into pad_buffers keyed by wav filename.
  -- IMPORTANT: AUDIOLEN_BASE is read from the snapshot taken at the top
  -- of this function — NOT live gmem — so the alen the manifest used in
  -- the loop above matches the alen this loop sees. Each successful
  -- capture also stamps the manifest pad_entry.audio field, so manifest
  -- audio references and zip wav contents are 1:1.
  local pad_buffers = {}
  local layer_max_frames = math.floor(LAYER_SIZE / 2)
  local pad_max_frames   = math.floor(SLOT_SIZE / 2)
  for pad = 0, NUM_PADS - 1 do
    local lc = layer_cnts[pad]
    local pad_entry = manifest.pads[pad + 1]
    if lc > 0 then
      for layer = 0, lc - 1 do
        local lp = layer_paths[pad][layer]
        if lp and lp ~= "" then
          local samples, sr = read_pcm_source_to_int16(lp, layer_max_frames)
          if samples and #samples > 0 then
            local wav_name = string.format("pad_%02d_layer_%02d.wav", pad + 1, layer + 1)
            pad_buffers[wav_name] = { samples = samples, sample_rate = sr, channels = 2 }
            pad_entry.layers[layer + 1].audio = wav_name
          end
        end
      end
    else
      local pp = pad_paths[pad]
      -- Pick the audio-length source that has a value for this pad. Prefer
      -- META s_len (slot 34) — written by THIS instance's state-11 export.
      -- Fall back to AUDIOLEN_BASE if META is 0 — happens when state 11 didn't
      -- write META (race, partial state) but the @gfx mirror is up-to-date.
      local meta_len     = math.floor(snap_meta[pad][34] or 0)
      local audiolen_len = snap_audiolen[pad]
      local alen = meta_len > 0 and meta_len or audiolen_len
      local samples, sr
      if (not pp or pp == "") and alen > 0 then
        -- Choppa pad: capture from the JSFX-dumped audio region (NOT the
        -- path-overlaid AUDIO_BASE + 0). JSFX state 11 writes s_audio_start[]
        -- to AUDIO_BASE + AUDIO_DUMP_OFFSET right before signalling CMD=1.
        --
        -- Use the SAME source (meta or audiolen) for the offset that we used
        -- for the length — mixing would misalign the read.
        local use_meta = (meta_len > 0)
        local audio_off = 0
        for p = 0, pad - 1 do
          if use_meta then
            audio_off = audio_off + math.floor(snap_meta[p][34] or 0)
          else
            audio_off = audio_off + snap_audiolen[p]
          end
        end
        local capped = alen
        if audio_off + capped > GMEM_AUDIO_MAX then
          capped = math.max(0, GMEM_AUDIO_MAX - audio_off)
        end
        if capped > 0 then
          samples = {}
          for j = 0, capped - 1 do
            -- Read from the dump region (NOT from path-overlaid offset 0)
            local v = reaper.gmem_read(AUDIO_BASE + AUDIO_DUMP_OFFSET + audio_off + j) or 0
            local i16
            if v > 1.5 or v < -1.5 then
              i16 = math.floor(v + 0.5)
            else
              if v < -1.0 then v = -1.0 elseif v > 1.0 then v = 1.0 end
              i16 = math.floor(v * 32767 + 0.5)
            end
            if i16 < -32768 then i16 = -32768 elseif i16 > 32767 then i16 = 32767 end
            samples[j + 1] = i16
          end
          sr = math.floor(snap_meta[pad][37] or 0)
        end
      elseif pp and pp ~= "" then
        samples, sr = read_pcm_source_to_int16(pp, pad_max_frames)
      end
      if samples and #samples > 0 then
        local wav_name = string.format("pad_%02d.wav", pad + 1)
        pad_buffers[wav_name] = { samples = samples, sample_rate = sr, channels = 2 }
        pad_entry.audio = wav_name
        -- Update the manifest s_len to reflect captured count so loader's
        -- per-pad audio length always matches the wav payload (single
        -- source of truth from this point on).
        pad_entry.s_len = #samples
        if sr and sr > 0 then pad_entry.s_sr = sr end
      else
        -- No audio captured — make sure s_len reflects that, otherwise the
        -- loader may try to consume nonexistent samples.
        pad_entry.s_len = 0
      end
    end
  end

  -- 4. Hand off to the v5 bundle writer
  local ok, err = swing_kit_v5.write_kit(filepath, manifest, pad_buffers)
  if not ok then
    reaper.ShowMessageBox("Error writing v5 kit:\n" .. tostring(err), SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- 5. Trailing: file size, sidecar registration, success dialog/ACK
  local fcheck = io.open(filepath, "rb")
  local fsize = 0
  if fcheck then fsize = fcheck:seek("end"); fcheck:close() end

  register_kit_source_after_save(filepath)

  if silent then
    reaper.gmem_write(CMD, 0)
  else
    reaper.gmem_write(CMD, 99)
    reaper.SetExtState("Swing", "kit_saved", "1", false)
    reaper.ShowMessageBox(
      'Kit saved (v5 bundle — kit owns its audio)!\n\n' ..
      'Name: ' .. info.kit_name .. '\n' ..
      'Size: ' .. format_size(fsize) .. '\n' ..
      'Location: ' .. filepath,
      SCRIPT_NAME, 0
    )
  end
  update_folder_track_name(find_swing_track())
end

local function do_export_write_file()
  local info = pending_export
  if not info then reaper.gmem_write(CMD, 98); return end

  -- JSFX signals "200" from state 11. Default = v4 (legacy hybrid, works
  -- reliably for kits whose pads have disk source files). v5 (self-contained
  -- zip bundle) is opt-in until we land the JSFX-side audio-dump fix that
  -- makes Choppa pads work reliably with v5.
  --
  -- Opt in to v5: reaper.SetExtState("EON_Swing", "save_format", "v5", false)
  local ver = math.floor(reaper.gmem_read(1))  -- KIT_GMEM_VER
  if ver == 200 then
    local fmt = (reaper.GetExtState("EON_Swing", "save_format") or ""):lower()
    if fmt == "v5" then
      write_kit_v5(info.filepath, info)
    else
      write_kit_v4(info.filepath, info)
    end
    pending_export = nil
    return
  end

  local f = io.open(info.filepath, "wb")
  if not f then
    reaper.ShowMessageBox("Could not create file:\n" .. info.filepath, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    pending_export = nil
    return
  end

  -- Wrap the v1 binary write in pcall (matches v3/v4 saves at lines
  -- 988-1000 and 1194-1216). A disk-full / quota-exceeded mid-write
  -- without this guard previously crashed the bridge AND left a
  -- partial file behind.
  local total_saved = 0
  local write_ok, write_err = pcall(function()
    -- Header
    f:write(pack_double(MAGIC))
    f:write(pack_double(FORMAT_VER))
    f:write(pack_double(NUM_PADS))
    write_gmem_string(f, NAME_BASE, NAMELEN, 32)
    write_string_field(f, info.author or "", 32)
    write_string_field(f, info.desc or "", 64)
    f:write(pack_double(os.time()))

    -- Per-pad metadata
    for pad = 0, NUM_PADS - 1 do
      local base = META_BASE + pad * META_PP
      for j = 0, META_PP - 1 do
        f:write(pack_double(reaper.gmem_read(base + j)))
      end
    end

    -- Per-pad names
    for pad = 0, NUM_PADS - 1 do
      local base = PADNAME_BASE + pad * PADNAME_LEN
      for j = 0, PADNAME_LEN - 1 do
        f:write(pack_double(reaper.gmem_read(base + j)))
      end
    end

    -- Audio as 16-bit PCM
    for pad = 0, NUM_PADS - 1 do
      local alen = math.floor(reaper.gmem_read(AUDIOLEN_BASE + pad))
      local pad_sr = reaper.gmem_read(META_BASE + pad * META_PP + 37)
      local audio_off = 0
      for p = 0, pad - 1 do
        audio_off = audio_off + math.floor(reaper.gmem_read(AUDIOLEN_BASE + p))
      end
      if audio_off + alen > GMEM_AUDIO_MAX then
        alen = math.max(0, GMEM_AUDIO_MAX - audio_off)
      end
      f:write(pack_double(alen))
      f:write(pack_double(pad_sr))
      for j = 0, alen - 1 do
        f:write(pack_s16(reaper.gmem_read(AUDIO_BASE + audio_off + j)))
      end
      total_saved = total_saved + alen
    end
  end)

  f:close()

  if not write_ok then
    -- Disk-full / permission-denied / etc. Remove the partial file and
    -- surface the error rather than leaving corrupted output.
    os.remove(info.filepath)
    reaper.ShowMessageBox(
      "Could not write kit (disk full?):\n" .. info.filepath ..
      "\n\nDetails: " .. tostring(write_err),
      SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    pending_export = nil
    return
  end

  local fcheck = io.open(info.filepath, "rb")
  local fsize = 0
  if fcheck then fsize = fcheck:seek("end"); fcheck:close() end

  -- Register saved file as kit source for sidecar system
  register_kit_source_after_save(info.filepath)

  reaper.gmem_write(CMD, 99)
  -- Signal browser to refresh kit list
  reaper.SetExtState("Swing", "kit_saved", "1", false)
  reaper.ShowMessageBox(
    'Kit saved!\n\n' ..
    'Name: ' .. info.kit_name .. '\n' ..
    (info.author ~= "" and ('Author: ' .. info.author .. '\n') or '') ..
    'Samples: ' .. total_saved .. '\n' ..
    'Size: ' .. format_size(fsize) .. '\n' ..
    'Location: ' .. info.filepath,
    SCRIPT_NAME, 0
  )
  update_folder_track_name(find_swing_track())
  pending_export = nil
end

-- ═════════════════════════════════════════════════════════════════════════════
-- KIT IMPORT (CMD 2, 16)
-- ═════════════════════════════════════════════════════════════════════════════

local function load_swing_file(filepath)
  local f = io.open(filepath, "rb")
  if not f then
    reaper.ShowMessageBox("Could not open: " .. filepath, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end
  local content = f:read("*a")
  f:close()

  if #content < 24 then
    reaper.ShowMessageBox("File too small to be a valid .swing kit.", SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local pos = 1
  local magic
  magic, pos = unpack_double(content, pos)
  if math.floor(magic) ~= MAGIC then
    reaper.ShowMessageBox("Invalid .swing file (bad magic).", SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local file_ver
  file_ver, pos = unpack_double(content, pos)
  file_ver = math.floor(file_ver)

  local file_npads
  file_npads, pos = unpack_double(content, pos)
  file_npads = math.min(math.floor(file_npads), NUM_PADS)

  reaper.gmem_write(1, file_ver)   -- VER
  reaper.gmem_write(2, file_npads) -- NPADS

  -- Kit name
  pos = read_string_to_gmem(content, pos, NAME_BASE, NAMELEN, 32)

  -- v21+ fields
  if file_ver >= 21 then
    local _
    _, pos = read_string_field(content, pos, 32)  -- author (file-only)
    _, pos = read_string_field(content, pos, 64)  -- desc (file-only)
    _, pos = unpack_double(content, pos)           -- timestamp
  end

  -- Per-pad metadata
  for pad = 0, file_npads - 1 do
    local base = META_BASE + pad * META_PP
    for j = 0, META_PP - 1 do
      local val
      val, pos = unpack_double(content, pos)
      reaper.gmem_write(base + j, val)
    end
  end

  -- Per-pad names
  -- v21 files stored 16 chars per pad; v22+ stores 32 (PADNAME_LEN).
  -- Read the correct count from the file, zero-fill the rest.
  local file_padname_len = file_ver >= 22 and PADNAME_LEN or 16
  for pad = 0, file_npads - 1 do
    local base = PADNAME_BASE + pad * PADNAME_LEN
    -- Clear the full 32-char slot so old 16-char names don't leave junk
    for j = 0, PADNAME_LEN - 1 do
      reaper.gmem_write(base + j, 0)
    end
    -- Read only what the file actually stored
    for j = 0, file_padname_len - 1 do
      local val
      val, pos = unpack_double(content, pos)
      reaper.gmem_write(base + j, val)
    end
  end

  -- Audio
  local audio_offset = 0
  for pad = 0, file_npads - 1 do
    local alen
    alen, pos = unpack_double(content, pos)
    alen = math.floor(alen)

    if file_ver >= 21 then
      local _sr
      _sr, pos = unpack_double(content, pos)
      reaper.gmem_write(AUDIOLEN_BASE + pad, alen)
      for j = 0, alen - 1 do
        local sample
        sample, pos = unpack_s16(content, pos)
        reaper.gmem_write(AUDIO_BASE + audio_offset + j, sample)
      end
    else
      reaper.gmem_write(AUDIOLEN_BASE + pad, alen)
      for j = 0, alen - 1 do
        local val
        val, pos = unpack_double(content, pos)
        reaper.gmem_write(AUDIO_BASE + audio_offset + j, val)
      end
    end
    audio_offset = audio_offset + alen
  end

  -- Clear remaining pads
  for pad = file_npads, NUM_PADS - 1 do
    local base = META_BASE + pad * META_PP
    for j = 0, META_PP - 1 do reaper.gmem_write(base + j, 0) end
    reaper.gmem_write(AUDIOLEN_BASE + pad, 0)
  end

  reaper.gmem_write(CMD, 3)  -- data ready
  update_folder_track_name(find_swing_track())
end

local function load_kit_v2(filepath)
  -- Load and evaluate the Lua table in a sandboxed environment
  -- (prevents malicious kit files from accessing globals / io / os)
  local chunk, err = loadfile(filepath, "t", {})
  if not chunk then
    reaper.ShowMessageBox("Invalid v2 kit file:\n" .. (err or ""), SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end
  local ok, kit = pcall(chunk)
  if not ok or type(kit) ~= "table" then
    reaper.ShowMessageBox("Invalid v2 kit data:\n" .. tostring(kit), SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Write kit name
  local kit_name = kit.kit_name or "Kit"
  gmem_write_string(kit_name, NAME_BASE, NAMELEN, 32)

  -- Write globals
  if kit.globals then
    for i, key in ipairs(KIT_GLOBAL_KEYS) do
      local default = (key == "oneshot_global") and 1 or 0
      reaper.gmem_write(KIT_GMEM_GLOBALS + i - 1, kit.globals[key] or default)
    end
  end

  -- Write per-pad metadata + paths
  local pads = kit.pads or {}
  for pad = 0, NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local base = META_BASE + pad * META_PP

    reaper.gmem_write(base + 0,  p.gain or 1.0)
    reaper.gmem_write(base + 1,  p.pan or 0)
    reaper.gmem_write(base + 2,  p.pitch or 0)
    reaper.gmem_write(base + 3,  p.attack or 0)
    reaper.gmem_write(base + 4,  p.decay or 0.5)
    reaper.gmem_write(base + 5,  p.sustain or 1.0)
    reaper.gmem_write(base + 6,  p.release or 0.02)
    reaper.gmem_write(base + 7,  p.mute or 0)
    reaper.gmem_write(base + 8,  p.solo or 0)
    reaper.gmem_write(base + 9,  p.output or 0)
    reaper.gmem_write(base + 10, p.note or (36 + pad))
    reaper.gmem_write(base + 11, p.note_lock or 0)
    reaper.gmem_write(base + 12, p.color or 0)
    reaper.gmem_write(base + 13, p.choke or 0)
    reaper.gmem_write(base + 14, p.oneshot or -1)
    reaper.gmem_write(base + 15, p.reverse or 0)
    reaper.gmem_write(base + 16, p.fx_hpf or 20)
    reaper.gmem_write(base + 17, p.fx_lpf or 20000)
    reaper.gmem_write(base + 18, p.fx_eq_lo or 0)
    reaper.gmem_write(base + 19, p.fx_eq_mid or 0)
    reaper.gmem_write(base + 20, p.fx_eq_hi or 0)
    reaper.gmem_write(base + 21, p.fx_sat or 0)
    reaper.gmem_write(base + 22, p.fx_drv_mode or 0)
    reaper.gmem_write(base + 23, p.fx_bc_rate or 0)
    reaper.gmem_write(base + 24, p.fx_bc_bits or 16)
    reaper.gmem_write(base + 25, p.fx_snd_dly or 0)
    reaper.gmem_write(base + 26, p.fx_snd_rvb or 0)
    reaper.gmem_write(base + 27, p.fx_eq_lo_freq or 200)
    reaper.gmem_write(base + 28, p.fx_eq_mid_freq or 1000)
    reaper.gmem_write(base + 29, p.fx_eq_hi_freq or 5000)
    reaper.gmem_write(base + 30, p.sum_tight or 0)
    reaper.gmem_write(base + 31, p.rpt_div or 0)
    reaper.gmem_write(base + 32, p.layer_cnt or 0)
    reaper.gmem_write(base + 33, p.layer_mode or 0)
    reaper.gmem_write(base + 34, p.s_len or 0)
    reaper.gmem_write(base + 35, p.s_start or 0)
    reaper.gmem_write(base + 36, p.s_end or 1.0)
    reaper.gmem_write(base + 37, p.s_sr or 0)
    reaper.gmem_write(base + 38, p.s_norm or 0)
    reaper.gmem_write(base + 39, p.s_norm_gain or 0)

    -- Sample offset (separate gmem region)
    reaper.gmem_write(GS_PAD_OFFSET_BASE + pad, p.sample_offset or 0)

    -- Clear layer data in metadata (layers not supported in v2 yet)
    for lj = 0, 3 do
      for li = 0, 9 do
        reaper.gmem_write(base + 40 + lj * 10 + li, 0)
      end
    end

    -- Write pad name
    local name = p.name or ""
    local name_base = PADNAME_BASE + pad * PADNAME_LEN
    for i = 0, PADNAME_LEN - 1 do
      reaper.gmem_write(name_base + i, i < #name and name:byte(i + 1) or 0)
    end

    -- Write file path to gmem audio area (for JSFX to load)
    local path = p.path or ""
    local pbase = AUDIO_BASE + pad * 260
    reaper.gmem_write(pbase, #path)  -- length prefix
    for i = 0, math.min(#path, 258) - 1 do
      reaper.gmem_write(pbase + 1 + i, path:byte(i + 1))
    end
    reaper.gmem_write(pbase + 1 + math.min(#path, 258), 0)  -- null term

    -- Store path in ExtState for future re-saves
    if path ~= "" then
      reaper.SetExtState("Swing", "pad_path_" .. pad, path, false)
    end
  end

  reaper.gmem_write(2, NUM_PADS)  -- NPADS
  reaper.gmem_write(1, 200)       -- VER = 200 (v2 marker)
  reaper.gmem_write(CMD, 3)       -- data ready
  update_folder_track_name(find_swing_track())
end

-- ─────────────────────────────────────────────────────────────────────────────
-- v3 HYBRID LOAD — Lua text section + baked 16-bit PCM audio (self-contained)
-- ─────────────────────────────────────────────────────────────────────────────
local function load_kit_v3(filepath)
  local f = io.open(filepath, "rb")
  if not f then
    reaper.ShowMessageBox("Could not open: " .. filepath, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end
  local content = f:read("*a")
  f:close()

  if #content < 16 then
    reaper.ShowMessageBox("Kit file too small to be v3.", SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Magic (bytes 1..8) + lua_len (bytes 9..16)
  if content:sub(1, 8) ~= "SWINGv03" then
    reaper.ShowMessageBox("Invalid v3 magic in " .. filepath, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local lua_len = math.floor(string.unpack("<d", content, 9))
  if lua_len <= 0 or 16 + lua_len > #content then
    reaper.ShowMessageBox("Corrupt v3 header (bad lua_len).", SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Extract and evaluate the Lua section in a sandbox (no globals, no io, no os)
  local lua_text = content:sub(17, 16 + lua_len)
  local chunk, err = load(lua_text, "swing_v3_kit", "t", {})
  if not chunk then
    reaper.ShowMessageBox("Invalid v3 Lua section:\n" .. (err or ""), SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end
  local ok, kit = pcall(chunk)
  if not ok or type(kit) ~= "table" then
    reaper.ShowMessageBox("Invalid v3 kit data:\n" .. tostring(kit), SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Kit name
  local kit_name = kit.kit_name or "Kit"
  gmem_write_string(kit_name, NAME_BASE, NAMELEN, 32)

  -- Globals
  if kit.globals then
    for i, key in ipairs(KIT_GLOBAL_KEYS) do
      local default = (key == "oneshot_global") and 1 or 0
      reaper.gmem_write(KIT_GMEM_GLOBALS + i - 1, kit.globals[key] or default)
    end
  end

  -- Per-pad metadata
  local pads = kit.pads or {}
  for pad = 0, NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local base = META_BASE + pad * META_PP

    reaper.gmem_write(base + 0,  p.gain or 1.0)
    reaper.gmem_write(base + 1,  p.pan or 0)
    reaper.gmem_write(base + 2,  p.pitch or 0)
    reaper.gmem_write(base + 3,  p.attack or 0)
    reaper.gmem_write(base + 4,  p.decay or 0.5)
    reaper.gmem_write(base + 5,  p.sustain or 1.0)
    reaper.gmem_write(base + 6,  p.release or 0.02)
    reaper.gmem_write(base + 7,  p.mute or 0)
    reaper.gmem_write(base + 8,  p.solo or 0)
    reaper.gmem_write(base + 9,  p.output or 0)
    reaper.gmem_write(base + 10, p.note or (36 + pad))
    reaper.gmem_write(base + 11, p.note_lock or 0)
    reaper.gmem_write(base + 12, p.color or 0)
    reaper.gmem_write(base + 13, p.choke or 0)
    reaper.gmem_write(base + 14, p.oneshot or -1)
    reaper.gmem_write(base + 15, p.reverse or 0)
    reaper.gmem_write(base + 16, p.fx_hpf or 20)
    reaper.gmem_write(base + 17, p.fx_lpf or 20000)
    reaper.gmem_write(base + 18, p.fx_eq_lo or 0)
    reaper.gmem_write(base + 19, p.fx_eq_mid or 0)
    reaper.gmem_write(base + 20, p.fx_eq_hi or 0)
    reaper.gmem_write(base + 21, p.fx_sat or 0)
    reaper.gmem_write(base + 22, p.fx_drv_mode or 0)
    reaper.gmem_write(base + 23, p.fx_bc_rate or 0)
    reaper.gmem_write(base + 24, p.fx_bc_bits or 16)
    reaper.gmem_write(base + 25, p.fx_snd_dly or 0)
    reaper.gmem_write(base + 26, p.fx_snd_rvb or 0)
    reaper.gmem_write(base + 27, p.fx_eq_lo_freq or 200)
    reaper.gmem_write(base + 28, p.fx_eq_mid_freq or 1000)
    reaper.gmem_write(base + 29, p.fx_eq_hi_freq or 5000)
    reaper.gmem_write(base + 30, p.sum_tight or 0)
    reaper.gmem_write(base + 31, p.rpt_div or 0)
    -- v3 stores a single audio blob per pad. The JSFX's binary-copy path
    -- (rk_swing_ui_state.jsfx-inc:496+) takes the LAYERED branch whenever
    -- p_layer_cnt > 0, and uses l_len[0] (which we zero below) — that copies
    -- 0 samples and leaves every pad blank. Force layer_cnt = 0 here so the
    -- non-layered branch runs and uses s_len[pad] + s_audio_start + pad*SLOT_SIZE
    -- (exactly where this loader writes the audio in the binary section below).
    -- Multi-velocity layered kits aren't fully round-trippable in v3 yet —
    -- that's a future enhancement requiring per-layer audio blobs.
    reaper.gmem_write(base + 32, 0)            -- p_layer_cnt = 0 (was: p.layer_cnt)
    reaper.gmem_write(base + 33, p.layer_mode or 0)
    reaper.gmem_write(base + 34, p.s_len or 0)
    reaper.gmem_write(base + 35, p.s_start or 0)
    reaper.gmem_write(base + 36, p.s_end or 1.0)
    reaper.gmem_write(base + 37, p.s_sr or 0)
    reaper.gmem_write(base + 38, p.s_norm or 0)
    reaper.gmem_write(base + 39, p.s_norm_gain or 0)
    reaper.gmem_write(GS_PAD_OFFSET_BASE + pad, p.sample_offset or 0)

    -- Clear layer metadata (layers carried in meta region but v3 Lua doesn't
    -- serialise them yet — zero out so stale values don't leak through).
    for lj = 0, 3 do
      for li = 0, 9 do
        reaper.gmem_write(base + 40 + lj * 10 + li, 0)
      end
    end

    -- Pad name
    local name = p.name or ""
    local name_base = PADNAME_BASE + pad * PADNAME_LEN
    for i = 0, PADNAME_LEN - 1 do
      reaper.gmem_write(name_base + i, i < #name and name:byte(i + 1) or 0)
    end

    -- Keep the original path in ExtState as a breadcrumb for the user (not
    -- used for loading — audio comes from the file itself below).
    local path = p.path or ""
    if path ~= "" then
      reaper.SetExtState("Swing", "pad_path_" .. pad, path, false)
    end
  end

  -- Binary audio section: starts right after the Lua text at byte (16 + lua_len + 1).
  -- For each pad: [interleaved_len:double 8B][sr:double 8B][int16 PCM × len].
  local pos = 17 + lua_len   -- Lua string:sub() is 1-indexed
  local audio_off = 0
  for pad = 0, NUM_PADS - 1 do
    if pos + 16 > #content then
      -- Audio section truncated — fill remaining pads with empty
      reaper.gmem_write(AUDIOLEN_BASE + pad, 0)
      reaper.gmem_write(META_BASE + pad * META_PP + 34, 0)  -- s_len = 0
    else
      local alen = math.floor(string.unpack("<d", content, pos));  pos = pos + 8
      local sr   = string.unpack("<d", content, pos);               pos = pos + 8
      if alen > 0 and pos + alen * 2 - 1 <= #content then
        -- Bounds guard vs. GMEM_AUDIO_MAX — keep file_alen so we still advance
        -- pos past clipped samples and later pads stay aligned.
        local file_alen = alen
        if audio_off + alen > GMEM_AUDIO_MAX then
          alen = math.max(0, GMEM_AUDIO_MAX - audio_off)
        end
        reaper.gmem_write(AUDIOLEN_BASE + pad, alen)
        for j = 0, alen - 1 do
          local sample
          sample, pos = unpack_s16(content, pos)
          reaper.gmem_write(AUDIO_BASE + audio_off + j, sample)
        end
        -- Skip any clipped-but-still-in-file samples
        if file_alen > alen then
          pos = pos + (file_alen - alen) * 2
        end
        audio_off = audio_off + alen
        -- The binary audio section is the source of truth — override the
        -- Lua-table s_len and s_sr with the values we actually unpacked
        -- so the JSFX's binary-copy path reads the right number of samples.
        reaper.gmem_write(META_BASE + pad * META_PP + 34, alen)  -- s_len
        reaper.gmem_write(META_BASE + pad * META_PP + 37, sr)    -- s_sr
      else
        reaper.gmem_write(AUDIOLEN_BASE + pad, 0)
        reaper.gmem_write(META_BASE + pad * META_PP + 34, 0)  -- s_len = 0
        -- Skip any declared-but-overrun samples
        pos = pos + alen * 2
      end
    end
  end

  -- Tell the JSFX this is binary-audio ready — use v24 meta marker (NOT 200).
  -- The JSFX's kit_import_state == 3 path will take the v1 binary branch
  -- (line ~496 of rk_swing_ui_state.jsfx-inc) and copy the audio we just wrote.
  reaper.gmem_write(2, NUM_PADS)  -- NPADS
  reaper.gmem_write(1, 24)        -- VER = 24 (triggers binary audio load)
  reaper.gmem_write(CMD, 3)       -- data ready
  update_folder_track_name(find_swing_track())
end

-- ─────────────────────────────────────────────────────────────────────────────
-- v4 HYBRID LOAD — Lua text section + per-pad main + per-layer baked PCM.
-- Round-trips velocity-layered, RR, and Sum kits.
-- ─────────────────────────────────────────────────────────────────────────────
local function load_kit_v4(filepath)
  local f = io.open(filepath, "rb")
  if not f then
    reaper.ShowMessageBox("Could not open: " .. filepath, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end
  local content = f:read("*a")
  f:close()

  if #content < 16 then
    reaper.ShowMessageBox("Kit file too small to be v4.", SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  if content:sub(1, 8) ~= "SWINGv04" then
    reaper.ShowMessageBox("Invalid v4 magic in " .. filepath, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local lua_len = math.floor(string.unpack("<d", content, 9))
  if lua_len <= 0 or 16 + lua_len > #content then
    reaper.ShowMessageBox("Corrupt v4 header (bad lua_len).", SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local lua_text = content:sub(17, 16 + lua_len)
  local chunk, err = load(lua_text, "swing_v4_kit", "t", {})
  if not chunk then
    reaper.ShowMessageBox("Invalid v4 Lua section:\n" .. (err or ""), SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end
  local ok, kit = pcall(chunk)
  if not ok or type(kit) ~= "table" then
    reaper.ShowMessageBox("Invalid v4 kit data:\n" .. tostring(kit), SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Kit name
  local kit_name = kit.kit_name or "Kit"
  gmem_write_string(kit_name, NAME_BASE, NAMELEN, 32)

  -- Globals
  if kit.globals then
    for i, key in ipairs(KIT_GLOBAL_KEYS) do
      local default = (key == "oneshot_global") and 1 or 0
      reaper.gmem_write(KIT_GMEM_GLOBALS + i - 1, kit.globals[key] or default)
    end
  end

  -- ── Per-pad metadata + per-layer metadata ──────────────────────────────
  local pads = kit.pads or {}
  local pad_layer_cnts = {}   -- remember lc per pad for the binary read below
  for pad = 0, NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local base = META_BASE + pad * META_PP

    reaper.gmem_write(base + 0,  p.gain or 1.0)
    reaper.gmem_write(base + 1,  p.pan or 0)
    reaper.gmem_write(base + 2,  p.pitch or 0)
    reaper.gmem_write(base + 3,  p.attack or 0)
    reaper.gmem_write(base + 4,  p.decay or 0.5)
    reaper.gmem_write(base + 5,  p.sustain or 1.0)
    reaper.gmem_write(base + 6,  p.release or 0.02)
    reaper.gmem_write(base + 7,  p.mute or 0)
    reaper.gmem_write(base + 8,  p.solo or 0)
    reaper.gmem_write(base + 9,  p.output or 0)
    reaper.gmem_write(base + 10, p.note or (36 + pad))
    reaper.gmem_write(base + 11, p.note_lock or 0)
    reaper.gmem_write(base + 12, p.color or 0)
    reaper.gmem_write(base + 13, p.choke or 0)
    reaper.gmem_write(base + 14, p.oneshot or -1)
    reaper.gmem_write(base + 15, p.reverse or 0)
    reaper.gmem_write(base + 16, p.fx_hpf or 20)
    reaper.gmem_write(base + 17, p.fx_lpf or 20000)
    reaper.gmem_write(base + 18, p.fx_eq_lo or 0)
    reaper.gmem_write(base + 19, p.fx_eq_mid or 0)
    reaper.gmem_write(base + 20, p.fx_eq_hi or 0)
    reaper.gmem_write(base + 21, p.fx_sat or 0)
    reaper.gmem_write(base + 22, p.fx_drv_mode or 0)
    reaper.gmem_write(base + 23, p.fx_bc_rate or 0)
    reaper.gmem_write(base + 24, p.fx_bc_bits or 16)
    reaper.gmem_write(base + 25, p.fx_snd_dly or 0)
    reaper.gmem_write(base + 26, p.fx_snd_rvb or 0)
    reaper.gmem_write(base + 27, p.fx_eq_lo_freq or 200)
    reaper.gmem_write(base + 28, p.fx_eq_mid_freq or 1000)
    reaper.gmem_write(base + 29, p.fx_eq_hi_freq or 5000)
    reaper.gmem_write(base + 30, p.sum_tight or 0)
    reaper.gmem_write(base + 31, p.rpt_div or 0)

    -- v4 honours layer_cnt (unlike v3 which forced it to 0). The binary
    -- audio section below carries per-layer data when layer_cnt > 0.
    local lc = math.floor(p.layer_cnt or 0)
    if lc < 0 then lc = 0 end
    if lc > MAX_LAYERS then lc = MAX_LAYERS end
    pad_layer_cnts[pad] = lc

    reaper.gmem_write(base + 32, lc)
    reaper.gmem_write(base + 33, p.layer_mode or 0)
    reaper.gmem_write(base + 34, p.s_len or 0)
    reaper.gmem_write(base + 35, p.s_start or 0)
    reaper.gmem_write(base + 36, p.s_end or 1.0)
    reaper.gmem_write(base + 37, p.s_sr or 0)
    reaper.gmem_write(base + 38, p.s_norm or 0)
    reaper.gmem_write(base + 39, p.s_norm_gain or 0)
    reaper.gmem_write(GS_PAD_OFFSET_BASE + pad, p.sample_offset or 0)

    -- Per-layer metadata (10 doubles per layer, stride 10 = v24+ layout).
    -- We must zero ALL MAX_LAYERS slots first because the JSFX iterates
    -- every layer slot (line 378 of rk_swing_ui_state.jsfx-inc) regardless
    -- of layer_cnt — stale data from a prior kit would corrupt playback.
    for lj = 0, MAX_LAYERS - 1 do
      local lo = base + 40 + lj * 10
      for li = 0, 9 do
        reaper.gmem_write(lo + li, 0)
      end
    end

    local layers = p.layers or {}
    for layer = 0, lc - 1 do
      local L  = layers[layer + 1] or {}
      local lo = base + 40 + layer * 10
      reaper.gmem_write(lo + 0, L.len or 0)
      reaper.gmem_write(lo + 1, L.start or 0)
      reaper.gmem_write(lo + 2, L["end"] or 1.0)
      reaper.gmem_write(lo + 3, L.sr or 0)
      reaper.gmem_write(lo + 4, L.norm or 0)
      reaper.gmem_write(lo + 5, L.norm_gain or 1.0)
      reaper.gmem_write(lo + 6, L.vel_lo or 0)
      reaper.gmem_write(lo + 7, L.vel_hi or 127)
      reaper.gmem_write(lo + 8, L.rr_order or layer)
      reaper.gmem_write(lo + 9, L.gain or 1.0)
    end

    -- Pad name
    local name = p.name or ""
    local name_base = PADNAME_BASE + pad * PADNAME_LEN
    for i = 0, PADNAME_LEN - 1 do
      reaper.gmem_write(name_base + i, i < #name and name:byte(i + 1) or 0)
    end

    -- Breadcrumb path in ExtState (audio is baked, but useful for the user
    -- to remember where the source came from).
    local path = p.path or ""
    if path ~= "" then
      reaper.SetExtState("Swing", "pad_path_" .. pad, path, false)
    end
  end

  -- ── Binary audio section (TAGGED UNION per pad) ────────────────────────
  -- Per pad:
  --   [num_layers:8B]
  --   If num_layers == 0:  [s_len:8B][s_sr:8B][PCM × s_len]
  --   If num_layers >  0:  per layer: [l_len:8B][l_sr:8B][PCM × l_len]
  --
  -- Audio writes go contiguously to AUDIO_BASE in (pad,blob) order. The
  -- JSFX's kit_import_state==3 copy loop consumes either s_len[pad] or
  -- sum(l_len[pad,*]) per pad — see rk_swing_ui_state.jsfx-inc lines 515-565.
  -- For the layered branch the JSFX iterates ALL MAX_LAYERS slots, but
  -- l_len=0 (zeroed above) means 0 bytes consumed for unused layers, so
  -- audio stays aligned.
  local pos = 17 + lua_len
  local audio_off = 0

  local function read_blob()
    -- Read [len:8B][sr:8B][PCM×len] from content at pos. Writes audio to
    -- gmem at AUDIO_BASE+audio_off, advances pos and audio_off.
    -- Returns (alen, sr).
    if pos + 16 > #content then return 0, 0 end
    local alen = math.floor(string.unpack("<d", content, pos));  pos = pos + 8
    local sr   = string.unpack("<d", content, pos);               pos = pos + 8
    if alen <= 0 then return 0, sr end
    if pos + alen * 2 - 1 > #content then
      pos = pos + alen * 2
      return 0, sr
    end

    local file_alen = alen
    if audio_off + alen > GMEM_AUDIO_MAX then
      alen = math.max(0, GMEM_AUDIO_MAX - audio_off)
    end
    for j = 0, alen - 1 do
      local sample
      sample, pos = unpack_s16(content, pos)
      reaper.gmem_write(AUDIO_BASE + audio_off + j, sample)
    end
    if file_alen > alen then
      pos = pos + (file_alen - alen) * 2
    end
    audio_off = audio_off + alen
    return alen, sr
  end

  for pad = 0, NUM_PADS - 1 do
    -- 1. Layer count (from binary — source of truth)
    local lc_bin = 0
    if pos + 8 <= #content then
      lc_bin = math.floor(string.unpack("<d", content, pos))
      pos = pos + 8
      if lc_bin < 0 then lc_bin = 0 end
      if lc_bin > MAX_LAYERS then lc_bin = MAX_LAYERS end
    end

    -- Reconcile with Lua section if they disagree (binary wins)
    if lc_bin ~= pad_layer_cnts[pad] then
      pad_layer_cnts[pad] = lc_bin
      reaper.gmem_write(META_BASE + pad * META_PP + 32, lc_bin)
    end

    if lc_bin > 0 then
      -- 2a. Layered: read lc_bin layer blobs. Audio length the JSFX will
      -- consume for this pad = sum of l_len values just unpacked.
      local total_alen = 0
      for layer = 0, lc_bin - 1 do
        local l_alen, l_sr = read_blob()
        local lo = META_BASE + pad * META_PP + 40 + layer * 10
        reaper.gmem_write(lo + 0, l_alen)   -- override l_len from binary truth
        reaper.gmem_write(lo + 3, l_sr)     -- override l_sr from binary truth
        total_alen = total_alen + l_alen
      end
      -- AUDIOLEN drives the JSFX progress counter (line 442) — it sums
      -- per-pad totals to compute kit_total_audio. For layered pads we
      -- report the sum of all layer sizes.
      reaper.gmem_write(AUDIOLEN_BASE + pad, total_alen)
      -- s_len has no role in the layered playback path — zero it so UI
      -- doesn't show a stale waveform from before this load.
      reaper.gmem_write(META_BASE + pad * META_PP + 34, 0)
    else
      -- 2b. Non-layered: read single pad-main blob (mirrors v3).
      local s_alen, s_sr = read_blob()
      reaper.gmem_write(AUDIOLEN_BASE + pad, s_alen)
      reaper.gmem_write(META_BASE + pad * META_PP + 34, s_alen)  -- s_len
      reaper.gmem_write(META_BASE + pad * META_PP + 37, s_sr)    -- s_sr
    end
  end

  -- Tell the JSFX this is binary-audio ready. v24 marker triggers the v1
  -- binary copy path which handles BOTH layered (p_layer_cnt > 0) and
  -- non-layered (p_layer_cnt == 0) pads in the same loop.
  reaper.gmem_write(2, NUM_PADS)  -- NPADS
  reaper.gmem_write(1, 24)        -- VER = 24
  reaper.gmem_write(CMD, 3)       -- data ready
  update_folder_track_name(find_swing_track())
end

-- ── load_kit_v5 — read a self-contained zip kit and push to gmem ─────────
-- Symmetric to write_kit_v5: unpack zip → parse kit.json → write meta + per-pad
-- wav samples to gmem at AUDIO_BASE (running offset). Signals JSFX with VER=24
-- (same v1 binary import path that load_kit_v4 uses) so audio gets copied into
-- internal s_audio_start buffers on the next @block.
local function load_kit_v5(filepath)
  local manifest, pad_buffers, err = swing_kit_v5.load_kit(filepath)
  if not manifest then
    reaper.ShowMessageBox("Could not load v5 kit:\n" .. tostring(err), SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Kit name
  gmem_write_string(manifest.kit_name or "Kit", NAME_BASE, NAMELEN, 32)

  -- Globals (object keyed by name, matching write_kit_v5 output)
  if manifest.globals then
    for i, key in ipairs(KIT_GLOBAL_KEYS) do
      local default = (key == "oneshot_global") and 1 or 0
      reaper.gmem_write(KIT_GMEM_GLOBALS + i - 1, manifest.globals[key] or default)
    end
  end

  local pads = manifest.pads or {}
  local pad_layer_cnts = {}

  -- Per-pad metadata (mirrors load_kit_v4 — same param ordering)
  for pad = 0, NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local base = META_BASE + pad * META_PP

    reaper.gmem_write(base + 0,  p.gain or 1.0)
    reaper.gmem_write(base + 1,  p.pan or 0)
    reaper.gmem_write(base + 2,  p.pitch or 0)
    reaper.gmem_write(base + 3,  p.attack or 0)
    reaper.gmem_write(base + 4,  p.decay or 0.5)
    reaper.gmem_write(base + 5,  p.sustain or 1.0)
    reaper.gmem_write(base + 6,  p.release or 0.02)
    reaper.gmem_write(base + 7,  p.mute or 0)
    reaper.gmem_write(base + 8,  p.solo or 0)
    reaper.gmem_write(base + 9,  p.output or 0)
    reaper.gmem_write(base + 10, p.note or (36 + pad))
    reaper.gmem_write(base + 11, p.note_lock or 0)
    reaper.gmem_write(base + 12, p.color or 0)
    reaper.gmem_write(base + 13, p.choke or 0)
    reaper.gmem_write(base + 14, p.oneshot or -1)
    reaper.gmem_write(base + 15, p.reverse or 0)
    reaper.gmem_write(base + 16, p.fx_hpf or 20)
    reaper.gmem_write(base + 17, p.fx_lpf or 20000)
    reaper.gmem_write(base + 18, p.fx_eq_lo or 0)
    reaper.gmem_write(base + 19, p.fx_eq_mid or 0)
    reaper.gmem_write(base + 20, p.fx_eq_hi or 0)
    reaper.gmem_write(base + 21, p.fx_sat or 0)
    reaper.gmem_write(base + 22, p.fx_drv_mode or 0)
    reaper.gmem_write(base + 23, p.fx_bc_rate or 0)
    reaper.gmem_write(base + 24, p.fx_bc_bits or 16)
    reaper.gmem_write(base + 25, p.fx_snd_dly or 0)
    reaper.gmem_write(base + 26, p.fx_snd_rvb or 0)
    reaper.gmem_write(base + 27, p.fx_eq_lo_freq or 200)
    reaper.gmem_write(base + 28, p.fx_eq_mid_freq or 1000)
    reaper.gmem_write(base + 29, p.fx_eq_hi_freq or 5000)
    reaper.gmem_write(base + 30, p.sum_tight or 0)
    reaper.gmem_write(base + 31, p.rpt_div or 0)

    local lc = math.floor(p.layer_cnt or 0)
    if lc < 0 then lc = 0 end
    if lc > MAX_LAYERS then lc = MAX_LAYERS end
    pad_layer_cnts[pad] = lc

    reaper.gmem_write(base + 32, lc)
    reaper.gmem_write(base + 33, p.layer_mode or 0)
    reaper.gmem_write(base + 34, p.s_len or 0)
    reaper.gmem_write(base + 35, p.s_start or 0)
    reaper.gmem_write(base + 36, p.s_end or 1.0)
    reaper.gmem_write(base + 37, p.s_sr or 0)
    reaper.gmem_write(base + 38, p.s_norm or 0)
    reaper.gmem_write(base + 39, p.s_norm_gain or 0)
    reaper.gmem_write(GS_PAD_OFFSET_BASE + pad, p.sample_offset or 0)

    -- Zero ALL MAX_LAYERS metadata slots, then fill the active ones
    for lj = 0, MAX_LAYERS - 1 do
      local lo = base + 40 + lj * 10
      for li = 0, 9 do reaper.gmem_write(lo + li, 0) end
    end
    local layers = p.layers or {}
    for layer = 0, lc - 1 do
      local L  = layers[layer + 1] or {}
      local lo = base + 40 + layer * 10
      reaper.gmem_write(lo + 0, L.len or 0)
      reaper.gmem_write(lo + 1, L.start or 0)
      reaper.gmem_write(lo + 2, L["end"] or 1.0)
      reaper.gmem_write(lo + 3, L.sr or 0)
      reaper.gmem_write(lo + 4, L.norm or 0)
      reaper.gmem_write(lo + 5, L.norm_gain or 1.0)
      reaper.gmem_write(lo + 6, L.vel_lo or 0)
      reaper.gmem_write(lo + 7, L.vel_hi or 127)
      reaper.gmem_write(lo + 8, L.rr_order or layer)
      reaper.gmem_write(lo + 9, L.gain or 1.0)
    end

    -- Pad name
    local name = p.name or ""
    local name_base = PADNAME_BASE + pad * PADNAME_LEN
    for i = 0, PADNAME_LEN - 1 do
      reaper.gmem_write(name_base + i, i < #name and name:byte(i + 1) or 0)
    end

    -- Breadcrumb (audio is baked, but path is informational)
    local path = p.path or ""
    if path ~= "" then
      reaper.SetExtState("Swing", "pad_path_" .. pad, path, false)
    end
  end

  -- Per-pad audio: write samples from pad_buffers to gmem AUDIO_BASE at
  -- running offset. wav.read returns int16; gmem expects -1.0..1.0 floats
  -- (matches the v4 unpack_s16 division by 32767.0).
  local audio_off = 0
  for pad = 0, NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local lc = pad_layer_cnts[pad]
    if lc > 0 then
      -- Layered: concatenate each layer's audio into gmem in order
      local total_alen = 0
      for layer = 0, lc - 1 do
        local L = (p.layers or {})[layer + 1] or {}
        local wav_name = L.audio
        local buf = wav_name and pad_buffers[wav_name]
        local l_alen, l_sr = 0, 0
        if buf and buf.samples then
          local samples = buf.samples
          l_sr = buf.sample_rate or 0
          local count = #samples
          if audio_off + count > GMEM_AUDIO_MAX then
            count = math.max(0, GMEM_AUDIO_MAX - audio_off)
          end
          for j = 0, count - 1 do
            reaper.gmem_write(AUDIO_BASE + audio_off + j, samples[j + 1] / 32767.0)
          end
          l_alen = count
          audio_off = audio_off + count
        end
        local lo = META_BASE + pad * META_PP + 40 + layer * 10
        reaper.gmem_write(lo + 0, l_alen)   -- l_len from wav (binary truth)
        reaper.gmem_write(lo + 3, l_sr)     -- l_sr
        total_alen = total_alen + l_alen
      end
      reaper.gmem_write(AUDIOLEN_BASE + pad, total_alen)
      reaper.gmem_write(META_BASE + pad * META_PP + 34, 0)
    else
      -- Non-layered: single pad blob
      local wav_name = p.audio
      local buf = wav_name and pad_buffers[wav_name]
      local s_alen, s_sr = 0, 0
      if buf and buf.samples then
        local samples = buf.samples
        s_sr = buf.sample_rate or 0
        local count = #samples
        if audio_off + count > GMEM_AUDIO_MAX then
          count = math.max(0, GMEM_AUDIO_MAX - audio_off)
        end
        for j = 0, count - 1 do
          reaper.gmem_write(AUDIO_BASE + audio_off + j, samples[j + 1] / 32767.0)
        end
        s_alen = count
        audio_off = audio_off + count
      end
      reaper.gmem_write(AUDIOLEN_BASE + pad, s_alen)
      reaper.gmem_write(META_BASE + pad * META_PP + 34, s_alen)  -- s_len
      reaper.gmem_write(META_BASE + pad * META_PP + 37, s_sr)    -- s_sr
    end
  end

  -- Signal JSFX (same VER=24 marker that load_kit_v4 uses)
  reaper.gmem_write(2, NUM_PADS)
  reaper.gmem_write(1, 24)
  reaper.gmem_write(CMD, 3)
  update_folder_track_name(find_swing_track())
end

local function load_swing_dispatch(filepath)
  local valid, fmt = validate_swing(filepath)
  if not valid then
    reaper.ShowMessageBox("Invalid file: " .. (fmt or ""), SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Track this path as the source for the requesting instance, so a
  -- subsequent project save can copy this exact file to the project's
  -- sidecar location (instead of rebuilding from gmem, which is racy
  -- across multi-window @gfx mirrors). Every kit-load route ends up
  -- here, so this single hook covers manual LOAD button, browser kit
  -- pick, drag-drop kit, auto-sidecar reload, etc.
  --
  -- Identify the requesting instance: prefer LOCK (set by JSFX-side
  -- LOAD button as `gmem[LOCK] = instance_id; gmem[CMD] = 2`), fall back
  -- to INSTANCE (browser-target slot, set by the browser picker before
  -- triggering kit_load_req without taking LOCK).
  --
  -- Also persist the path to per-track ExtState (P_EXT:swing_kit_src)
  -- so it survives REAPER restarts and project reopens. Without this,
  -- opening a saved project starts with empty kit_sources and the
  -- chunk-loaded kits can't be saved to sidecar without manual reload.
  if kit_sources then
    -- Identifier resolution order (each ID points at the requesting instance):
    --   LOCK                 — JSFX-side LOAD button took it before writing CMD=2
    --   GS_PENDING_LOAD_INST — auto-load 808 / browser-driven path; survives
    --                          the bridge's CMD auto-release (LOCK cleared
    --                          after CMD 22 dispatch but PENDING is still set
    --                          when kit_load_req's deferred dispatch fires)
    --   INSTANCE             — browser picker target, set by browser script
    local lock_id    = math.floor(reaper.gmem_read(LOCK) or 0)
    local pending_id = math.floor(reaper.gmem_read(G.GS_PENDING_LOAD_INST) or 0)
    local inst_id_gmem = math.floor(reaper.gmem_read(INSTANCE) or 0)
    local target_id = lock_id > 0 and lock_id
                   or (pending_id > 0 and pending_id)
                   or inst_id_gmem
    if target_id > 0 then
      kit_sources[target_id] = filepath
      -- Find the track that owns this instance and stash the path on it.
      -- Use a `done` flag to break out of both loops; `return` here would
      -- exit load_swing_dispatch entirely, skipping the actual kit load!
      local done = false
      for tr in core.iter_all_tracks() do
        if done then break end
        for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
          if is_swing_fx(tr, fx) then
            local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
            if inst_id == target_id then
              reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:swing_kit_src", filepath, true)
              done = true
              break
            end
          end
        end
      end
    end
  end

  if fmt == "v5" then
    load_kit_v5(filepath)
  elseif fmt == "v4" then
    load_kit_v4(filepath)
  elseif fmt == "v3" then
    load_kit_v3(filepath)
  elseif fmt == "v2" then
    -- Legacy path-only format — best-effort load (pads may be blank if source
    -- files have moved). Users should re-save to upgrade these to v5.
    load_kit_v2(filepath)
  else
    -- v1 binary format (already self-contained)
    load_swing_file(filepath)
  end
end

-- CMD 2: Import from kit browser (Swing_Kits folder)
local function do_import()
  local kits, kits_dir = enumerate_kits()

  if #kits == 0 then
    reaper.ShowMessageBox(
      "No .swing kit files found.\n\nKit directory:\n" .. kits_dir ..
      "\n\nSave a kit first, or place .swing files in this folder.",
      SCRIPT_NAME, 0
    )
    reaper.gmem_write(CMD, 98)
    return
  end

  local menu_str = ""
  for i, k in ipairs(kits) do
    if i > 1 then menu_str = menu_str .. "|" end
    menu_str = menu_str .. k.name .. "  (" .. format_size(k.size) .. ")"
  end

  -- Wrap gfx.init/showmenu/quit in pcall so a transient failure (display
  -- driver hiccup, exotic OS DPI state, etc.) doesn't leak a gfx context
  -- and brick the bridge. On error: report via console, fail the CMD.
  local ok, choice = pcall(function()
    gfx.init("Swing Kit Browser", 1, 1, 0, 0, 0)
    gfx.x = gfx.mouse_x; gfx.y = gfx.mouse_y
    local c = gfx.showmenu(menu_str)
    gfx.quit()
    return c
  end)
  if not ok then
    -- Defensive cleanup in case gfx.init succeeded but quit didn't run
    pcall(gfx.quit)
    reaper.ShowConsoleMsg("[Swing Bridge] gfx menu failed: " .. tostring(choice) .. "\n")
    reaper.gmem_write(CMD, 98); return
  end

  if choice <= 0 then reaper.gmem_write(CMD, 98); return end

  local selected = kits[choice]
  if not selected then reaper.gmem_write(CMD, 98); return end

  load_swing_dispatch(selected.path)
end

-- CMD 16: Import from full PC browse (any folder)
local function do_import_browse()
  local has_js = reaper.JS_Dialog_BrowseForOpenFiles ~= nil
  if not has_js then
    -- Fallback: GetUserInputs
    local retval, input = reaper.GetUserInputs("Load Swing Kit", 1, "Full path to .swing file:,extrawidth=300", "")
    if not retval or input == "" then reaper.gmem_write(CMD, 98); return end
    load_swing_dispatch(input)
    return
  end

  local retval, filepath = reaper.JS_Dialog_BrowseForOpenFiles(
    "Load Swing Kit", get_kits_dir(), "", "Swing Kit Files (*.swing)\0*.swing\0All Files (*.*)\0*.*\0", false
  )
  if not retval or filepath == "" then reaper.gmem_write(CMD, 98); return end

  load_swing_dispatch(filepath)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- MULTI-OUT TRACK BUILDER (CMD 40)
-- ═════════════════════════════════════════════════════════════════════════════

local function do_build_multiout()
  local swing_track, swing_fx = find_swing_track()
  if not swing_track then
    reaper.ShowMessageBox(
      "Could not find Swing on any track.\n\n" ..
      "Make sure Swing (Swing_ReaKit.jsfx) is loaded as an FX on a track.",
      SCRIPT_NAME, 0
    )
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Read pad names and colors from gmem (JSFX syncs these before sending CMD=40)
  local pad_names = {}
  local pad_hues = {}
  for i = 0, NUM_PADS - 1 do
    local chars = {}
    for j = 0, PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(PADNAME_BASE + i * PADNAME_LEN + j))
      if c > 0 and c < 128 then chars[#chars + 1] = string.char(c) end
    end
    local name = table.concat(chars)
    if name == "" then name = "Pad " .. (i + 1) end
    pad_names[i] = name

    local hue = reaper.gmem_read(META_BASE + i * META_PP + 12)
    -- Allow negative sentinels through (-1 = white, -2 = black)
    if hue > 1 then hue = i / 16.0 end
    pad_hues[i] = hue
  end

  -- Helper: generate track name from pad name
  local function make_track_name(idx)
    local pname = pad_names[idx]
    if pname ~= "" and pname ~= string.format("Pad %d", idx + 1) then
      return pname
    else
      return string.format("%02d", idx + 1)
    end
  end

  -- Check if multi-out tracks already exist (look for sends from Swing track)
  local existing_sends = reaper.GetTrackNumSends(swing_track, 0)
  if existing_sends >= 16 then
    -- Collect existing send destination tracks keyed by source channel pair
    local send_dest = {}
    for s = 0, existing_sends - 1 do
      local src_chan = math.floor(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
      local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
      if dest_tr then send_dest[src_chan] = dest_tr end
    end

    -- YES = Rebuild (delete + recreate), NO = Update (rename + recolor in place)
    local choice = reaper.ShowMessageBox(
      "Multi-out tracks already exist (" .. existing_sends .. " sends).\n\n" ..
      "YES = Rebuild (delete old tracks, create fresh)\n" ..
      "NO = Update (keep tracks, refresh names & colors)",
      SCRIPT_NAME, 3  -- Yes/No/Cancel → 6=Yes, 7=No, 2=Cancel
    )

    if choice == 7 then
      -- UPDATE: refresh names and colors on existing send destinations
      reaper.Undo_BeginBlock()
      reaper.PreventUIRefresh(1)
      local updated = 0
      for i = 0, NUM_PADS - 1 do
        local dest_tr = send_dest[i * 2]
        if dest_tr then
          reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", make_track_name(i), true)
          if reaper.gmem_read(AUDIOLEN_BASE + i) > 0 then
            local s = reaper.gmem_read(GS_COL_EFFECTIVE_S)
            local l = reaper.gmem_read(GS_COL_EFFECTIVE_L)
            if l <= 0 then s = 0.75; l = 0.55 end
            local r, g, b = hsl_to_rgb(pad_hues[i], s, l)
            local color = reaper.ColorToNative(r, g, b) | 0x1000000
            reaper.SetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR", color)
          else
            -- Empty pad → remove custom color (REAPER default)
            reaper.SetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR", 0)
          end
          updated = updated + 1
        end
      end
      update_folder_track_name(swing_track)
      -- Ensure the JSFX-hosting track is named "Swing"
      reaper.GetSetMediaTrackInfo_String(swing_track, "P_NAME", "Swing", true)
      reaper.PreventUIRefresh(-1)
      reaper.TrackList_AdjustWindows(false)
      reaper.Undo_EndBlock("Swing: Update multi-out track names & colors", -1)
      reaper.gmem_write(CMD, 99)

      local summary = "Updated " .. updated .. " multi-out tracks:\n\n"
      for i = 0, NUM_PADS - 1 do
        summary = summary .. string.format("  Ch %02d → %s\n", i + 1, make_track_name(i))
      end
      reaper.ShowMessageBox(summary, SCRIPT_NAME, 0)
      return

    elseif choice == 6 then
      -- REBUILD: delete old destination tracks and sends, then fall through to create new
      reaper.Undo_BeginBlock()
      reaper.PreventUIRefresh(1)
      -- Remove sends first (reverse order)
      for s = existing_sends - 1, 0, -1 do
        reaper.RemoveTrackSend(swing_track, 0, s)
      end
      -- Delete destination tracks (sort by index descending to avoid shift)
      local tracks_to_delete = {}
      for _, tr in pairs(send_dest) do
        tracks_to_delete[#tracks_to_delete + 1] = tr
      end
      table.sort(tracks_to_delete, function(a, b)
        return reaper.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER") >
               reaper.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")
      end)
      for _, tr in ipairs(tracks_to_delete) do
        reaper.DeleteTrack(tr)
      end
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Swing: Remove old multi-out tracks", -1)
      -- Fall through to create new tracks below

    else
      -- Cancel / closed dialog
      reaper.gmem_write(CMD, 98)
      return
    end
  end

  local swing_idx = math.floor(reaper.GetMediaTrackInfo_Value(swing_track, "IP_TRACKNUMBER")) - 1

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Create folder track above Swing (skip if one already exists)
  local existing_folder = find_folder_track(swing_track)
  if not existing_folder then
    reaper.InsertTrackAtIndex(swing_idx, true)
    local folder_tr = reaper.GetTrack(0, swing_idx)
    reaper.SetMediaTrackInfo_Value(folder_tr, "I_FOLDERDEPTH", 1)
    -- Swing track is now at swing_idx + 1
    swing_idx = swing_idx + 1
  end
  -- Name/rename the folder track
  update_folder_track_name(swing_track)
  -- Ensure the JSFX-hosting track is named "Swing"
  reaper.GetSetMediaTrackInfo_String(swing_track, "P_NAME", "Swing", true)

  -- Create 16 child tracks
  local created = {}
  for i = 0, NUM_PADS - 1 do
    local insert_idx = swing_idx + 1 + i
    reaper.InsertTrackAtIndex(insert_idx, true)
    local tr = reaper.GetTrack(0, insert_idx)
    if not tr then break end

    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", make_track_name(i), true)

    if reaper.gmem_read(AUDIOLEN_BASE + i) > 0 then
      local s = reaper.gmem_read(GS_COL_EFFECTIVE_S)
      local l = reaper.gmem_read(GS_COL_EFFECTIVE_L)
      if l <= 0 then s = 0.75; l = 0.55 end
      local r, g, b = hsl_to_rgb(pad_hues[i], s, l)
      local color = reaper.ColorToNative(r, g, b) | 0x1000000
      reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", color)
    else
      -- Empty pad → no custom color (REAPER default)
      reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", 0)
    end

    reaper.SetMediaTrackInfo_Value(tr, "I_HEIGHTOVERRIDE", 28)

    local send_idx = reaper.CreateTrackSend(swing_track, tr)
    if send_idx >= 0 then
      reaper.SetTrackSendInfo_Value(swing_track, 0, send_idx, "I_SRCCHAN", i * 2)
      reaper.SetTrackSendInfo_Value(swing_track, 0, send_idx, "I_DSTCHAN", 0)
      reaper.SetTrackSendInfo_Value(swing_track, 0, send_idx, "I_SENDMODE", 0)
    end

    created[#created + 1] = tr
  end

  if #created > 0 then
    reaper.SetMediaTrackInfo_Value(swing_track, "B_MAINSEND", 0)
    -- Close folder on last child track
    reaper.SetMediaTrackInfo_Value(created[#created], "I_FOLDERDEPTH", -1)
  end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("Swing: Build " .. #created .. " multi-out tracks", -1)

  reaper.gmem_write(CMD, 99)

  local summary = "Multi-out routing created!\n\n"
  for i = 0, math.min(#created - 1, 15) do
    summary = summary .. string.format("  Ch %02d → %s\n", i + 1, pad_names[i])
  end
  summary = summary .. "\nSwing master send muted (audio routes through child tracks)."
  reaper.ShowMessageBox(summary, SCRIPT_NAME, 0)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- BATCH IMPORT (CMD 20)
-- ═════════════════════════════════════════════════════════════════════════════

local function do_batch_import()
  -- Browse for folder
  local folder = nil
  local has_js = reaper.JS_Dialog_BrowseForFolder ~= nil
  if has_js then
    local retval, path = reaper.JS_Dialog_BrowseForFolder("Select sample folder for batch import", get_kits_dir())
    if retval == 1 and path ~= "" then folder = path end
  else
    local retval, input = reaper.GetUserInputs("Batch Import", 1, "Folder path:,extrawidth=300", "")
    if retval and input ~= "" then folder = input end
  end

  if not folder then reaper.gmem_write(CMD, 98); return end

  -- Enumerate audio files
  local files = {}
  local idx = 0
  while true do
    local fname = reaper.EnumerateFiles(folder, idx)
    if not fname then break end
    if core.is_native_audio(fname) then
      files[#files + 1] = {
        name = fname,
        path = folder .. sep .. fname,
        display = fname:gsub("%.[^.]+$", "")
      }
    end
    idx = idx + 1
  end

  if #files == 0 then
    reaper.ShowMessageBox("No audio files found in:\n" .. folder, SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Sort alphabetically
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)

  -- Limit to 16 pads
  local count = math.min(#files, NUM_PADS)

  -- Confirm
  local msg = "Found " .. #files .. " audio files.\n"
  if #files > 16 then msg = msg .. "Only the first 16 will be loaded.\n" end
  msg = msg .. "\nFiles:\n"
  for i = 1, count do
    msg = msg .. "  Pad " .. i .. ": " .. files[i].name .. "\n"
  end
  msg = msg .. "\nLoad these samples?"
  if reaper.ShowMessageBox(msg, SCRIPT_NAME, 4) ~= 6 then
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Acquire one scratch track for the whole batch — placed at the end of
  -- the project so we don't pollute the user's first track. Reused for
  -- every pad's temp item (track stays until release after the loop).
  local scratch_tr = acquire_scratch_track()

  -- Load each file via audio accessor and write to gmem
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local audio_offset = 0
  for i = 0, count - 1 do
    local file = files[i + 1]
    local source = reaper.PCM_Source_CreateFromFile(file.path)
    if source then
      local sr = reaper.GetMediaSourceSampleRate(source)
      local length = reaper.GetMediaSourceLength(source)
      local nch = ({reaper.GetMediaSourceNumChannels(source)})[1] or 1
      local num_samples = math.floor(length * sr)

      -- Cap at SLOT_SIZE/2 (each mono frame → 2 interleaved) and total gmem capacity
      num_samples = math.min(num_samples, math.floor(SLOT_SIZE / 2))
      if audio_offset + num_samples * 2 > GMEM_AUDIO_MAX then
        num_samples = math.floor((GMEM_AUDIO_MAX - audio_offset) / 2)
        if num_samples <= 0 then
          reaper.PCM_Source_Destroy(source)
          break
        end
      end

      -- Create a temporary item on the scratch track to get an audio accessor
      if not scratch_tr then break end  -- safety: track creation failed
      local temp_item = reaper.AddMediaItemToTrack(scratch_tr)
      local temp_take = reaper.AddTakeToMediaItem(temp_item)
      reaper.SetMediaItemTake_Source(temp_take, source)
      reaper.SetMediaItemInfo_Value(temp_item, "D_LENGTH", length)

      local aa = reaper.CreateTakeAudioAccessor(temp_take)
      if aa then
        -- Read samples (mono mixdown)
        local chunk_size = math.min(num_samples, 1000000)
        local samples_read = 0
        local start_time = 0.0
        local sample_buf = reaper.new_array(chunk_size * nch)

        while samples_read < num_samples do
          local to_read = math.min(chunk_size, num_samples - samples_read)
          sample_buf.clear()
          reaper.GetAudioAccessorSamples(aa, sr, nch, start_time + samples_read / sr, to_read, sample_buf)

          -- Write to gmem as stereo interleaved (duplicate mono to L+R)
          for j = 0, to_read - 1 do
            local val = 0
            -- Mono source: duplicate; stereo source: preserve L/R; 3+ ch:
            -- take ch0/ch1 and drop the rest (same convention as the
            -- single-file loader above).
            local valL, valR
            if nch == 1 then
              valL = sample_buf[j + 1]
              valR = valL
            else
              valL = sample_buf[j * nch + 1] or 0
              valR = sample_buf[j * nch + 2] or 0
            end
            -- Write L and R (interleaved stereo, matching JSFX playback format)
            local dst = AUDIO_BASE + audio_offset + (samples_read + j) * 2
            reaper.gmem_write(dst,     valL)
            reaper.gmem_write(dst + 1, valR)
          end
          samples_read = samples_read + to_read
        end

        reaper.DestroyAudioAccessor(aa)

        -- Write metadata, audio length, and pad name
        local interleaved_len = num_samples * 2
        local _, hue = guess_drum_type(file.display)
        write_default_pad_meta(i, interleaved_len, sr, hue, file.display)
        audio_offset = audio_offset + interleaved_len
      end

      -- Clean up temp item (the scratch track itself is released after the loop)
      reaper.DeleteTrackMediaItem(scratch_tr, temp_item)
    end
  end

  reaper.PreventUIRefresh(-1)
  release_scratch_track(scratch_tr)
  -- Was: flag=8 (no undo point) — meant the entire batch-import was
  -- non-undoable. Switched to flag=-1 so the user can Ctrl+Z to revert
  -- a folder import. The scratch-track manipulation is wrapped in
  -- PreventUIRefresh so REAPER doesn't add UI flicker; the chunk diff
  -- captures all the gmem state changes that the JSFX picks up next
  -- frame via CMD 3.
  reaper.Undo_EndBlock("Swing: Batch import", -1)

  -- Clear unused pads
  for i = count, NUM_PADS - 1 do
    reaper.gmem_write(AUDIOLEN_BASE + i, 0)
    local mb = META_BASE + i * META_PP
    for j = 0, META_PP - 1 do reaper.gmem_write(mb + j, 0) end
  end

  -- Signal JSFX
  reaper.gmem_write(CMD, 3)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- CHOP-TO-PADS (CMD 30)
-- ═════════════════════════════════════════════════════════════════════════════

local function do_chop_to_pads()
  -- Get selected media item
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    reaper.ShowMessageBox(
      "No media item selected.\n\nSelect an audio item on the timeline, then try again.",
      SCRIPT_NAME, 0
    )
    reaper.gmem_write(CMD, 98)
    return
  end

  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    reaper.ShowMessageBox("Selected item is not audio.", SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  local source = reaper.GetMediaItemTake_Source(take)
  local sr = reaper.GetMediaSourceSampleRate(source)
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local nch = ({reaper.GetMediaSourceNumChannels(source)})[1] or 1
  local total_samples = math.floor(item_len * sr)

  -- Ask for number of slices
  local retval, input = reaper.GetUserInputs(
    "Chop to Pads", 2,
    "Number of slices (2-16):,Transient detection (0=equal, 1=auto):,extrawidth=180",
    "16,0"
  )
  if not retval then reaper.gmem_write(CMD, 98); return end

  local fields = {}
  for field in (input .. ","):gmatch("(.-),") do
    fields[#fields + 1] = field
  end
  local num_slices = math.max(2, math.min(16, math.floor(tonumber(fields[1]) or 16)))
  local use_transients = (tonumber(fields[2]) or 0) == 1

  -- Create audio accessor
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then
    reaper.ShowMessageBox("Could not create audio accessor.", SCRIPT_NAME, 0)
    reaper.gmem_write(CMD, 98)
    return
  end

  -- Cap total samples to prevent runaway memory allocation (~60s stereo @ 192kHz)
  local MAX_CHOP_SAMPLES = 12000000
  if total_samples > MAX_CHOP_SAMPLES then total_samples = MAX_CHOP_SAMPLES end

  -- Read entire audio into Lua table
  local full_buf = reaper.new_array(total_samples * nch)
  full_buf.clear()
  reaper.GetAudioAccessorSamples(aa, sr, nch, 0, total_samples, full_buf)

  -- Mono mixdown into a Lua table
  local mono = {}
  for j = 0, total_samples - 1 do
    if nch == 1 then
      mono[j] = full_buf[j + 1]
    else
      local sum = 0
      for ch = 0, nch - 1 do
        sum = sum + (full_buf[j * nch + ch + 1] or 0)
      end
      mono[j] = sum / nch
    end
  end

  reaper.DestroyAudioAccessor(aa)

  -- Compute slice points
  local slice_points = {}
  if use_transients and num_slices <= 16 then
    -- Energy-based transient detection
    local window = math.floor(sr * 0.01)  -- 10ms window
    local hop = math.floor(window / 2)
    local energies = {}
    local max_energy = 0

    for pos = 0, total_samples - window, hop do
      local sum = 0
      for k = pos, pos + window - 1 do
        local s = mono[k] or 0
        sum = sum + s * s
      end
      local e = sum / window
      energies[#energies + 1] = {pos = pos, energy = e}
      if e > max_energy then max_energy = e end
    end

    -- Find peaks in energy derivative (onsets)
    local onsets = {0}  -- always start at 0
    local threshold = max_energy * 0.05
    local min_gap = math.floor(sr * 0.05)  -- min 50ms between onsets

    for i = 2, #energies do
      local diff = energies[i].energy - energies[i-1].energy
      if diff > threshold then
        local pos = energies[i].pos
        if pos - onsets[#onsets] >= min_gap then
          onsets[#onsets + 1] = pos
        end
      end
    end

    -- If we got more onsets than slices, take the strongest
    if #onsets > num_slices then
      -- Pre-build energy lookup map (avoids O(n²) scan in comparator)
      local energy_map = {}
      for _, e in ipairs(energies) do energy_map[e.pos] = e.energy end
      -- Keep first onset (0), then pick the strongest N-1
      table.sort(onsets, function(a, b)
        return (energy_map[a] or 0) > (energy_map[b] or 0)
      end)
      local top = {0}
      for i = 1, #onsets do
        if onsets[i] ~= 0 then
          top[#top + 1] = onsets[i]
          if #top >= num_slices then break end
        end
      end
      table.sort(top)
      onsets = top
    end

    -- If fewer onsets than slices, fall back to equal
    if #onsets < num_slices then
      onsets = {}
      for i = 0, num_slices - 1 do
        onsets[#onsets + 1] = math.floor(i * total_samples / num_slices)
      end
    end

    slice_points = onsets
  else
    -- Equal division
    for i = 0, num_slices - 1 do
      slice_points[#slice_points + 1] = math.floor(i * total_samples / num_slices)
    end
  end

  -- Add end point
  slice_points[#slice_points + 1] = total_samples

  -- Wrap the gmem mutation in an undo block so the user can Ctrl+Z to
  -- revert a chop operation. Closed at the bottom of the function with
  -- Undo_EndBlock("Swing: Chop to Pads", -1). All early-return paths
  -- bail BEFORE this line, so they don't open an empty block.
  reaper.Undo_BeginBlock()

  -- Write slices to gmem as individual pads
  local audio_offset = 0
  local source_name = ({reaper.GetMediaSourceFileName(source, "")})[2] or ""
  local base_name = source_name:match("([^/\\]+)%.[^.]+$") or "Chop"

  for i = 1, math.min(#slice_points - 1, NUM_PADS) do
    local pad = i - 1
    local start_samp = slice_points[i]
    local end_samp = slice_points[i + 1]
    local slice_len = end_samp - start_samp

    if slice_len > 0 then
      -- Cap at SLOT_SIZE/2 (each mono frame becomes 2 interleaved samples)
      slice_len = math.min(slice_len, math.floor(SLOT_SIZE / 2))
      -- Cap at total gmem capacity
      if audio_offset + slice_len * 2 > GMEM_AUDIO_MAX then
        slice_len = math.floor((GMEM_AUDIO_MAX - audio_offset) / 2)
        if slice_len <= 0 then break end
      end

      -- Write audio as stereo interleaved (duplicate mono to L+R)
      for j = 0, slice_len - 1 do
        local val = mono[start_samp + j] or 0
        reaper.gmem_write(AUDIO_BASE + audio_offset + j * 2,     val)
        reaper.gmem_write(AUDIO_BASE + audio_offset + j * 2 + 1, val)
      end

      -- Metadata, audio length, and pad name
      local interleaved_len = slice_len * 2
      local pad_name = base_name .. " " .. i
      write_default_pad_meta(pad, interleaved_len, sr, pad / 16.0, pad_name)
      audio_offset = audio_offset + interleaved_len
    end
  end

  -- Clear unused pads
  local used = math.min(#slice_points - 1, NUM_PADS)
  for i = used, NUM_PADS - 1 do
    reaper.gmem_write(AUDIOLEN_BASE + i, 0)
    local mb = META_BASE + i * META_PP
    for j = 0, META_PP - 1 do reaper.gmem_write(mb + j, 0) end
  end

  -- Write kit name
  local kit_name = "Chop: " .. base_name
  gmem_write_string(kit_name:sub(1, 32), NAME_BASE, NAMELEN, 32)

  -- Clear stale per-pad disk-path breadcrumbs. Chop replaces pad audio with
  -- gmem-resident slices that have NO disk source. Leaving the previously-
  -- loaded kit's paths in ExtState was confusing the v4 save path before
  -- the bridge was rewritten to ignore ExtState for non-layered pads, and
  -- it still bakes wrong "path = ..." breadcrumbs into the kit's lua
  -- metadata. Clearing them keeps the saved kit file metadata honest.
  for pad = 0, NUM_PADS - 1 do
    reaper.SetExtState("Swing", "pad_path_" .. pad, "", false)
  end

  reaper.gmem_write(CMD, 3)  -- data ready for JSFX
  update_folder_track_name(find_swing_track())
  reaper.Undo_EndBlock("Swing: Chop to Pads (" .. (#slice_points - 1) .. " slices)", -1)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- AUTO-COLOR PADS (CMD 23)
-- ═════════════════════════════════════════════════════════════════════════════

local function do_auto_color()
  local colored = 0
  for i = 0, NUM_PADS - 1 do
    -- Read pad name
    local chars = {}
    for j = 0, PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(PADNAME_BASE + i * PADNAME_LEN + j))
      if c > 0 then chars[#chars + 1] = string.char(c) end
    end
    local name = table.concat(chars)
    if name ~= "" then
      local _, hue = guess_drum_type(name)
      if hue then
        -- Write color to metadata slot 12
        reaper.gmem_write(META_BASE + i * META_PP + 12, hue)
        colored = colored + 1
      end
    end
  end

  reaper.gmem_write(CMD, 99)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- MAIN LOOP
-- ═════════════════════════════════════════════════════════════════════════════

-- Self-register as startup action (one-time, first manual run).
-- The block written to __startup.lua is SELF-CLEANING: when the script
-- file is removed (e.g. via ReaPack uninstall), the block detects that
-- its registered command ID can no longer be resolved, strips itself
-- out of __startup.lua, and clears the registered_v3 ExtState so a
-- future reinstall will register fresh. No manual cleanup needed.
--
-- Bump from registered_v2 to registered_v3 forces existing installs
-- (which have the old single-line format) to re-register and pick up
-- the new self-cleaning block on next bridge run.
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
  -- the bridge as usual. When `id == 0` (file removed via ReaPack uninstall),
  -- strips this block from __startup.lua and clears the registered_v3
  -- ExtState. The cleanup runs at most once per uninstall — once the block
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
self_register()

reaper.gmem_attach(GMEM_NAME)
reaper.gmem_write(BRIDGE_ALIVE, os.time())

-- Ensure 32 channels on Swing track at bridge startup
local function ensure_32ch()
  local lock_id = math.floor(reaper.gmem_read(LOCK))
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        if reaper.GetMediaTrackInfo_Value(tr, "I_NCHAN") < 32 then
          reaper.SetMediaTrackInfo_Value(tr, "I_NCHAN", 32)
        end
      end
    end
  end
end

ensure_32ch()  -- run once at startup

-- ── Auto-detect factory kits alongside the script and move to Swing_Kits ──
local function auto_migrate_kits()
  -- Get this script's directory
  local info = debug.getinfo(1, "S")
  local script_path = info and info.source and info.source:match("^@?(.+)$") or ""
  local script_dir = script_path:match("(.*[/\\])") or ""
  if script_dir == "" then return end

  -- Scan for .swing files in the same directory
  local found = {}
  local i = 0
  while true do
    local fname = reaper.EnumerateFiles(script_dir, i)
    if not fname then break end
    if fname:match("%.swing$") then
      found[#found + 1] = fname
    end
    i = i + 1
  end
  if #found == 0 then return end

  -- Check which ones are NOT already in the kits directory
  local kits_dir = get_kits_dir()
  local to_move = {}
  for _, fname in ipairs(found) do
    local dest = kits_dir .. sep .. fname
    local f = io.open(dest, "rb")
    if f then
      f:close()  -- already exists in kits dir, skip
    else
      to_move[#to_move + 1] = fname
    end
  end
  if #to_move == 0 then return end

  -- Prompt user
  local names = table.concat(to_move, ", ")
  local msg = "Found " .. #to_move .. " kit file(s) alongside Swing:\n\n" ..
              names .. "\n\n" ..
              "Move them to your Swing_Kits folder?\n" ..
              kits_dir
  local ok = reaper.ShowMessageBox(msg, SCRIPT_NAME, 4)
  if ok ~= 6 then return end  -- user said No

  -- Move files
  local moved = 0
  for _, fname in ipairs(to_move) do
    local src = script_dir .. fname
    local dest = kits_dir .. sep .. fname
    -- Read source
    local f_in = io.open(src, "rb")
    if f_in then
      local data = f_in:read("*a")
      f_in:close()
      -- Write destination
      local f_out = io.open(dest, "wb")
      if f_out then
        f_out:write(data)
        f_out:close()
        -- Delete source
        os.remove(src)
        moved = moved + 1
      end
    end
  end

  if moved > 0 then
    reaper.ShowMessageBox(
      "Moved " .. moved .. " kit(s) to:\n" .. kits_dir,
      SCRIPT_NAME, 0)
  end
end

auto_migrate_kits()  -- run once at startup

-- ═══════════════════════════════════════════════════════════════════════════════
-- EON LOADER PROTOCOL v1 — file-based external loader
-- ═══════════════════════════════════════════════════════════════════════════════
-- Lets any REAPER script load samples into Swing without gmem knowledge.
-- External script writes <reaper_resource>/Data/EON_Loader/pending_<unique>.txt
-- with key=value lines; bridge polls, validates, and routes through the
-- existing load_audio_to_pad pipeline. See EON_Loader_Protocol_v1.md for the
-- public-facing spec.
--
-- Multi-instance note (v2.1.1): the loader routes to whichever Swing instance
-- find_swing_track() returns (LOCK holder, or first found). External scripts
-- have no way to target a specific instance yet — that's planned for protocol
-- v2 with an optional instance_id field.

local LOADER_DIR = reaper.GetResourcePath() .. sep .. "Data" .. sep .. "EON_Loader"
reaper.RecursiveCreateDirectory(LOADER_DIR, 0)

-- Per-request retry counter prevents stale files from looping forever when
-- no Swing is connected (could happen if the user closes Swing right after
-- a third-party script wrote a request).
local loader_retries = {}
local LOADER_MAX_RETRIES = 30  -- ~1 second at typical defer rate

local function loader_parse_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  if not content then return nil end

  local req = {}
  for line in content:gmatch("[^\r\n]+") do
    local k, v = line:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
    if k and v then req[k:lower()] = v end
  end
  return req
end

local function loader_process_one(path)
  local req = loader_parse_file(path)
  if not req then
    os.remove(path)
    return
  end

  -- Forward-compat: only target=swing handled in v2.1.1 (target field reserves
  -- coupe / sedan / press for future products). Unknown targets silently
  -- discarded so a future-targeted file doesn't pile up here.
  if (req.target or "swing"):lower() ~= "swing" then
    os.remove(path)
    return
  end

  -- Validate filepath exists and is readable
  if not req.filepath or req.filepath == "" then
    os.remove(path)
    return
  end
  local probe = io.open(req.filepath, "rb")
  if not probe then
    os.remove(path)
    return
  end
  probe:close()

  -- Validate pad index
  local pad = tonumber(req.pad) or 0
  if pad < 0 or pad > 15 then
    os.remove(path)
    return
  end

  -- Need a Swing instance to route to. If none, defer; if persistently absent,
  -- give up to keep the request directory clean.
  local tr = find_swing_track()
  if not tr then
    loader_retries[path] = (loader_retries[path] or 0) + 1
    if loader_retries[path] > LOADER_MAX_RETRIES then
      os.remove(path)
      loader_retries[path] = nil
    end
    return
  end

  -- Route through existing load pipeline (same path as CMD 61 from browser)
  if load_audio_to_pad(req.filepath, pad) then
    reaper.gmem_write(PARAM1, pad)
    reaper.gmem_write(CMD, 3)  -- "import data ready" — JSFX picks up via state machine
  end

  os.remove(path)
  loader_retries[path] = nil
end

local function loader_poll()
  local i = 0
  repeat
    local fname = reaper.EnumerateFiles(LOADER_DIR, i)
    if fname and fname:match("^pending_") and fname:sub(-4) == ".txt" then
      loader_process_one(LOADER_DIR .. sep .. fname)
    end
    i = i + 1
  until not fname or i > 100  -- safety cap; 100 pending requests per poll is plenty
end

local heartbeat_counter = 0

-- ─── Real-time multi-out track color sync ────────────────────────────────
-- Watch the JSFX's pad-color slots in gmem and propagate any change to the
-- multi-out child tracks. Triggers naturally when the user loads a new kit
-- (kit load fires pad_colors), changes a pad's color manually via the
-- overlay color picker, or runs auto-color (CMD 23). Cost: 16 gmem_reads
-- per defer tick to compute a hash; the work loop only runs when the hash
-- actually changes AND multi-out tracks exist.
--
-- Bridge-side because the JSFX doesn't have track-state access — gmem is
-- the only path from JSFX to track metadata.
local last_pad_color_hash = -1

local function refresh_multiout_colors_if_changed()
  -- Hash the 16 hue floats + per-pad audio state + the broadcast effective
  -- saturation and lightness slots. Quantize to int*1000 so floating-point
  -- noise doesn't trigger a redundant refresh. Including S/L in the hash
  -- means changes to the intensity dial or theme picker also trigger an
  -- update, not just per-pad hue changes. Audio state is included so that
  -- pad load/clear transitions reset tracks to REAPER's default color.
  local hash = 1
  for i = 0, NUM_PADS - 1 do
    local hue_x1k = math.floor(reaper.gmem_read(META_BASE + i * META_PP + 12) * 1000 + 0.5)
    local has_audio = reaper.gmem_read(AUDIOLEN_BASE + i) > 0 and 1 or 0
    hash = (hash * 31 + hue_x1k) % 0x7FFFFFFF
    hash = (hash * 31 + has_audio) % 0x7FFFFFFF
  end
  local eff_s = reaper.gmem_read(GS_COL_EFFECTIVE_S)
  local eff_l = reaper.gmem_read(GS_COL_EFFECTIVE_L)
  hash = (hash * 31 + math.floor(eff_s * 1000 + 0.5)) % 0x7FFFFFFF
  hash = (hash * 31 + math.floor(eff_l * 1000 + 0.5)) % 0x7FFFFFFF
  if hash == last_pad_color_hash then return end
  last_pad_color_hash = hash

  -- Find the active Swing track (LOCK-holder, or first found)
  local swing_track = find_swing_track()
  if not swing_track then return end

  -- Only update if multi-out tracks actually exist (i.e. user has run
  -- "Build Multi-Out Tracks" at least once).
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends < NUM_PADS then return end

  -- Saturation and lightness from gmem; fall back to legacy 0.75/0.55 if
  -- the JSFX hasn't populated the new slots yet (e.g. an older Swing
  -- instance running alongside a newer bridge). Use eff_l as the "slot
  -- initialized" sentinel since theme lightness is never 0 (themes range
  -- 0.35..0.72) — that lets eff_s legitimately be 0 when the user pulls
  -- the intensity dial all the way down (full desaturation, monochrome).
  if eff_l <= 0 then
    eff_s = 0.75
    eff_l = 0.55
  end

  -- Walk each send, map source channel pair → pad index, recolor dest track
  reaper.PreventUIRefresh(1)
  for s = 0, sends - 1 do
    local src_chan = math.floor(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
    if src_chan >= 0 and (src_chan % 2) == 0 then
      local pad = src_chan / 2
      if pad >= 0 and pad < NUM_PADS then
        local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
        if dest_tr then
          if reaper.gmem_read(AUDIOLEN_BASE + pad) > 0 then
            -- Pad has audio → apply pad color
            local hue = reaper.gmem_read(META_BASE + pad * META_PP + 12)
            local r, g, b = hsl_to_rgb(hue, eff_s, eff_l)
            local color = reaper.ColorToNative(r, g, b) | 0x1000000
            reaper.SetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR", color)
          else
            -- Empty pad → remove custom color (REAPER default)
            reaper.SetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR", 0)
          end
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
end

-- ─────────────────────────────────────────────────────────────────────────
-- SAFETY-NET FORWARD NAME SYNC (matches the color version's pattern)
-- ─────────────────────────────────────────────────────────────────────────
-- The forward name sync today fires via CMD=52 (event-driven, set by
-- JSFX sync_note_names after rename/load/drop). If any code path
-- bypasses CMD=52 (future code, edge cases, races), names go stale on
-- multi-out tracks silently. This hash-debounced poll catches every
-- pad-name change regardless of how it happened — same idea as
-- refresh_multiout_colors_if_changed (color version, line ~4609).
--
-- Cost: 16 pads × 16 chars = 256 gmem reads + 16 hash ops per ~33ms.
-- No-op early-out if hash matches last seen.

local last_pad_name_hash = 0

local function refresh_multiout_names_if_changed()
  local hash = 1
  -- Read all 16 pad-name strings from PADNAME_BASE and hash them
  for pad = 0, NUM_PADS - 1 do
    for j = 0, PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(PADNAME_BASE + pad * PADNAME_LEN + j) or 0)
      if c == 0 then break end
      hash = (hash * 31 + c) % 0x7FFFFFFF
    end
    hash = (hash * 31 + pad) % 0x7FFFFFFF  -- include pad index so reordered names trigger
  end
  if hash == last_pad_name_hash then return end
  last_pad_name_hash = hash

  -- Hash changed — walk multi-out tracks and rename to match.
  local swing_track = find_swing_track()
  if not swing_track then return end
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends < NUM_PADS then return end

  reaper.PreventUIRefresh(1)
  for s = 0, sends - 1 do
    local src_chan = math.floor(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
    if src_chan >= 0 and (src_chan % 2) == 0 then
      local pad = src_chan / 2
      if pad >= 0 and pad < NUM_PADS then
        local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
        if dest_tr then
          -- Reassemble the pad name from gmem
          local pname = ""
          for j = 0, PADNAME_LEN - 1 do
            local c = math.floor(reaper.gmem_read(PADNAME_BASE + pad * PADNAME_LEN + j) or 0)
            if c == 0 then break end
            pname = pname .. string.char(c)
          end
          if pname == "" then pname = string.format("%02d", pad + 1) end
          reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", pname, true)
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
end

-- ─────────────────────────────────────────────────────────────────────────
-- REVERSE-DIRECTION SYNC: TCP/MCP track edits → JSFX/Browser
-- ─────────────────────────────────────────────────────────────────────────
-- When the user renames or recolors a multi-out child track DIRECTLY in
-- REAPER's TCP, propagate that change back into the JSFX (and from there
-- to the browser). Forward direction (JSFX → tracks) lives in the two
-- existing refresh_multiout_*_if_changed functions; these are their
-- mirror images.
--
-- Hash-debounced like the forward versions, so when names/colors haven't
-- changed (or no multi-out tracks exist), these functions are nearly
-- free (~16 API calls per poll tick).

local last_tcp_name_hash  = 0
local last_tcp_color_hash = 0
local rgb_to_hue          = core.rgb_to_hue

local function refresh_pad_names_from_tracks_if_changed()
  -- Skip reverse sync while a command is pending — the JSFX may have
  -- written fresh pad names to gmem that CMD=52 hasn't pushed to
  -- tracks yet.  Without this guard, we'd read the stale TCP name and
  -- overwrite the fresh gmem name before the cmd dispatch runs.
  if math.floor(reaper.gmem_read(CMD) or 0) ~= 0 then return end
  local swing_track = find_swing_track()
  if not swing_track then return end
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends < NUM_PADS then return end

  -- Read each multi-out track's P_NAME and build a hash that includes
  -- both the names AND the pad indices (so swapping tracks for the same
  -- pad indices doesn't escape detection).
  local hash = 1
  local tcp_names = {}  -- [pad_idx] = name
  for s = 0, sends - 1 do
    local src_chan = math.floor(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
    if src_chan >= 0 and (src_chan % 2) == 0 then
      local pad = src_chan / 2
      if pad >= 0 and pad < NUM_PADS then
        local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
        if dest_tr then
          local _, tname = reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", "", false)
          tcp_names[pad] = tname or ""
          hash = (hash * 31 + pad) % 0x7FFFFFFF
          for i = 1, #(tname or "") do
            hash = (hash * 31 + string.byte(tname, i)) % 0x7FFFFFFF
          end
        end
      end
    end
  end
  if hash == last_tcp_name_hash then return end
  last_tcp_name_hash = hash

  -- Compare each TCP name against gmem PADNAME. If different, write the
  -- TCP name into gmem so the JSFX gmem-watcher picks it up next @gfx.
  -- Note: we DON'T write all names every change — only the ones that
  -- actually differ, to avoid clobbering names the JSFX wrote (which
  -- would trigger an oscillation).
  for pad, tname in pairs(tcp_names) do
    if tname ~= "" then
      -- Read current gmem PADNAME for this pad
      local cur = ""
      for j = 0, PADNAME_LEN - 1 do
        local c = math.floor(reaper.gmem_read(PADNAME_BASE + pad * PADNAME_LEN + j))
        if c > 0 then cur = cur .. string.char(c) else break end
      end
      -- Multi-out tracks default to "01", "02", ... when built by
      -- do_build_multiout. Skip those numeric defaults so we don't
      -- overwrite a real pad name with a placeholder track name.
      local is_default = tname:match("^%d%d$") or tname == ""
      if tname ~= cur and not is_default then
        local truncated = tname:sub(1, PADNAME_LEN)
        for j = 0, PADNAME_LEN - 1 do
          local c = j < #truncated and string.byte(truncated, j + 1) or 0
          reaper.gmem_write(PADNAME_BASE + pad * PADNAME_LEN + j, c)
        end
      end
    end
  end
end

local function refresh_pad_colors_from_tracks_if_changed()
  -- Same guard as name reverse sync — don't clobber gmem hues while a
  -- command is in flight (e.g. auto-color rebuild via CMD 63/64).
  if math.floor(reaper.gmem_read(CMD) or 0) ~= 0 then return end
  local swing_track = find_swing_track()
  if not swing_track then return end
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends < NUM_PADS then return end

  -- Hash all 16 multi-out track colors. Quantize to int (they already are).
  local hash = 1
  local tcp_colors = {}  -- [pad_idx] = raw I_CUSTOMCOLOR with flag
  for s = 0, sends - 1 do
    local src_chan = math.floor(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
    if src_chan >= 0 and (src_chan % 2) == 0 then
      local pad = src_chan / 2
      if pad >= 0 and pad < NUM_PADS then
        local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
        if dest_tr then
          local raw_color = math.floor(reaper.GetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR") or 0)
          tcp_colors[pad] = raw_color
          hash = (hash * 31 + pad) % 0x7FFFFFFF
          hash = (hash * 31 + raw_color) % 0x7FFFFFFF
        end
      end
    end
  end
  if hash == last_tcp_color_hash then return end
  last_tcp_color_hash = hash

  -- For each pad, if the TCP color is set (0x1000000 flag) AND the
  -- corresponding hue in gmem differs from what RGB→hue produces from
  -- the TCP color, write the new hue. The forward-sync function will
  -- next tick set the TCP color from hue+S/L and the hashes will
  -- converge — so a TCP rename + recolor stabilizes within one cycle.
  for pad, raw_color in pairs(tcp_colors) do
    -- 0x1000000 = "use custom color" flag. Without it, REAPER returns 0
    -- or uses default — skip those (no explicit color set by user).
    if (raw_color & 0x1000000) ~= 0 then
      local color = raw_color & 0xFFFFFF
      local r, g, b = reaper.ColorFromNative(color)
      local new_hue = rgb_to_hue(r, g, b)
      local cur_hue = reaper.gmem_read(META_BASE + pad * META_PP + 12) or 0
      -- Tolerance: 0.005 hue ~ 1.8° — below visible difference
      if math.abs(new_hue - cur_hue) > 0.005 then
        reaper.gmem_write(META_BASE + pad * META_PP + 12, new_hue)
      end
    end
  end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- AUTO-KIT-SIDECAR — bypasses REAPER chunk-size truncation for big kits
-- ═════════════════════════════════════════════════════════════════════════════
-- On project save: write a `.swing` file per Swing instance into the project
-- folder. On project open / new instance detection: auto-load that sidecar
-- via existing kit-load infrastructure. The embedded chunk continues to be
-- written (small kit fallback for "user emails .rpp alone"), but sidecars
-- always win on load if present, so big kits round-trip reliably.

local prev_proj_dirty = -1                -- IsProjectDirty value last poll (-1 = first poll)
local prev_proj_filename = ""             -- detect project switches / reopens
local primed_instances = {}               -- inst_id → true once we've checked for sidecar
local pending_load_queue = {}             -- queue of {inst_id, path} for serialized loads
local current_load = nil                  -- in-flight load: {inst_id, path, started_at} or nil
-- kit_sources is declared at file top (before load_swing_dispatch) so the
-- recording hook inside that function can see it via lexical scope. See
-- "AUTO-KIT-SIDECAR — kit_sources" further up the file.

-- Get the sidecar `.swing` path for an instance, or nil if project unsaved.
-- Format: <projectfolder>/Swing/swing_<inst>.swing
local function get_sidecar_path(inst_id)
  if not inst_id or inst_id <= 0 then return nil end
  local _, proj_filename = reaper.EnumProjects(-1)
  if not proj_filename or proj_filename == "" then return nil end
  local proj_dir = proj_filename:match("(.*[/\\])")
  if not proj_dir then return nil end
  -- Subfolder keeps multi-instance projects tidy; create on demand
  local sidecar_dir = proj_dir .. "Swing"
  reaper.RecursiveCreateDirectory(sidecar_dir, 0)
  return sidecar_dir .. sep .. "swing_" .. math.floor(inst_id) .. ".swing"
end

-- Enumerate every Swing instance on the project (track + fx + instance_id).
-- Also rehydrate kit_sources from track ExtState (P_EXT:swing_kit_src) so
-- legacy projects opened in a fresh bridge session inherit their saved
-- kit-source paths without requiring a manual reload.
local function enumerate_all_swings()
  local list = {}
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
        if inst_id > 0 then
          -- Pull persisted kit_source path from track ExtState into
          -- the in-memory table, but only if not already set this
          -- session (we trust live loads over the persisted hint).
          if not kit_sources[inst_id] then
            local _, src = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:swing_kit_src", "", false)
            if src and src ~= "" then
              kit_sources[inst_id] = src
            end
          end
          list[#list + 1] = { tr = tr, fx = fx, inst_id = inst_id }
        end
      end
    end
  end
  return list
end

-- Save sidecars by COPYING the source kit file each instance was loaded
-- from. Synchronous (file copy is fast for typical kits, even 200MB).
-- Avoids the gmem multi-window race entirely — we never read kit data
-- from gmem on save. Each instance has a recorded source path tracked
-- by record_kit_source() (called whenever a kit-load happens through
-- the bridge). If no source is recorded for an instance (fresh insert
-- with no kit, or a path we lost track of), the save is skipped — the
-- chunk's truncated fallback covers small kits, and the user can re-
-- load the kit manually to capture it for the next save.
local function file_copy(src_path, dst_path)
  if src_path == dst_path then return true end  -- self-copy = no-op
  local src = io.open(src_path, "rb")
  if not src then return false end

  -- Magic check: refuse to copy anything that doesn't look like a .swing
  -- file. Catches accidental ExtState corruption pointing at the wrong
  -- file, or someone manually tampering with track ExtState. Both v1
  -- binary (8-byte double magic 0x40d4d5d2538000... ≈ specific dword)
  -- and v4 text ("SWINGv0") share enough structure that we accept either.
  local head = src:read(8) or ""
  if head:sub(1, 8) ~= "SWINGv04" and head:sub(1, 8) ~= "SWINGv03" then
    -- Fall back: v1/v2 binary format starts with a packed double. Hard
    -- to validate cheaply, so accept any 8 bytes that aren't all zero.
    if head:byte(1) == 0 and head:byte(2) == 0 and head:byte(3) == 0
       and head:byte(4) == 0 and head:byte(5) == 0 and head:byte(6) == 0
       and head:byte(7) == 0 and head:byte(8) == 0 then
      src:close()
      return false  -- looks like an empty/zeroed file, not a real kit
    end
  end
  src:seek("set", 0)

  local dst = io.open(dst_path, "wb")
  if not dst then src:close(); return false end

  -- Chunked copy (4MB blocks) so large kits (200MB+) don't pin the
  -- entire file into Lua string memory at once. Synchronous within the
  -- defer cycle, but doesn't balloon RAM use proportionally to kit size.
  local CHUNK = 4 * 1024 * 1024
  local ok = true
  while true do
    local chunk = src:read(CHUNK)
    if not chunk or #chunk == 0 then break end
    if not dst:write(chunk) then ok = false; break end
  end
  src:close()
  dst:close()
  return ok
end

local function auto_save_all_sidecars()
  local _, proj_filename = reaper.EnumProjects(-1)
  if not proj_filename or proj_filename == "" then return end
  local swings = enumerate_all_swings()
  for _, swing in ipairs(swings) do
    local source_path = kit_sources[swing.inst_id]
    local dest_path = get_sidecar_path(swing.inst_id)
    if source_path and dest_path then
      file_copy(source_path, dest_path)
    end
  end
end

-- Queue a sidecar load for a freshly-detected instance. Tries (in order):
--   1. Project-folder sidecar (<projectpath>/Swing/swing_<inst>.swing)
--   2. Track ExtState (P_EXT:swing_kit_src) — last-seen kit path
--   3. Default 808_v2.swing — for fresh insertions on tracks with no kit
-- Silently skips if all three miss (e.g., fresh insert when 808_v2.swing is
-- also missing — user should never see that, but bridge stays sane).
--
-- Bridge-side 808 fallback exists because the JSFX-side auto-load 808
-- gating (`gmem[LOCK] == 0 && gmem[CMD] == 0 && bridge alive`) can fail
-- silently — if any condition is briefly false during JSFX init, the
-- _auto_load_attempted flag flips to 1 and the JSFX never retries. The
-- bridge has no such gating: if it sees an instance with no kit, it
-- pushes 808 directly via the same kit-load pipeline.
local function queue_sidecar_load_if_present(swing)
  -- "Hit" requires both: file exists AND has at least minimal valid kit
  -- structure (>= 16 bytes — magic 8 + lua_len 8 for v4, or magic
  -- double + format ver double for v1). 0-byte and tiny corrupted
  -- sidecars would otherwise pass the existence probe and then crash
  -- load_kit_v* with a dialog. Rejecting them here lets us fall
  -- through to Path 2/3.
  local function probe(path)
    if not path or path == "" then return false end
    local f = io.open(path, "rb"); if not f then return false end
    local size = f:seek("end") or 0
    f:close()
    return size >= 16
  end
  local p1 = get_sidecar_path(swing.inst_id)
  local p1_hit = probe(p1)
  local _, p2 = reaper.GetSetMediaTrackInfo_String(swing.tr, "P_EXT:swing_kit_src", "", false)
  local p2_hit = probe(p2)
  local p3 = get_kits_dir() .. sep .. "808_v2.swing"
  local p3_hit = probe(p3)

  -- Path 1: project-folder sidecar
  if p1_hit then
    pending_load_queue[#pending_load_queue + 1] = { inst_id = swing.inst_id, tr = swing.tr, fx = swing.fx, path = p1 }
    return
  end

  -- Path 2: track ExtState (set by previous load_swing_dispatch)
  if p2_hit then
    pending_load_queue[#pending_load_queue + 1] = { inst_id = swing.inst_id, tr = swing.tr, fx = swing.fx, path = p2 }
    return
  end

  -- Path 3: DISABLED — was loading 808_v2.swing as fallback for fresh inserts,
  -- but this clobbers kits that the JSFX already deserialized from the project
  -- chunk (e.g. Choppa-applied slices that bypass the bridge). The JSFX-side
  -- auto-load (_auto_load_attempted flag in @block) already handles truly fresh
  -- instances via CMD=22, so this bridge-side fallback is redundant and harmful.
  -- if p3_hit then
  --   pending_load_queue[#pending_load_queue + 1] = { inst_id = swing.inst_id, tr = swing.tr, fx = swing.fx, path = p3 }
  -- end
end

-- Drive the load queue: pop one item at a time, wait for completion before
-- starting the next. Completion = CMD has changed away from 3 (the
-- "load in flight" sentinel load_kit_v* writes during the pop). Possible
-- post-load CMD values we treat as "done":
--   0  → JSFX state-machine completed successfully (rk_swing_ui_state
--        .jsfx-inc:604 sets CMD=0 at end of state 4)
--   52 → JSFX state 4's tail call to sync_note_names() ran in the same
--        @gfx tick — it grabs the lock and writes 52 to ask the bridge
--        to sync pad names to the piano roll. CMD goes 3→0→52 fast
--        enough that the bridge often catches it at 52. Either snapshot
--        means the kit is loaded.
--   98 → bridge wrote it on validation/format failure (load_kit_v*
--        error paths) — JSFX may clear it back to 0 on its side, either
--        observation means done
--   99 → legacy non-import completion ack (multi-out builder, etc.)
-- Plus a 30s timeout for genuinely stuck loads. Prevents multi-instance
-- gmem corruption from overlapping loads.
local function drive_load_queue()
  if current_load then
    local cmd_val = math.floor(reaper.gmem_read(CMD))
    local done = false
    local timed_out = false
    if cmd_val ~= 3 then
      done = true
    elseif (os.time() - current_load.started_at) > 30 then
      -- Stuck — abandon and continue. JSFX state may be partial but we
      -- don't want to block the rest of the bridge forever.
      done = true
      timed_out = true
    end
    if done then
      -- LOCK release strategy:
      --   - On success (cmd_val != 3 and not timed_out): JSFX state 4
      --     already cleared LOCK to 0, but immediately afterward
      --     sync_note_names() reacquired it (LOCK = instance_id) so
      --     it can write CMD=52 + the new pad names for the bridge's
      --     cmd 52 handler to push to the piano roll. If we cleared
      --     LOCK here, find_swing_track() inside the cmd 52 handler
      --     would see LOCK=0 and return the FIRST Swing track instead
      --     of ours — multi-instance reopens would write every
      --     instance's pad names onto the first instance's track.
      --     Leave LOCK alone; the idle stale-LOCK self-heal in
      --     poll_sidecar_events catches anything left over after
      --     CMD goes back to 0.
      --   - On timeout: state 4 never ran, so LOCK is still pinned
      --     to our inst_id from when we wrote it at pop time. Clear
      --     it defensively so a future fresh-insert auto-load (which
      --     gates on LOCK==0) isn't blocked by our orphan.
      if timed_out then
        local lock_now = math.floor(reaper.gmem_read(LOCK) or 0)
        if lock_now == current_load.inst_id then
          reaper.gmem_write(LOCK, 0)
        end
      end
      current_load = nil
    else
      return  -- still in flight, wait
    end
  end
  if not current_load and #pending_load_queue > 0 then
    -- Gate the pop on CMD == 0 so any JSFX-initiated command in flight
    -- gets a chance to be processed by the main poll's cmd dispatch
    -- (which runs AFTER us this same tick). Concrete case: at the end
    -- of a successful kit-import, the JSFX writes CMD=0 then immediately
    -- CMD=52 (sync_note_names tail call in rk_swing_ui_state.jsfx-inc
    -- :609). Without this gate, drive_load_queue clears current_load
    -- on the CMD=52 snapshot, pops the next item, calls load_kit_v* which
    -- writes CMD=3 — overwriting the 52 before the bridge's cmd 52
    -- handler (piano-roll name sync) ever runs. Same risk for any other
    -- JSFX-driven command (CMD=22 auto-load, CMD=99 ack, etc.) that
    -- happens to land in the gap between our done-detection and pop.
    --
    -- Cost: at most one extra poll tick (~33ms) of latency between
    -- successive queued loads. Imperceptible to the user, and only
    -- relevant on bulk-reopen where loads pipeline back-to-back.
    local cmd_now = math.floor(reaper.gmem_read(CMD) or 0)
    if cmd_now ~= 0 then return end
    local item = table.remove(pending_load_queue, 1)
    current_load = { inst_id = item.inst_id, tr = item.tr, fx = item.fx, path = item.path, started_at = os.time() }
    reaper.gmem_write(LOCK, item.inst_id)
    -- Track this path as the source for this instance, so subsequent
    -- project saves copy the right file (sidecar → sidecar = no-op,
    -- which is correct for already-saved projects).
    kit_sources[item.inst_id] = item.path
    -- Pre-set the per-instance routing slot so load_swing_dispatch's
    -- source-tracking fallback (lock → pending → instance) and, more
    -- importantly, the JSFX-side @gfx delivery gate
    --   GS_KIT_LOAD_REQ == 2 && PENDING_LOAD_INST == instance_id
    -- can both target this instance specifically.
    reaper.gmem_write(G.GS_PENDING_LOAD_INST, item.inst_id)
    -- Note: the kit-import gate + state machine now run in JSFX @block
    -- (see Swing_ReaKit.jsfx, just before @sample). No need to
    -- force-open the FX window for @gfx — @block runs whenever the FX
    -- is on a track, regardless of UI visibility.
    load_swing_dispatch(item.path)
    -- Trigger the JSFX-side import gate. load_kit_v4 has just written
    -- CMD=3 + meta + audio; without GS_KIT_LOAD_REQ=2 the JSFX never
    -- enters kit_import_state=1, so the data sits in gmem unconsumed.
    -- This mirrors the JSFX-driven CMD 22 path (which sets KIT_LOAD_REQ
    -- =2 in the kit_req==1 poll branch) — without it, the bridge-side
    -- 808 fallback never actually delivers, and fresh-insert auto-load
    -- silently fails. Only signal "data ready" if load_kit_v* actually
    -- wrote CMD=3; on validation/format failure CMD is 98 and we leave
    -- it alone so the JSFX-side error path runs.
    local post_cmd = math.floor(reaper.gmem_read(CMD) or 0)
    if post_cmd == 3 then
      reaper.gmem_write(GS_KIT_LOAD_REQ, 2)
    else
      -- Load failed before reaching CMD=3 — clear PENDING so a future
      -- successful load isn't mis-routed to a stale inst_id.
      reaper.gmem_write(G.GS_PENDING_LOAD_INST, 0)
    end
  end
end

-- Detect "project just saved" via IsProjectDirty 1→0 transition.
-- Detect "new instance appeared this session" via primed_instances table.
-- Detect "project switched/reopened OR Save As" via filename change.
local function poll_sidecar_events()
  -- Project change detection — clear primed table on switch/reopen.
  -- Save As also lands here (filename changes from old to new). When
  -- the change is between two real projects (not blank → blank), treat
  -- it as an implicit save event so sidecars get written to the new
  -- path. Without this, Save As would never trigger sidecar write —
  -- the IsProjectDirty 1→0 transition gets consumed by the rename.
  local _, cur_proj_filename = reaper.EnumProjects(-1)
  cur_proj_filename = cur_proj_filename or ""
  if cur_proj_filename ~= prev_proj_filename then
    primed_instances = {}
    pending_load_queue = {}
    local was_save_as = (prev_proj_filename ~= "" and cur_proj_filename ~= "")
    prev_proj_filename = cur_proj_filename
    prev_proj_dirty = -1
    if was_save_as then
      auto_save_all_sidecars()
    end
  end

  -- Save trigger — IsProjectDirty(0) returns >0=dirty, 0=clean
  local dirty = reaper.IsProjectDirty(0) or 0
  if prev_proj_dirty > 0 and dirty == 0 then
    auto_save_all_sidecars()
  end
  prev_proj_dirty = dirty

  -- Load trigger — check every Swing instance once per session, queue any
  -- that have a sidecar file waiting in the project folder.
  local swings = enumerate_all_swings()
  for _, swing in ipairs(swings) do
    if not primed_instances[swing.inst_id] then
      primed_instances[swing.inst_id] = true
      queue_sidecar_load_if_present(swing)
    end
  end

  -- ── Audio-repair trigger ────────────────────────────────────────────
  -- JSFX writes GS_AUDIO_REPAIR_REQ = its instance_id when it detects
  -- chunk-truncated audio after a deserialize (Undo, Redo, project
  -- chunk restore). The detector is in @serialize is_read tail (see
  -- Swing_ReaKit.jsfx) — it probes 3 positions per pad and flags if
  -- the buffer reads as zeroed despite metadata claiming s_len > 100.
  --
  -- Repair = re-run Path B for that one instance only: find its
  -- tr/fx, queue queue_sidecar_load_if_present for it (which falls
  -- through project-sidecar → track-ExtState → 808 default if needed),
  -- and let drive_load_queue dispatch it the next tick.
  --
  -- LIMITATION: the sidecar reflects whatever was on disk at the LAST
  -- project save. If the user changed kits between saves and then
  -- triggered an Undo-style repair, the audio may not match the
  -- restored metadata. Acceptable trade-off vs. the alternative
  -- (silent blank pads). Documented in CLAUDE.md / project docs.
  local repair_inst = math.floor(reaper.gmem_read(G.GS_AUDIO_REPAIR_REQ) or 0)
  if repair_inst > 0 then
    -- Consume the request immediately so the JSFX doesn't keep re-
    -- writing it every poll (it's set by @serialize, not @block, so
    -- it only fires once per chunk restore — but defensive clear
    -- still right thing to do)
    reaper.gmem_write(G.GS_AUDIO_REPAIR_REQ, 0)
    -- Re-prime this instance so queue_sidecar_load_if_present is
    -- willing to fire for it (primed_instances guards re-load).
    primed_instances[repair_inst] = nil
    -- Locate the swing for this inst_id and queue it
    local repair_swing
    for _, swing in ipairs(swings) do
      if swing.inst_id == repair_inst then
        repair_swing = swing
        break
      end
    end
    if repair_swing then
      -- TEMP: console log so we can see when repair triggers in
      -- testing. Strip after we're confident it works in practice.
      reaper.ShowConsoleMsg(string.format(
        "[Swing] audio repair: chunk-truncated kit detected on inst=%d → reloading from sidecar/808\n",
        repair_inst
      ))
      primed_instances[repair_inst] = true
      queue_sidecar_load_if_present(repair_swing)
    end
  end

  -- Process the load queue (one at a time, waiting for JSFX completion).
  -- Save is now synchronous (file copy in auto_save_all_sidecars), no
  -- queue needed.
  drive_load_queue()

  -- Stale LOCK detection. The bridge's general CMD-completion auto-
  -- release (in the main poll, after the cmd dispatch) only fires when
  -- CMD transitions to 0/98/99. If something orphans LOCK without
  -- changing CMD (e.g., a kit-import that errors silently in the
  -- middle, or a previous bridge session leaving stale state), LOCK
  -- stays pinned forever. The JSFX-side auto-load 808 gates on
  -- `gmem[LOCK] == 0`, so this stuck state means fresh Swing inserts
  -- never auto-load. When everything is genuinely idle (no in-flight
  -- load, no pending queue, no CMD), it's safe to clear LOCK.
  if not current_load and #pending_load_queue == 0 then
    local cmd_now  = math.floor(reaper.gmem_read(CMD) or 0)
    local lock_now = math.floor(reaper.gmem_read(LOCK) or 0)
    if cmd_now == 0 and lock_now ~= 0 then
      reaper.gmem_write(LOCK, 0)
    end
  end
end

local function poll()
  -- EON Loader protocol v1 — file-based external sample loader
  loader_poll()

  -- Auto-kit-sidecar — save/load per-instance .swing files in project folder
  -- so big kits survive REAPER's chunk-size truncation.
  poll_sidecar_events()

  -- Real-time pad-color → multi-out track sync (cheap; no-op when colors
  -- haven't changed or no multi-out tracks exist)
  refresh_multiout_colors_if_changed()

  -- Safety-net pad-name sync (forward direction). Today's name sync runs
  -- via CMD=52 event-driven; this hash-debounced poll catches any name
  -- change regardless of code path — defends against future bugs.
  refresh_multiout_names_if_changed()

  -- Reverse direction: TCP/MCP rename/recolor → JSFX/Browser.
  -- Both hash-debounced. The forward and reverse functions converge to
  -- a stable state within one or two poll ticks because both directions
  -- agree on the same representation (hue for color, char[] for name).
  refresh_pad_names_from_tracks_if_changed()
  refresh_pad_colors_from_tracks_if_changed()

  -- Pad-click → MCP/TCP track select (gated in JSFX by
  -- pad_click_selects_track preference). JSFX writes 1-indexed pad to
  -- GS_PAD_TRACK_SELECT; bridge resolves the multi-out child track via
  -- the existing send-walk pattern (same as CMD=50 rename auto-update)
  -- and exclusively-selects it. Slot reset to 0 to consume the request.
  do
    local req = math.floor(reaper.gmem_read(G.GS_PAD_TRACK_SELECT) or 0)
    if req > 0 and req <= NUM_PADS then
      local pad_idx = req - 1
      local sw_tr = find_swing_track()
      if sw_tr then
        local num_sends = reaper.GetTrackNumSends(sw_tr, 0)
        local found = false
        for si = 0, num_sends - 1 do
          local src_chan = reaper.GetTrackSendInfo_Value(sw_tr, 0, si, "I_SRCCHAN")
          if math.floor(src_chan) == pad_idx * 2 then
            local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(sw_tr, 0, si, 1)
            if dest_tr then
              reaper.SetOnlyTrackSelected(dest_tr)
              reaper.Main_OnCommand(40913, 0)  -- Track: Vertical scroll selected tracks into view
              found = true
            end
            break
          end
        end
        -- silent no-op if no multi-out track exists for this pad
      end
      reaper.gmem_write(G.GS_PAD_TRACK_SELECT, 0)  -- consume request
    end
  end


  -- Browser-initiated kit load (dedicated flag, avoids CMD race with @gfx)
  local kit_req = math.floor(reaper.gmem_read(GS_KIT_LOAD_REQ))
  if kit_req == 1 then
    reaper.gmem_write(GS_KIT_LOAD_REQ, 0)  -- clear request
    local direct_path = reaper.GetExtState("Swing", "kit_load_path")
    if direct_path and direct_path ~= "" then
      reaper.SetExtState("Swing", "kit_load_path", "", false)
      -- Wrap in undo block so the load shows up as a named entry in
      -- REAPER's undo list with the kit name. Caveat: the chunk diff
      -- captures metadata (slider values, pad paths, kit name) but NOT
      -- the audio buffers (those live in @init freemem, outside the
      -- chunk). After Ctrl+Z on a kit load, pad metadata reverts to the
      -- previous kit, but pads play silent until the user re-loads. A
      -- proper redo-via-reload state machine would fix this; for now
      -- the named undo entry is at least correct in the list.
      local kit_name = direct_path:match("([^/\\]+)%.swing$")
                    or direct_path:match("([^/\\]+)$")
                    or "kit"
      reaper.Undo_BeginBlock()
      load_swing_dispatch(direct_path)
      reaper.Undo_EndBlock("Swing: Load Kit " .. kit_name, -1)
      -- Signal JSFX: kit data is now in gmem, enter import state machine
      reaper.gmem_write(GS_KIT_LOAD_REQ, 2)  -- 2 = data ready
    end
  end

  local cmd = math.floor(reaper.gmem_read(CMD))

  -- Kit ops
  if cmd == 10 then
    do_export_name_prompt()
  elseif cmd == 15 then
    do_export_browse()
  elseif cmd == 1 then
    do_export_write_file()
  elseif cmd == 2 then
    do_import()
  elseif cmd == 16 then
    do_import_browse()

  -- SFZ kit import (LOAD right-click "Import SFZ Kit..." menu item).
  -- File dialog → ExtState → CMD 60 (open browser, which reads ExtState
  -- and runs import_start). Same pipeline as EON_SB_ImportKit.lua but
  -- triggered from inside the JSFX, so the user doesn't have to hunt
  -- for the standalone action.
  elseif cmd == 17 then
    local retval, filename = reaper.GetUserFileNameForRead(
      "", "Import SFZ Kit", "sfz"
    )
    if retval and filename ~= "" then
      reaper.SetExtState("Swing", "import_file", filename, false)
      reaper.gmem_write(CMD, 60)  -- delegate to "open browser" handler next tick
    else
      reaper.gmem_write(CMD, 0)   -- user cancelled
    end

  -- Auto-load default 808 kit on fresh JSFX instance creation.
  -- JSFX fires this once (tracked via _auto_load_attempted in @serialize)
  -- when the bridge first becomes available. Uses get_kits_dir() so the
  -- resolution matches every other kit-load code path (browser kit menu,
  -- file dialog, drag-drop). On Windows that resolves to
  --   %APPDATA%\REAPER\Data\Swing_Kits\808_v2.swing
  -- on Mac to
  --   ~/Library/Application Support/REAPER/Data/Swing_Kits/808_v2.swing
  -- and on Linux to
  --   ~/.config/REAPER/Data/Swing_Kits/808_v2.swing
  -- — exactly where each platform's installer drops the bundled kits. For
  -- portable REAPER installs it follows the portable resource path.
  -- get_kits_dir() also calls RecursiveCreateDirectory so a fresh install
  -- with no kit data yet still resolves cleanly (the open below just won't
  -- find the file and the auto-load no-ops without erroring).
  elseif cmd == 22 then
    local kit_path = get_kits_dir() .. sep .. "808_v2.swing"
    local f = io.open(kit_path, "rb")
    if f then
      f:close()
      reaper.SetExtState("Swing", "kit_load_path", kit_path, false)
      reaper.gmem_write(GS_KIT_LOAD_REQ, 1)
      local req_tr, req_fx = find_swing_track()
      if req_tr and req_fx then
        -- Only force the window open if it's currently closed. If the
        -- user already had Swing floating, TrackFX_SetOpen would yank
        -- it back into the FX chain window — don't touch it.
        if not reaper.TrackFX_GetOpen(req_tr, req_fx)
           and reaper.TrackFX_GetFloatingWindow(req_tr, req_fx) == nil then
          reaper.TrackFX_Show(req_tr, req_fx, 3)  -- 3 = show in floating window
        end
      end
    end
    reaper.gmem_write(CMD, 0)

  -- Drag-drop import (kit-format file dropped on the pad grid).
  -- JSFX wrote the path to GS_BROWSER_PATH chars + GS_BROWSER_PATH_LEN.
  -- Same downstream as CMD 17: ExtState + open browser.
  elseif cmd == 18 then
    local path_len = math.floor(reaper.gmem_read(G.GS_BROWSER_PATH_LEN))
    if path_len > 0 and path_len < G.GS_BROWSER_PATH_MAX then
      local chars = {}
      for i = 0, path_len - 1 do
        chars[i + 1] = string.char(math.floor(reaper.gmem_read(G.GS_BROWSER_PATH + i)))
      end
      local filename = table.concat(chars)
      reaper.SetExtState("Swing", "import_file", filename, false)
      reaper.gmem_write(CMD, 60)
    else
      reaper.gmem_write(CMD, 0)
    end

  -- Sample ops
  elseif cmd == 20 then
    do_batch_import()
  elseif cmd == 23 then
    do_auto_color()

  -- Arrangement ops
  elseif cmd == 30 then
    do_chop_to_pads()

  -- Routing ops
  elseif cmd == 40 then
    do_build_multiout()

  -- UI ops
  elseif cmd == 45 then
    reaper.Main_OnCommand(50124, 0)   -- toggle Media Explorer
    reaper.gmem_write(CMD, 0)

  -- Browser ops (v5)
  elseif cmd == 60 then
    -- Toggle Swing Browser — open if closed, close if open
    -- Note: only one browser can run at a time (shared gmem namespace)
    local browser_running = reaper.GetExtState("Swing", "browser_running")
    local browser_gmem = reaper.gmem_read(GS_BROWSER_OPEN)
    -- If ExtState says running but gmem says not, browser crashed — clear stale state
    if browser_running == "1" and browser_gmem == 0 then
      reaper.SetExtState("Swing", "browser_running", "0", false)
      browser_running = "0"
    end
    if browser_running == "1" and reaper.gmem_read(GS_BROWSER_VISIBLE) == 1 then
      -- Visible → close (toggle off)
      reaper.SetExtState("Swing", "browser_close", "1", false)
    else
      -- Not running, or running but hidden (docked) → close stale + (re)launch
      if browser_running == "1" then
        reaper.SetExtState("Swing", "browser_close", "1", false)
      end
      local info = debug.getinfo(1, "S")
      local script_path = info.source:match("@?(.*)")
      local script_dir = script_path:match("^(.*)[/\\]") or ""
      local browser_path = script_dir .. sep .. "Swing_Browser.lua"
      local f = io.open(browser_path, "r")
      if f then
        f:close()
        local cmd_id = reaper.AddRemoveReaScript(true, 0, browser_path, true)
        if cmd_id > 0 then
          reaper.Main_OnCommand(cmd_id, 0)
          reaper.AddRemoveReaScript(false, 0, browser_path, true)
        end
      end
    end
    reaper.gmem_write(CMD, 0)

  elseif cmd == 61 then
    -- Sample assigned from browser — load audio from file path into gmem
    local pad_idx = math.floor(reaper.gmem_read(PARAM1))
    -- Bad pad_idx must NOT bare-`return` here: poll() is defer-driven and a
    -- raw return kills the entire poll loop until script restart. `goto
    -- cmd_done` skips to the lock-release/heartbeat/defer tail at the end
    -- of the function so the loop keeps running.
    if pad_idx < 0 or pad_idx >= NUM_PADS then reaper.gmem_write(CMD, 0); goto cmd_done end
    local filepath = reaper.GetExtState("Swing", "browser_sample_path")
    if filepath and filepath ~= "" and load_audio_to_pad(filepath, pad_idx) then
      reaper.gmem_write(PARAM1, pad_idx)
      reaper.gmem_write(CMD, 3)  -- tell JSFX: import data ready
    else
      reaper.gmem_write(CMD, 98)  -- signal failure
    end

  elseif cmd == 62 then
    -- Close browser
    reaper.SetExtState("Swing", "browser_close", "1", false)
    reaper.gmem_write(CMD, 0)

  -- ─── Header-bar UNDO / REDO buttons (CMD 80 / 81) ──────────────────────
  -- JSFX writes CMD 80 (or 81) when user clicks the header undo/redo
  -- button. Bridge calls REAPER's native undo/redo, which restores the
  -- FX chunk via its own mechanism (independent of the CMD 46/48
  -- protocol used for descriptive begin/end blocks).
  elseif cmd == 80 then
    reaper.Main_OnCommand(40029, 0)  -- Edit: Undo
    reaper.gmem_write(CMD, 0)

  elseif cmd == 81 then
    reaper.Main_OnCommand(40030, 0)  -- Edit: Redo
    reaper.gmem_write(CMD, 0)

  -- Undo support — Phase 1: open undo block, signal JSFX to execute action.
  -- Pushes onto the stack so nested begin/end pairs (e.g. two Swing
  -- instances issuing CMD 46 between bridge polls) don't cross-label.
  elseif cmd == 46 then
    local desc_id = math.floor(reaper.gmem_read(UNDO_DESC))
    local desc = "Swing: parameter change"
    if desc_id == 1 then desc = "Swing: Clear All Pads"
    elseif desc_id == 2 then desc = "Swing: Clear Pad"
    elseif desc_id == 3 then desc = "Swing: Load Sample"
    elseif desc_id == 4 then desc = "Swing: Load Kit"
    elseif desc_id == 5 then desc = "Swing: Swap Pads"
    elseif desc_id == 6 then desc = "Swing: New Kit"
    elseif desc_id == 7 then desc = "Swing: Clear Layer"
    end
    table.insert(pending_undo_descs, desc)
    table.insert(undo_block_times, os.time())
    reaper.Undo_BeginBlock()
    reaper.gmem_write(UNDO_ACK, 1)        -- tell JSFX: undo block is open
    reaper.gmem_write(UNDO_DESC, 0)
    reaper.gmem_write(CMD, 0)

  -- Undo support — Phase 2: JSFX finished action, close undo block.
  -- Pops the matching description from the stack (LIFO matches REAPER's
  -- begin/end nesting).
  elseif cmd == 48 then
    local desc = table.remove(pending_undo_descs) or "Swing: parameter change"
    table.remove(undo_block_times)
    reaper.Undo_EndBlock(desc, -1)
    reaper.gmem_write(UNDO_ACK, #pending_undo_descs > 0 and 1 or 0)
    reaper.gmem_write(CMD, 0)
    sync_names_and_tracks(find_swing_track())

  -- Pad naming
  elseif cmd == 50 then
    -- Rename pad via REAPER's native text input dialog
    local pad_idx = math.floor(reaper.gmem_read(PARAM1))
    -- See cmd 61 note: `goto cmd_done` instead of bare `return` so a bad
    -- pad_idx doesn't kill the defer-driven poll loop.
    if pad_idx < 0 or pad_idx >= NUM_PADS then reaper.gmem_write(CMD, 0); goto cmd_done end
    -- Read current name from gmem PADNAME area
    local cur_name = ""
    for j = 0, PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(PADNAME_BASE + pad_idx * PADNAME_LEN + j))
      if c > 0 then cur_name = cur_name .. string.char(c) end
    end
    local retval, new_name = reaper.GetUserInputs(
      string.format("Rename Pad %d", pad_idx + 1), 1,
      "Pad Name (max 16 chars):,extrawidth=160",
      cur_name
    )
    if retval and new_name ~= nil then
      -- Trim to PADNAME_LEN chars and write back to gmem PADNAME area
      new_name = new_name:sub(1, PADNAME_LEN)
      for j = 0, PADNAME_LEN - 1 do
        local c = j < #new_name and string.byte(new_name, j + 1) or 0
        reaper.gmem_write(PADNAME_BASE + pad_idx * PADNAME_LEN + j, c)
      end
      reaper.gmem_write(PARAM1, pad_idx)
      reaper.gmem_write(CMD, 51)  -- signal JSFX: name ready

      -- Auto-update multi-out track name if it exists
      local sw_tr = find_swing_track()
      if sw_tr then
        local num_sends = reaper.GetTrackNumSends(sw_tr, 0)
        for si = 0, num_sends - 1 do
          local src_chan = reaper.GetTrackSendInfo_Value(sw_tr, 0, si, "I_SRCCHAN")
          if math.floor(src_chan) == pad_idx * 2 then
            local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(sw_tr, 0, si, 1)
            if dest_tr then
              local tname
              if new_name ~= "" then
                tname = new_name
              else
                tname = string.format("%02d", pad_idx + 1)
              end
              reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", tname, true)
            end
            break
          end
        end
      end
    else
      reaper.gmem_write(CMD, 0)   -- cancelled
    end

  -- Sync MIDI note names to REAPER piano roll + multi-out child track names
  elseif cmd == 52 then
    sync_names_and_tracks(find_swing_track())
    reaper.gmem_write(CMD, 0)

  end

  -- Skip target for `goto cmd_done` from inside cmd handlers that need to
  -- bail early without killing the defer poll loop. Falls through to the
  -- lock-release / undo-leak / heartbeat / defer tail below.
  ::cmd_done::

  -- Release instance lock for commands that fully complete in the bridge.
  -- Commands that write CMD=3 (data transfer) keep the lock held;
  -- the JSFX releases it once it finishes reading.
  if cmd > 0 then
    local final = math.floor(reaper.gmem_read(CMD))
    if final == 0 or final == 98 or final == 99 then
      reaper.gmem_write(LOCK, 0)
    end
  end

  -- Undo block leak protection: close orphaned undo blocks after 10 seconds.
  -- Walks the stack from the bottom (oldest) and closes each block whose
  -- timestamp has aged out. Uses the matching description from the desc
  -- stack for each one so the labels stay aligned.
  while #undo_block_times > 0 and (os.time() - undo_block_times[1]) > 10 do
    local desc = table.remove(pending_undo_descs, 1) or "Swing: parameter change (timeout)"
    table.remove(undo_block_times, 1)
    reaper.Undo_EndBlock(desc .. " (timeout)", -1)
  end
  if #pending_undo_descs == 0 then
    reaper.gmem_write(UNDO_ACK, 0)
  end

  -- Heartbeat + periodic 32-channel check + track number
  heartbeat_counter = heartbeat_counter + 1
  if heartbeat_counter >= 30 then
    reaper.gmem_write(BRIDGE_ALIVE, os.time())
    -- Write track number for browser title
    local sw_tr = find_swing_track()
    if sw_tr then
      reaper.gmem_write(GS_TRACK_NUM, math.floor(reaper.GetMediaTrackInfo_Value(sw_tr, "IP_TRACKNUMBER")))
    end
    ensure_32ch()
    heartbeat_counter = 0
  end

  -- Publish Media Explorer toggle state every tick so the JSFX EXPLORE button
  -- recolors instantly when the user opens/closes it (action 50124).
  reaper.gmem_write(GS_MEDIA_EXPLORER_OPEN, reaper.GetToggleCommandState(50124) == 1 and 1 or 0)

  -- ─── Publish undo/redo state for header buttons ──────────────────────
  -- Throttle to every 6 polls (~5Hz). Tooltip latency is fine at that
  -- rate; reading 2 strings + 2 booleans per poll is overhead we don't
  -- need to pay 30 times a second.
  if (heartbeat_counter % 6) == 0 then
    -- Undo_CanUndo2/CanRedo2 return the next-action description string
    -- (e.g. "FX: Swing parameter change") or nil if the stack is empty.
    local undo_desc = reaper.Undo_CanUndo2(0)
    local redo_desc = reaper.Undo_CanRedo2(0)
    reaper.gmem_write(G.GS_UNDO_AVAIL, (undo_desc ~= nil) and 1 or 0)
    reaper.gmem_write(G.GS_REDO_AVAIL, (redo_desc ~= nil) and 1 or 0)
    -- Write description strings (truncate to 127 chars + null terminator)
    local function write_str(base, max_len, s)
      s = s or ""
      local n = math.min(#s, max_len - 1)
      for i = 0, n - 1 do
        reaper.gmem_write(base + i, s:byte(i + 1))
      end
      reaper.gmem_write(base + n, 0)  -- null terminator
    end
    write_str(G.GS_UNDO_DESC, G.GS_UNDO_DESC_LEN, undo_desc)
    write_str(G.GS_REDO_DESC, G.GS_REDO_DESC_LEN, redo_desc)
  end

  reaper.defer(poll)
end

reaper.defer(poll)
reaper.atexit(function()
  reaper.gmem_write(BRIDGE_ALIVE, 0)
end)
