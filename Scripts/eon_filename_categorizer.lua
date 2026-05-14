-- eon_filename_categorizer.lua
-- Filename → drum/instrument category classifier.
--
-- Originally adapted from TouristKiller's tk_filename_categorizer.lua
-- (TK Media Browser). Used here under the same permissive intent — drop-in
-- pure-Lua module with no DAW coupling, no DSP, just keyword matching.
--
-- Usage:
--   local cat = categorizer.classify(filename, optional_folder_path)
--   local color = categorizer.get_category_color(cat)  -- 0xRRGGBBAA u32
--
-- Returns "other" + matched=false when no keyword fires. Folder name
-- contributes a smaller weight than filename so a "Kicks" folder bias
-- is preserved without overriding an explicit "snare.wav" inside it.

local categorizer = {}

local CATEGORY_KEYWORDS = {
    kick = {
        "kick", "kck", "kik", "kk", "bd", "bassdrum", "bass_drum", "bass drum",
        -- Compound 808/909 patterns only — bare "808" matched every TR-808
        -- file (claps, congas, cowbells, toms, rimshots) and pulled them
        -- all into kick by tie-break order. These compounds only fire
        -- when the filename actually says it's a kick from that drum
        -- machine.
        "808kick", "808 kick", "808bd", "909kick", "909bd", "909 kick"
    },
    snare = {
        "snare", "snr", "sd", "clap snare",
        "909snare", "909snr", "909 snare"
        -- "sn" removed — too short, false-matched any filename with
        -- "sn" anywhere ("kick basin", "lessons", etc.). "snare" / "snr"
        -- catch the real cases.
    },
    clap = {
        "clap", "clp", "handclap", "hand_clap", "hand clap"
    },
    rimshot = {
        "rimshot", "rim shot", "rim_shot", "rim"
    },
    -- Hi-hat family split into three categories. CATEGORY_ORDER places
    -- specific (closed_hat, open_hat) BEFORE generic (hihat) so a name
    -- that contains "closed hat" wins over the "hat" generic match.
    closed_hat = {
        "closed hat", "closedhat", "closed_hat", "hat closed", "hat_closed",
        "closed",  -- bare "closed" — unambiguous in sample-name context
        "pedal hat", "pedalhat", "ch"  -- "ch" via frontier pattern (≤3 chars)
    },
    open_hat = {
        "open hat", "openhat", "open_hat", "hat open", "hat_open",
        "oh"  -- "oh" via frontier pattern (≤3 chars)
    },
    hihat = {
        -- Generic / unspecified hi-hat — name doesn't say open or closed.
        "hihat", "hi hat", "hi_hat", "hh", "hat"
    },
    cymbal = {
        "cymbal", "cym", "splash", "china"
    },
    ride = {
        "ride"
    },
    crash = {
        "crash", "crsh"
    },
    tom = {
        "tom", "toms", "floor tom", "rack tom", "hi tom", "lo tom",
        "mid tom", "high tom", "low tom"
    },
    -- Hand drums broken out so TR-808 / Latin kits get accurate filtering.
    -- Each takes priority over the generic "percussion" catch-all because
    -- the exact match scores 2 for the specific category vs 0 for percussion.
    conga = {
        "conga", "congas"
    },
    bongo = {
        "bongo", "bongos"
    },
    cowbell = {
        "cowbell", "cow bell"
    },
    clave = {
        "clave", "claves"
    },
    tambourine = {
        "tambourine", "tamb", "tambou"
    },
    shaker = {
        "shaker", "shakers", "shake"
    },
    maraca = {
        "maraca", "maracas", "marcas"  -- "marcas" handles the TR-808 typo
    },
    percussion = {
        "perc", "percussion", "triangle", "woodblock", "wood block",
        "cabasa", "guiro", "timbale", "agogo", "djembe", "cajon",
        "snap", "fingersnap", "finger snap"
    },
    bass = {
        "bass", "sub", "808bass", "subbass", "sub_bass", "sub bass",
        "reese", "bass synth", "bassline", "bass_line"
    },
    synth = {
        -- Bare "lead" removed: false-positives in "release", "leader".
        -- "synth lead" / "synthlead" are explicit and safe; bare "lead"
        -- on its own as a filename is rare and ambiguous.
        "synth", "synth lead", "synthlead", "arp", "arpeggio",
        "pluck", "stab", "chord", "chords", "saw", "square", "sine",
        "supersaw", "hoover"
    },
    pad = {
        "pad", "pads", "ambient", "atmosphere", "atmo", "drone",
        "texture", "evolving", "soundscape"
    },
    keys = {
        -- "e_piano" removed (dead — underscore normalization). "epiano"
        -- and "electric piano" cover the legitimate cases.
        "piano", "keys", "keyboard", "organ", "rhodes", "wurlitzer",
        "electric piano", "epiano", "e piano", "clav", "clavinet",
        "marimba", "vibraphone", "xylophone", "glockenspiel", "celesta",
        "harp", "harpsichord", "mallet"
    },
    guitar = {
        "guitar", "gtr", "guit", "acoustic guitar", "electric guitar",
        "clean guitar", "distorted guitar", "overdrive guitar",
        "strat", "tele", "les paul", "nylon", "steel string", "ukulele"
    },
    strings = {
        "strings", "string", "violin", "viola", "cello", "contrabass",
        "orchestral", "ensemble", "chamber", "pizzicato", "legato strings"
    },
    brass = {
        "brass", "trumpet", "trombone", "horn", "french horn", "tuba",
        "flugelhorn", "cornet"
    },
    vocal = {
        "vocal", "vox", "voice", "choir", "acapella", "a capella",
        "singing", "spoken", "speech", "adlib", "chant"
    },
    fx = {
        "fx", "sfx", "effect", "riser", "impact", "downlifter",
        "uplifter", "whoosh", "sweep", "noise", "glitch", "stutter",
        "transition", "reverse", "buildup", "build up", "build_up",
        "drop", "explosion", "boom", "siren", "alarm", "foley",
        "cinematic", "hit", "one shot"
    },
    loop = {
        "loop", "break", "breakbeat", "drum loop", "drumloop",
        "drum_loop", "top loop", "toploop", "top_loop", "groove",
        "pattern", "beat", "full loop", "construction"
    }
}

-- Each category gets a unique hue spread around the color wheel. The 5
-- core drum types (kick/snare/clap/closed_hat/open_hat) are maximally
-- spread for instant visual distinction. RGB values are computed from
-- HSL(hue, S=0.75, L=0.55) to match the JSFX pad-face rendering.
-- The JSFX-side swing_color_drumtype_hue function in rk_swing_colors.jsfx-inc
-- mirrors the same hue assignments — colors stay consistent between the
-- browser file list and the JSFX pad grid.
local CATEGORY_COLORS = {
    kick =       0xE23636FF,  -- hue 0.00 (red)
    snare =      0xE2B236FF,  -- hue 0.12 (orange)
    rimshot =    0xE27436FF,  -- hue 0.06 (orange-red)
    clap =       0x59E236FF,  -- hue 0.30 (green)
    closed_hat = 0x36CEE2FF,  -- hue 0.52 (teal-cyan)
    hihat =      0x36E2D8FF,  -- hue 0.49 (teal)
    open_hat =   0x6D36E2FF,  -- hue 0.72 (violet)
    ride =       0xDFE236FF,  -- hue 0.17 (yellow)
    crash =      0xCAE236FF,  -- hue 0.19 (warm gold)
    cymbal =     0xB6E236FF,  -- hue 0.21 (gold)
    brass =      0xA1E236FF,  -- hue 0.23 (chartreuse)
    cowbell =    0x8CE236FF,  -- hue 0.25 (yellow-green)
    clave =      0x78E236FF,  -- hue 0.27 (lime)
    tambourine = 0x3AE236FF,  -- hue 0.33 (green)
    shaker =     0x36E247FF,  -- hue 0.35 (forest green)
    maraca =     0x36E25CFF,  -- hue 0.37 (green)
    percussion = 0x36E27BFF,  -- hue 0.40 (deep green)
    tom =        0xE25536FF,  -- hue 0.03 (red-orange)
    conga =      0xE2366AFF,  -- hue 0.95 (pink-red)
    bongo =      0xE23655FF,  -- hue 0.97 (magenta-red)
    guitar =     0x36E29AFF,  -- hue 0.43 (teal)
    strings =    0x36E2B9FF,  -- hue 0.46 (cyan)
    keys =       0x36AFE2FF,  -- hue 0.55 (cyan-blue)
    pad =        0x3690E2FF,  -- hue 0.58 (sky blue)
    vocal =      0x3666E2FF,  -- hue 0.62 (blue)
    synth =      0x363DE2FF,  -- hue 0.66 (indigo)
    bass =       0x9736E2FF,  -- hue 0.76 (purple)
    fx =         0xD536E2FF,  -- hue 0.82 (magenta)
    loop =       0xE236C7FF,  -- hue 0.86 (pink)
    other =      0xE2369DFF   -- hue 0.90 (warm pink)
}

local CATEGORY_ORDER = {
    -- Drum kit pieces first (most-used in the typical drum-sampler
    -- context). Hi-hat split: closed_hat and open_hat BEFORE generic
    -- hihat so specific variants win on tie-break (a name with "closed
    -- hat" picks closed_hat, not the generic "hat" keyword in hihat).
    "kick", "snare", "rimshot", "clap",
    "closed_hat", "open_hat", "hihat",
    "cymbal", "crash", "ride",
    "tom",
    "conga", "bongo", "cowbell", "clave", "tambourine", "shaker", "maraca",
    "percussion",
    "bass", "synth", "pad", "keys", "guitar", "strings", "brass",
    "vocal", "fx", "loop"
}

function categorizer.classify(filename, folder_path)
    local name_lower = filename:lower():gsub("[_%-%.%(%)]", " ")
    local folder_lower = ""
    if folder_path then
        folder_lower = folder_path:lower():gsub("[_%-%.%(%)]", " ")
    end

    local scores = {}
    for cat, keywords in pairs(CATEGORY_KEYWORDS) do
        scores[cat] = 0
        for _, kw in ipairs(keywords) do
            -- Short keywords (≤3 chars) are prone to substring false
            -- positives ("rim" → "primary", "tom" → "stomach"). Use
            -- Lua frontier patterns to match only at letter/non-letter
            -- transitions. %f[%a] = "previous char is non-letter, next
            -- is letter"; %f[%A] = the reverse. This hits "rim" in
            -- "rim wav", "tom" in "tom1 wav" (digit is non-letter), and
            -- correctly skips "rim" in "primary", "tom" in "stomach".
            -- Longer keywords keep plain substring matching so
            -- "808kick" (no separator) still hits "kick".
            local name_hit, folder_hit
            if #kw <= 3 then
                local pat = "%f[%a]" .. kw .. "%f[%A]"
                name_hit   = name_lower:find(pat) ~= nil
                folder_hit = folder_lower:find(pat) ~= nil
            else
                name_hit   = name_lower:find(kw, 1, true) ~= nil
                folder_hit = folder_lower:find(kw, 1, true) ~= nil
            end
            if name_hit   then scores[cat] = scores[cat] + 2 end
            if folder_hit then scores[cat] = scores[cat] + 1 end
        end
    end

    local best_cat = "other"
    local best_score = 0
    for _, cat in ipairs(CATEGORY_ORDER) do
        if scores[cat] and scores[cat] > best_score then
            best_score = scores[cat]
            best_cat = cat
        end
    end

    return best_cat, best_score > 0
end

function categorizer.get_category_color(category)
    return CATEGORY_COLORS[category] or CATEGORY_COLORS["other"]
end

function categorizer.get_category_order()
    return CATEGORY_ORDER
end

function categorizer.get_all_colors()
    return CATEGORY_COLORS
end

return categorizer
