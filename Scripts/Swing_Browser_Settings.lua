-- Swing Browser settings (per-user). The browser overwrites this file as the
-- user navigates / favorites / changes prefs. The shipped version below is a
-- clean default — empty recent + favorites + no hardcoded last_folder so a
-- new install starts at the user's own Downloads folder.
--
-- The Shortcuts panel (Desktop / Downloads / REAPER Resources / Project Dir)
-- is built dynamically from $USERPROFILE / $HOME at draw time
-- (Swing_Browser.lua → draw_shortcuts_panel), so those entries are already
-- portable across users.
return {
  version = 1,
  last_folder = "",
  window_w = 773,
  window_h = 928,
  volume = 1.000,
  auto_play = true,
  sort_column = 1,
  sort_ascending = true,
  loop_preview = false,
  theme = "light",
  show_shortcuts = true,
  show_favorites = true,
  show_recent = true,
  show_kits = true,
  -- Docking: 0 = floating (default). Negative IDs (-1..-16) target REAPER's
  -- native dockers; positive IDs are ImGui internal docks (rare). Updated
  -- from the live ImGui_GetWindowDockID() each frame so user-initiated
  -- drags persist across sessions.
  dock_id = 0,
  favorites = {
  },
  recent_folders = {
  },
}
