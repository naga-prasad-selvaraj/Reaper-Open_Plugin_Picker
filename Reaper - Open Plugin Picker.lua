-- Independent REAPER FX browser with metadata artwork, editable categories,
-- nested categories, and a complete searchable plugin library.

local TITLE, EXT = "Open Plugin Picker", "OpenPluginPicker"
local WIDTH, HEIGHT = 1260, 860
local CARD_W, CARD_H, CARD_GAP = 228, 246, 14
local LIST_TOP, FOOTER_H = 196, 34
local ALL, OTHER, PATH_SEP, MEMBER_SEP = "All", "Unassigned", "::", string.char(31)
local DEFAULT_CATEGORIES = { ALL }
local SEEDED_DEFAULTS = { Other = true, Dynamics = true, EQ = true, Reverb = true, Delay = true, Modulation = true, Saturation = true, Utility = true, Instruments = true }

local query, library_query, active_category, view_mode = "", "", ALL, "cards"
local library_search_focused, cards_search_focused = false, false
local scroll, library_page, selected, main_scroll, sub_scroll = 0, 1, 1, 0, 0
local plugins, categories, plugin_categories, plugin_images = {}, {}, {}, {}
local image_slots, slot_paths, next_image_slot = {}, {}, 0
local last_mouse_cap = 0
local card_layout, library_layout = {}, {}
local main_tabs, sub_tabs, controls = {}, {}, {}
local snapshot_notice_shown = false

local function encode(value)
  return (value or ""):gsub("([^%w%-_%.~])", function(ch) return string.format("%%%02X", ch:byte()) end)
end

local function decode(value)
  return (value or ""):gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
end

local function split_lines(value)
  local out = {}
  for line in ((value or "") .. "\n"):gmatch("(.-)\n") do if line ~= "" then out[#out + 1] = line end end
  return out
end

local function load_pairs(key)
  local out = {}
  for _, line in ipairs(split_lines(reaper.GetExtState(EXT, key))) do
    local a, b = line:match("^([^\t]*)\t(.*)$")
    if a and b then out[decode(a)] = decode(b) end
  end
  return out
end

local function save_state()
  local cat_lines = {}
  for _, name in ipairs(categories) do cat_lines[#cat_lines + 1] = encode(name) end
  reaper.SetExtState(EXT, "categories", table.concat(cat_lines, "\n"), true)
  local function serialize(map)
    local lines = {}
    for key, value in pairs(map) do lines[#lines + 1] = encode(key) .. "\t" .. encode(value) end
    table.sort(lines)
    return table.concat(lines, "\n")
  end
  reaper.SetExtState(EXT, "plugin_categories", serialize(plugin_categories), true)
  reaper.SetExtState(EXT, "plugin_images", serialize(plugin_images), true)
end

local function load_state()
  local saved = split_lines(reaper.GetExtState(EXT, "categories"))
  categories = {}
  if #saved == 0 then
    for _, name in ipairs(DEFAULT_CATEGORIES) do categories[#categories + 1] = name end
  else
    for _, name in ipairs(saved) do categories[#categories + 1] = decode(name) end
  end
  if categories[1] ~= ALL then table.insert(categories, 1, ALL) end
  local function is_old_default(path)
    local root = path:match("^(.-)" .. PATH_SEP) or path
    return SEEDED_DEFAULTS[root] == true
  end
  local unique, seen = {}, {}
  for _, name in ipairs(categories) do
    if name ~= "" and name ~= OTHER and not is_old_default(name) and not seen[name] then
      unique[#unique + 1], seen[name] = name, true
    end
  end
  if unique[1] ~= ALL then table.insert(unique, 1, ALL) end
  categories = unique
  plugin_categories = load_pairs("plugin_categories")
  plugin_images = load_pairs("plugin_images")
  for ident, raw in pairs(plugin_categories) do
    local values = {}
    for path in raw:gmatch("([^" .. MEMBER_SEP .. "]+)") do
      if path ~= OTHER and not is_old_default(path) then values[#values + 1] = path end
    end
    plugin_categories[ident] = #values > 0 and table.concat(values, MEMBER_SEP) or nil
  end
  save_state()
end

local function category_parent(path)
  return path:match("^(.-)" .. PATH_SEP) or nil
end

local function category_label(path)
  return (path or ""):gsub(PATH_SEP, "  ›  ")
end

local function category_name(path)
  local parent = category_parent(path)
  return parent and path:sub(#parent + #PATH_SEP + 1) or path
end

local function main_categories()
  local out = {}
  for _, name in ipairs(categories) do if not category_parent(name) then out[#out + 1] = name end end
  return out
end

local function children_of(parent)
  local out, prefix = {}, parent .. PATH_SEP
  for _, name in ipairs(categories) do
    if name:sub(1, #prefix) == prefix and not name:sub(#prefix + 1):find(PATH_SEP, 1, true) then out[#out + 1] = name end
  end
  return out
end

local function memberships(fx)
  local out = {}
  for name in (plugin_categories[fx.ident] or ""):gmatch("([^" .. MEMBER_SEP .. "]+)") do out[#out + 1] = name end
  return out
end

local function has_category(fx, target)
  local values = memberships(fx)
  if target == OTHER then return #values == 0 end
  local is_main = not category_parent(target)
  for _, name in ipairs(values) do
    if name == target or (is_main and name:sub(1, #target + #PATH_SEP) == target .. PATH_SEP) then return true end
  end
  return false
end

local function directly_has_category(fx, target)
  local values = memberships(fx)
  if target == OTHER then return #values == 0 end
  for _, name in ipairs(values) do if name == target then return true end end
  return false
end

local function category_text(fx)
  local values = memberships(fx)
  if #values == 0 then return OTHER end
  if #values == 1 then return category_label(values[1]) end
  return tostring(#values) .. " categories"
end

local function prompt_for_search(title, current)
  local ok, value = reaper.GetUserInputs(title, 1, "Filter text", current or "")
  if ok then return value end
  return nil
end

local function toggle_category(fx, target)
  if target == OTHER then plugin_categories[fx.ident] = nil; return end
  local values, found = memberships(fx), false
  for i = #values, 1, -1 do
    if values[i] == target then table.remove(values, i); found = true end
  end
  if not found then values[#values + 1] = target end
  plugin_categories[fx.ident] = #values > 0 and table.concat(values, MEMBER_SEP) or nil
end

local function refresh_plugins()
  local found, i = {}, 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    if name and ident and name ~= "" and ident ~= "" then found[#found + 1] = { name = name, ident = ident } end
    i = i + 1
  end
  table.sort(found, function(a, b) return a.name:lower() < b.name:lower() end)
  plugins = found
end

local function filtered_plugins(all_categories, search_text)
  local out, needle = {}, (search_text == nil and query or search_text):lower()
  for _, fx in ipairs(plugins) do
    local category_match = all_categories or (active_category == ALL and #memberships(fx) > 0) or has_category(fx, active_category)
    if category_match and (needle == "" or fx.name:lower():find(needle, 1, true)) then out[#out + 1] = fx end
  end
  return out
end

local schedule_snapshot

local function insert_plugin(fx, target_category)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Select a track first, then choose a plugin.", TITLE, 0)
    return false
  end
  reaper.Undo_BeginBlock()
  local index = reaper.TrackFX_AddByName(track, fx.ident, false, -1)
  reaper.Undo_EndBlock("Add FX: " .. fx.name, -1)
  if index < 0 then
    reaper.ShowMessageBox("REAPER could not add this effect:\n" .. fx.name, TITLE, 0)
    return false
  end
  reaper.TrackFX_Show(track, index, 3)
  if schedule_snapshot then schedule_snapshot(track, index, fx, target_category) end
  return true
end

local function stable_hash(value)
  local hash = 5381
  for i = 1, #value do hash = (hash * 33 + value:byte(i)) % 4294967296 end
  return string.format("%08X", hash)
end

local function snapshot_path(fx)
  local sep = package.config:sub(1, 1)
  local dir = reaper.GetResourcePath() .. sep .. "PluginPicker" .. sep .. "Artwork"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir .. sep .. stable_hash(fx.ident) .. ".png"
end

local function capture_plugin_window(track, index, fx)
  local required = { "JS_Window_GetClientRect", "JS_GDI_GetClientDC", "JS_GDI_ReleaseDC", "JS_GDI_Blit", "JS_LICE_CreateBitmap", "JS_LICE_GetDC", "JS_LICE_WritePNG", "JS_LICE_DestroyBitmap" }
  for _, api in ipairs(required) do
    if not reaper.APIExists(api) then return false, "Install or update js_ReaScriptAPI to capture plugin window images." end
  end
  local hwnd = reaper.TrackFX_GetFloatingWindow(track, index)
  if not hwnd then return false, "REAPER did not open a floating window for this plugin." end
  local ok, left, top, right, bottom = reaper.JS_Window_GetClientRect(hwnd)
  if not ok then return false, "Could not read the plugin window size." end
  local width, height = right - left, bottom - top
  if width < 2 or height < 2 then return false, "The plugin window has no capturable area." end
  local source = reaper.JS_GDI_GetClientDC(hwnd)
  if not source then return false, "Could not access the plugin window for capture." end
  local bitmap = reaper.JS_LICE_CreateBitmap(true, width, height)
  if not bitmap then reaper.JS_GDI_ReleaseDC(source, hwnd); return false, "Could not create an image for this plugin." end
  local dest = reaper.JS_LICE_GetDC(bitmap)
  if not dest then
    reaper.JS_GDI_ReleaseDC(source, hwnd)
    reaper.JS_LICE_DestroyBitmap(bitmap)
    return false, "Could not access the capture image buffer."
  end
  reaper.JS_GDI_Blit(dest, 0, 0, source, 0, 0, width, height, "SRCCOPY")
  reaper.JS_GDI_ReleaseDC(source, hwnd)
  local path = snapshot_path(fx)
  local written = reaper.JS_LICE_WritePNG(path, bitmap, false)
  reaper.JS_LICE_DestroyBitmap(bitmap)
  if not written then return false, "The plugin window could not be saved as an image." end
  return true, path
end

local function add_to_category(fx, target)
  local values = memberships(fx)
  for _, path in ipairs(values) do if path == target then return end end
  values[#values + 1] = target
  plugin_categories[fx.ident] = table.concat(values, MEMBER_SEP)
end

schedule_snapshot = function(track, index, fx, target_category)
  local attempts = 0
  local started = reaper.time_precise()
  local function capture_when_ready()
    attempts = attempts + 1
    local hwnd = reaper.TrackFX_GetFloatingWindow(track, index)
    local elapsed = reaper.time_precise() - started
    if elapsed >= 0.8 and (hwnd or attempts >= 40) then
      local ok, result = capture_plugin_window(track, index, fx)
      if ok then plugin_images[fx.ident] = result end
      if target_category then add_to_category(fx, target_category) end
      save_state(); image_slots, slot_paths, next_image_slot = {}, {}, 0
      if not ok and not snapshot_notice_shown then
        snapshot_notice_shown = true
        reaper.ShowMessageBox("The effect was added, but its snapshot could not be captured. " .. tostring(result) .. " You can still choose an image from the card's right-click menu.", TITLE, 0)
      end
      return
    end
    if attempts < 120 then reaper.defer(capture_when_ready)
    else
      if target_category then add_to_category(fx, target_category); save_state() end
      if not snapshot_notice_shown then
        snapshot_notice_shown = true
        reaper.ShowMessageBox("The effect was added, but REAPER did not provide a capturable plugin window. Keep its window open and use the card's image menu to add a picture.", TITLE, 0)
      end
    end
  end
  reaper.defer(capture_when_ready)
end

local function image_slot(path)
  if not path or path == "" then return nil end
  if image_slots[path] ~= nil then return image_slots[path] or nil end
  local slot = next_image_slot
  next_image_slot = (next_image_slot + 1) % 128
  local old = slot_paths[slot]
  if old then image_slots[old] = nil end
  if gfx.loadimg(slot, path) < 0 then image_slots[path], slot_paths[slot] = false, nil; return nil end
  image_slots[path], slot_paths[slot] = slot, path
  return slot
end

local function draw_image(path, x, y, w, h)
  local slot = image_slot(path)
  if not slot then return false end
  local iw, ih = gfx.getimgdim(slot)
  if iw <= 0 or ih <= 0 then return false end
  local scale = math.min(w / iw, h / ih)
  local dw, dh = iw * scale, ih * scale
  gfx.blit(slot, 1, 0, 0, 0, iw, ih, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh, 0, 0)
  return true
end

local function plugin_metadata(fx)
  local format = fx.name:match("^([^:]+):") or fx.ident:match("^([^:]+):") or "REAPER FX"
  local clean = fx.name:gsub("^[^:]+:%s*", "")
  local lower = (clean .. " " .. fx.ident):lower()
  local family = "Effect"
  if lower:match("synth") or lower:match("instrument") or lower:match("sampler") or lower:match("piano") or lower:match("drum") then family = "Instrument"
  elseif lower:match("equaliz") or lower:match("%seq%s") or lower:match("eq$") or lower:match("filter") then family = "Equalizer"
  elseif lower:match("compress") or lower:match("limiter") or lower:match("gate") or lower:match("dynamics") then family = "Dynamics"
  elseif lower:match("reverb") or lower:match("verb") then family = "Reverb"
  elseif lower:match("delay") or lower:match("echo") then family = "Delay"
  elseif lower:match("chorus") or lower:match("flanger") or lower:match("phaser") or lower:match("modulat") then family = "Modulation"
  elseif lower:match("meter") or lower:match("utility") or lower:match("routing") then family = "Utility" end
  return clean, format:upper(), family
end

local PALETTES = {
  Instrument = { 0.16, 0.34, 0.49 }, Equalizer = { 0.18, 0.39, 0.32 }, Dynamics = { 0.42, 0.25, 0.20 },
  Reverb = { 0.29, 0.25, 0.48 }, Delay = { 0.45, 0.31, 0.16 }, Modulation = { 0.19, 0.34, 0.45 },
  Utility = { 0.29, 0.34, 0.38 }, Effect = { 0.22, 0.28, 0.37 }
}

local function monogram(name)
  local words = {}
  for word in name:gmatch("[%w]+") do words[#words + 1] = word end
  if #words > 1 then return (words[1]:sub(1, 1) .. words[2]:sub(1, 1)):upper() end
  return name:sub(1, 3):upper()
end

local function draw_metadata_art(fx, x, y, w, h)
  local clean, format, family = plugin_metadata(fx)
  local c = PALETTES[family] or PALETTES.Effect
  gfx.gradrect(x, y, w, h, c[1], c[2], c[3], 1, 0.10, 0.10, 0.11, 0, -0.10, -0.08, -0.04, 0)
  gfx.set(c[1] + 0.18, c[2] + 0.14, c[3] + 0.13, 0.28)
  gfx.circle(x + w * 0.83, y + h * 0.15, h * 0.31, 1, 1)
  gfx.set(0.96, 0.97, 1, 0.88)
  gfx.setfont(1, "Arial", 15, "b")
  gfx.x, gfx.y = x + 13, y + 12
  gfx.drawstr(format .. "  /  " .. family:upper(), 1, x + w - 10, y + 35)
  gfx.setfont(1, "Arial", 48, "b")
  local mark = monogram(clean)
  gfx.x, gfx.y = x + 16, y + h * 0.35
  gfx.drawstr(mark, 1, x + w - 12, y + h * 0.78)
  gfx.setfont(1, "Arial", 13)
  gfx.set(0.91, 0.94, 0.98, 0.8)
  gfx.x, gfx.y = x + 14, y + h - 26
  gfx.drawstr(clean, 1, x + w - 12, y + h - 5)
end

local function popup(menu, x, y)
  local items = 1
  for _ in menu:gmatch("|") do items = items + 1 end
  local menu_h = math.min(gfx.h - 8, items * 24 + 8)
  gfx.x = math.max(4, math.min(x, gfx.w - 340))
  gfx.y = math.max(4, math.min(y, gfx.h - menu_h - 4))
  return gfx.showmenu(menu)
end

local function create_category(raw_name, parent)
  local name = (raw_name or ""):gsub("|", "-"):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or name == ALL or name == OTHER or name:find(PATH_SEP, 1, true) then return end
  local path = parent and (parent .. PATH_SEP .. name) or name
  for _, existing in ipairs(categories) do if existing:lower() == path:lower() then return end end
  categories[#categories + 1] = path
  active_category, selected, scroll = path, 1, 0
  save_state()
end

local function rename_category(old, raw_name)
  if old == ALL or old == OTHER then return end
  local name = (raw_name or ""):gsub("|", "-"):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or name == ALL or name == OTHER or name:find(PATH_SEP, 1, true) then return end
  local parent = category_parent(old)
  local new = parent and (parent .. PATH_SEP .. name) or name
  for _, existing in ipairs(categories) do if existing ~= old and existing:lower() == new:lower() then return end end
  local prefix = old .. PATH_SEP
  for i, path in ipairs(categories) do
    if path == old then categories[i] = new
    elseif not parent and path:sub(1, #prefix) == prefix then categories[i] = new .. path:sub(#old + 1) end
  end
  for ident, raw in pairs(plugin_categories) do
    local values = {}
    for path in raw:gmatch("([^" .. MEMBER_SEP .. "]+)") do
      if path == old then values[#values + 1] = new
      elseif not parent and path:sub(1, #prefix) == prefix then values[#values + 1] = new .. path:sub(#old + 1)
      else values[#values + 1] = path end
    end
    plugin_categories[ident] = #values > 0 and table.concat(values, MEMBER_SEP) or nil
  end
  if active_category == old then active_category = new
  elseif not parent and active_category:sub(1, #prefix) == prefix then active_category = new .. active_category:sub(#old + 1) end
  save_state()
end

local function delete_category(target)
  if target == ALL or target == OTHER then return end
  if reaper.ShowMessageBox("Delete " .. category_label(target) .. "? Plugins assigned only to it will become uncategorized.", TITLE, 1) ~= 1 then return end
  local prefix = target .. PATH_SEP
  for i = #categories, 1, -1 do
    local path = categories[i]
    if path == target or (not category_parent(target) and path:sub(1, #prefix) == prefix) then table.remove(categories, i) end
  end
  for ident, raw in pairs(plugin_categories) do
    local values = {}
    for path in raw:gmatch("([^" .. MEMBER_SEP .. "]+)") do
      if path ~= target and (category_parent(target) or path:sub(1, #prefix) ~= prefix) then values[#values + 1] = path end
    end
    plugin_categories[ident] = #values > 0 and table.concat(values, MEMBER_SEP) or nil
  end
  active_category, selected, scroll = ALL, 1, 0
  save_state()
end

local function image_slot(path)
  if not path or path == "" then return nil end
  if image_slots[path] ~= nil then return image_slots[path] or nil end
  local slot = next_image_slot
  next_image_slot = (next_image_slot + 1) % 128
  local old = slot_paths[slot]
  if old then image_slots[old] = nil end
  if gfx.loadimg(slot, path) < 0 then image_slots[path], slot_paths[slot] = false, nil; return nil end
  image_slots[path], slot_paths[slot] = slot, path
  return slot
end

local function choose_image(fx)
  local ok, path = reaper.GetUserFileNameForRead(plugin_images[fx.ident] or "", "Choose plugin screenshot or image", "png")
  if ok and path and path ~= "" then
    image_slots[path] = nil
    if image_slot(path) then plugin_images[fx.ident] = path; save_state()
    else reaper.ShowMessageBox("Could not load that image. Choose a PNG, JPG, or BMP file.", TITLE, 0) end
  end
end

local function normalized_name(value)
  return (value or ""):lower():gsub("[^%w]", "")
end

local function auto_match_images()
  local ok, sample = reaper.GetUserFileNameForRead("", "Select any image in the artwork folder", "png")
  if not ok or not sample then return end
  local directory = sample:match("^(.*)[/\\][^/\\]+$")
  if not directory then return end
  local separator, images, i = package.config:sub(1, 1), {}, 0
  while true do
    local filename = reaper.EnumerateFiles(directory, i)
    if not filename then break end
    local ext = filename:match("%.([^%.]+)$")
    ext = ext and ext:lower() or ""
    if ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "bmp" then
      local stem = filename:gsub("%.[^%.]*$", "")
      local key = normalized_name(stem)
      if key ~= "" and not images[key] then images[key] = directory .. separator .. filename end
    end
    i = i + 1
  end
  local matched = 0
  for _, fx in ipairs(plugins) do
    local bare_name = fx.name:gsub("^[^:]+:%s*", "")
    local path = images[normalized_name(fx.name)] or images[normalized_name(bare_name)] or images[normalized_name(fx.ident)]
    if path then plugin_images[fx.ident] = path; matched = matched + 1 end
  end
  image_slots, slot_paths, next_image_slot = {}, {}, 0
  save_state()
  reaper.ShowMessageBox("Matched artwork to " .. tostring(matched) .. " of " .. tostring(#plugins) .. " effects. Name image files after plugin names for a match.", TITLE, 0)
end

local function assignment_menu(fx, x, y)
  local options = { "Choose screenshot/image...", "Use metadata artwork", "#Assign categories (toggle)" }
  for _, path in ipairs(categories) do
    if path ~= ALL then options[#options + 1] = (directly_has_category(fx, path) and "!" or "") .. category_label(path) end
  end
  options[#options + 1] = "Auto-match artwork folder..."
  local choice = popup(table.concat(options, "|"), x, y)
  if choice == 1 then choose_image(fx)
  elseif choice == 2 then plugin_images[fx.ident] = nil; save_state()
  elseif choice >= 4 and choice < #options then
    toggle_category(fx, categories[choice - 2]); save_state()
  elseif choice == #options then auto_match_images() end
end

local function library_category_menu(fx, x, y)
  local choices = {}
  for _, path in ipairs(categories) do if path ~= ALL then choices[#choices + 1] = path end end
  if #choices == 0 then
    reaper.ShowMessageBox("Create a main category with the + button before adding plugins to the library.", TITLE, 0)
    return
  end
  local labels = {}
  for _, path in ipairs(choices) do labels[#labels + 1] = category_label(path) end
  local choice = popup(table.concat(labels, "|"), x, y)
  if choice > 0 and choices[choice] then insert_plugin(fx, choices[choice]) end
end

local function draw_category_bars()
  main_tabs, sub_tabs = {}, {}
  local mains, y, tab_w = main_categories(), 94, 126
  local first_x, gap = 50, 8
  local visible = math.max(1, math.floor((gfx.w - first_x - 122) / (tab_w + gap)))
  main_scroll = math.max(0, math.min(main_scroll, math.max(0, #mains - visible)))
  controls.main_left = { x = 14, y = y, w = 26, h = 36 }
  controls.main_right = { x = gfx.w - 94, y = y, w = 26, h = 36 }
  controls.main_plus = { x = gfx.w - 54, y = y, w = 40, h = 36 }
  gfx.setfont(1, "Arial", 18, "b")
  gfx.set(0.58, 0.64, 0.71, 1)
  gfx.x, gfx.y = 19, y + 6; gfx.drawstr("‹")
  gfx.x, gfx.y = gfx.w - 90, y + 6; gfx.drawstr("›")
  gfx.set(0.36, 0.78, 0.96, 1)
  gfx.x, gfx.y = gfx.w - 43, y + 7; gfx.drawstr("+")
  local parent = category_parent(active_category) or active_category
  for i = 1, visible do
    local index, name = main_scroll + i, mains[main_scroll + i]
    if not name then break end
    local x = first_x + (i - 1) * (tab_w + gap)
    local active = name == parent
    gfx.set(active and 0.12 or 0.095, active and 0.36 or 0.12, active and 0.51 or 0.16, 1)
    gfx.roundrect(x, y, tab_w, 36, 6, 1)
    gfx.set(active and 1 or 0.78, active and 1 or 0.84, active and 1 or 0.90, 1)
    gfx.setfont(1, "Arial", 17, active and "b" or "")
    gfx.x, gfx.y = x + 10, y + 8; gfx.drawstr(name, 1, x + tab_w - 7, y + 32)
    main_tabs[#main_tabs + 1] = { name = name, x = x, y = y, w = tab_w, h = 36 }
  end

  local sub_y, sub_w = 140, 164
  local children = (parent ~= ALL and parent ~= OTHER) and children_of(parent) or {}
  local all_subs = { parent }
  for _, child in ipairs(children) do all_subs[#all_subs + 1] = child end
  local sub_visible = math.max(1, math.floor((gfx.w - first_x - 122) / (sub_w + gap)))
  sub_scroll = math.max(0, math.min(sub_scroll, math.max(0, #all_subs - sub_visible)))
  controls.sub_left = { x = 14, y = sub_y, w = 26, h = 32 }
  controls.sub_right = { x = gfx.w - 94, y = sub_y, w = 26, h = 32 }
  controls.sub_plus = { x = gfx.w - 54, y = sub_y, w = 40, h = 32 }
  gfx.setfont(1, "Arial", 16, "b"); gfx.set(0.55, 0.62, 0.70, 1)
  gfx.x, gfx.y = 19, sub_y + 4; gfx.drawstr("‹")
  gfx.x, gfx.y = gfx.w - 90, sub_y + 4; gfx.drawstr("›")
  gfx.set(0.36, 0.78, 0.96, 1); gfx.x, gfx.y = gfx.w - 43, sub_y + 4; gfx.drawstr("+")
  if #children == 0 then
    gfx.setfont(1, "Arial", 14); gfx.set(0.49, 0.56, 0.64, 1)
    gfx.x, gfx.y = first_x + 2, sub_y + 8
    local hint = (parent == ALL or parent == OTHER) and "Pick a main category to manage subcategories" or (parent .. "  /  no subcategories yet")
    gfx.drawstr(hint)
  else
    for i = 1, sub_visible do
      local path = all_subs[sub_scroll + i]
      if not path then break end
      local x = first_x + (i - 1) * (sub_w + gap)
      local active = path == active_category
      gfx.set(active and 0.12 or 0.10, active and 0.31 or 0.13, active and 0.43 or 0.17, 1)
      gfx.roundrect(x, sub_y, sub_w, 32, 6, 1)
      gfx.set(active and 0.95 or 0.72, active and 0.96 or 0.80, active and 1 or 0.88, 1)
      gfx.setfont(1, "Arial", 15, active and "b" or "")
      gfx.x, gfx.y = x + 9, sub_y + 7
      gfx.drawstr(path == parent and ("All " .. parent) or category_label(path:sub(#parent + #PATH_SEP + 1)), 1, x + sub_w - 8, sub_y + 29)
      sub_tabs[#sub_tabs + 1] = { name = path, x = x, y = sub_y, w = sub_w, h = 32 }
    end
  end
end

local function draw_metadata_card(fx, x, y, w, h)
  local clean, format, family = plugin_metadata(fx)
  local c = PALETTES[family] or PALETTES.Effect
  gfx.gradrect(x, y, w, h, c[1], c[2], c[3], 1, 0.12, 0.10, 0.08, 0, -0.10, -0.08, -0.05, 0)
  gfx.set(c[1] + 0.16, c[2] + 0.16, c[3] + 0.16, 0.30)
  gfx.circle(x + w * 0.83, y + h * 0.15, h * 0.32, 1, 1)
  gfx.set(0.96, 0.98, 1, 0.9)
  gfx.setfont(1, "Arial", 15, "b"); gfx.x, gfx.y = x + 13, y + 12
  gfx.drawstr(format .. "  /  " .. family:upper(), 1, x + w - 10, y + 35)
  gfx.setfont(1, "Arial", 54, "b"); gfx.x, gfx.y = x + 16, y + h * 0.33
  gfx.drawstr(monogram(clean), 1, x + w - 12, y + h * 0.76)
  gfx.setfont(1, "Arial", 15); gfx.set(0.92, 0.95, 0.99, 0.86)
  gfx.x, gfx.y = x + 14, y + h - 30; gfx.drawstr(clean, 1, x + w - 12, y + h - 5)
end

local function draw_cards(list)
  card_layout = {}
  local columns = math.max(1, math.floor((gfx.w - 32 + CARD_GAP) / (CARD_W + CARD_GAP)))
  local rows = math.max(1, math.floor((gfx.h - LIST_TOP - FOOTER_H + CARD_GAP) / (CARD_H + CARD_GAP)))
  local page = columns * rows
  scroll = math.max(0, math.min(scroll, math.max(0, #list - page)))
  selected = #list > 0 and math.max(1, math.min(selected, #list)) or 1
  if #list == 0 then
    gfx.setfont(1, "Arial", 19); gfx.set(0.64, 0.69, 0.75, 1)
    gfx.x, gfx.y = 20, LIST_TOP + 20
    gfx.drawstr("No plugins match this view. Use Plugin Library to search and organize all scanned plugins.")
  end
  for visible_i = 1, page do
    local index, fx = scroll + visible_i, list[scroll + visible_i]
    if not fx then break end
    local row, col = math.floor((visible_i - 1) / columns), (visible_i - 1) % columns
    local x, y = 16 + col * (CARD_W + CARD_GAP), LIST_TOP + row * (CARD_H + CARD_GAP)
    local chosen = index == selected
    gfx.set(chosen and 0.22 or 0.11, chosen and 0.34 or 0.13, chosen and 0.47 or 0.17, 1)
    gfx.roundrect(x, y, CARD_W, CARD_H, 8, 1)
    gfx.set(0.07, 0.085, 0.11, 1); gfx.roundrect(x + 9, y + 9, CARD_W - 18, 154, 6, 1)
    if not draw_image(plugin_images[fx.ident], x + 12, y + 12, CARD_W - 24, 148) then
      draw_metadata_card(fx, x + 9, y + 9, CARD_W - 18, 154)
    end
    gfx.setfont(1, "Arial", 16, "b"); gfx.set(0.96, 0.97, 0.99, 1)
    local max_text_w, max_lines = CARD_W - 24, 2
    local lines, line, truncated = {}, "", false
    for word in fx.name:gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if gfx.measurestr(candidate) <= max_text_w then line = candidate
      elseif line ~= "" then
        lines[#lines + 1] = line
        if #lines >= max_lines then truncated = true; line = ""; break end
        line = word
      else
        line = word
      end
    end
    if line ~= "" and #lines < max_lines then lines[#lines + 1] = line end
    if #lines > 0 and gfx.measurestr(lines[#lines]) > max_text_w then truncated = true end
    if truncated and #lines > 0 then
      local last = lines[#lines]
      while #last > 0 and gfx.measurestr(last .. "…") > max_text_w do
        local start = #last
        while start > 1 do
          local byte = last:byte(start)
          if not byte or byte < 128 or byte > 191 then break end
          start = start - 1
        end
        last = last:sub(1, start - 1)
      end
      lines[#lines] = last .. "…"
    end
    for line_i, text in ipairs(lines) do
      gfx.x, gfx.y = x + 12, y + 168 + (line_i - 1) * 19
      gfx.drawstr(text, 0, x + CARD_W - 12, y + 210)
    end
    gfx.setfont(1, "Arial", 13); gfx.set(0.65, 0.73, 0.81, 1)
    gfx.x, gfx.y = x + 12, y + 222; gfx.drawstr(category_text(fx), 1, x + CARD_W - 10, y + CARD_H - 3)
    card_layout[#card_layout + 1] = { fx = fx, index = index, x = x, y = y, w = CARD_W, h = CARD_H }
  end
  return columns, page
end

local function draw_library()
  library_layout = {}
  local list = filtered_plugins(true, library_query)
  gfx.setfont(1, "Arial", 22, "b"); gfx.set(0.93, 0.96, 0.99, 1)
  gfx.x, gfx.y = 18, LIST_TOP + 1; gfx.drawstr("Plugin Library")
  gfx.setfont(1, "Arial", 15); gfx.set(0.60, 0.68, 0.76, 1)
  gfx.x, gfx.y = 202, LIST_TOP + 7; gfx.drawstr("All scanned effects • " .. #list .. " shown")
  local search_y = LIST_TOP + 34
  controls.library_search = { x = 16, y = search_y, w = gfx.w - 430, h = 38 }
  controls.library_clear = { x = gfx.w - 408, y = search_y, w = 36, h = 38 }
  controls.library_prev = { x = gfx.w - 320, y = search_y, w = 92, h = 38 }
  controls.library_next = { x = gfx.w - 104, y = search_y, w = 88, h = 38 }
  gfx.set(0.10, 0.12, 0.15, 1); gfx.roundrect(controls.library_search.x, search_y, controls.library_search.w, 38, 6, 1)
  if library_search_focused then gfx.set(0.20, 0.61, 0.83, 1); gfx.roundrect(controls.library_search.x, search_y, controls.library_search.w, 38, 6, 0) end
  gfx.setfont(1, "Arial", 18); gfx.set(0.93, 0.95, 0.98, 1)
  gfx.x, gfx.y = controls.library_search.x + 12, search_y + 9
  gfx.drawstr(library_query == "" and "Click to filter all scanned plugins..." or library_query)
  gfx.set(0.14, 0.22, 0.29, 1); gfx.roundrect(controls.library_clear.x, search_y, controls.library_clear.w, 38, 5, 1)
  gfx.setfont(1, "Arial", 17, "b"); gfx.set(0.89, 0.94, 0.99, 1)
  gfx.x, gfx.y = controls.library_clear.x + 12, search_y + 9; gfx.drawstr("×")
  local row_h, y0 = 52, search_y + 49
  local visible = math.max(1, math.floor((gfx.h - y0 - FOOTER_H) / row_h))
  local pages = math.max(1, math.ceil(#list / visible))
  library_page = math.max(1, math.min(library_page, pages))
  local first = (library_page - 1) * visible
  selected = #list > 0 and math.max(1, math.min(selected, #list)) or 1
  gfx.set(0.12, 0.20, 0.28, 1); gfx.roundrect(controls.library_prev.x, search_y, controls.library_prev.w, 38, 5, 1)
  gfx.roundrect(controls.library_next.x, search_y, controls.library_next.w, 38, 5, 1)
  gfx.setfont(1, "Arial", 15, "b"); gfx.set(0.92, 0.95, 0.99, 1)
  gfx.x, gfx.y = controls.library_prev.x + 17, search_y + 10; gfx.drawstr("‹  Previous")
  gfx.x, gfx.y = controls.library_next.x + 17, search_y + 10; gfx.drawstr("Next  ›")
  gfx.setfont(1, "Arial", 14); gfx.set(0.62, 0.70, 0.78, 1)
  gfx.x, gfx.y = gfx.w - 218, search_y + 11; gfx.drawstr("Page " .. library_page .. " / " .. pages)
  for i = 1, visible do
    local index, fx = first + i, list[first + i]
    if not fx then break end
    local y = y0 + (i - 1) * row_h
    local chosen = selected == index
    gfx.set(chosen and 0.16 or (i % 2 == 0 and 0.10 or 0.085), chosen and 0.28 or 0.11, chosen and 0.39 or 0.14, 1)
    gfx.roundrect(14, y, gfx.w - 28, row_h - 5, 5, 1)
    gfx.setfont(1, "Arial", 18, "b"); gfx.set(0.94, 0.96, 0.99, 1)
    gfx.x, gfx.y = 26, y + 13; gfx.drawstr(fx.name, 1, gfx.w * 0.53, y + row_h - 5)
    gfx.setfont(1, "Arial", 14); gfx.set(0.61, 0.70, 0.79, 1)
    gfx.x, gfx.y = gfx.w * 0.54, y + 15; gfx.drawstr(category_text(fx), 1, gfx.w - 324, y + row_h - 5)
    local categorize = { x = gfx.w - 310, y = y + 7, w = 186, h = 34 }
    local insert = { x = gfx.w - 112, y = y + 7, w = 94, h = 34 }
    gfx.set(0.15, 0.28, 0.37, 1); gfx.roundrect(categorize.x, categorize.y, categorize.w, categorize.h, 5, 1)
    gfx.set(0.88, 0.93, 0.98, 1); gfx.setfont(1, "Arial", 14, "b")
    gfx.x, gfx.y = categorize.x + 12, categorize.y + 9; gfx.drawstr("Add to category")
    gfx.set(0.13, 0.36, 0.51, 1); gfx.roundrect(insert.x, insert.y, insert.w, insert.h, 5, 1)
    gfx.set(0.95, 0.97, 1, 1); gfx.x, gfx.y = insert.x + 9, insert.y + 9; gfx.drawstr("Insert + snap")
    library_layout[#library_layout + 1] = { fx = fx, index = index, x = 14, y = y, w = gfx.w - 28, h = row_h - 5, categorize = categorize, insert = insert }
  end
  return list, visible, pages
end

local function draw()
  controls = {}
  gfx.set(0.045, 0.055, 0.075, 1); gfx.rect(0, 0, gfx.w, gfx.h, 1)
  gfx.setfont(1, "Arial", 28, "b"); gfx.set(0.95, 0.97, 1, 1)
  gfx.x, gfx.y = 18, 12; gfx.drawstr(TITLE)
  local toggle_w, toggle_y = 142, 10
  controls.cards_mode = { x = gfx.w - 310, y = toggle_y, w = toggle_w, h = 36 }
  controls.library_mode = { x = gfx.w - 158, y = toggle_y, w = toggle_w, h = 36 }
  local modes = { { "cards", controls.cards_mode, "Cards" }, { "library", controls.library_mode, "Plugin Library" } }
  for _, entry in ipairs(modes) do
    local mode, box, label = entry[1], entry[2], entry[3]
    local active = view_mode == mode
    gfx.set(active and 0.14 or 0.10, active and 0.34 or 0.13, active and 0.49 or 0.17, 1)
    gfx.roundrect(box.x, box.y, box.w, box.h, 6, 1)
    gfx.set(active and 1 or 0.74, active and 1 or 0.81, active and 1 or 0.89, 1)
    gfx.setfont(1, "Arial", 16, active and "b" or "")
    gfx.x, gfx.y = box.x + 13, box.y + 9; gfx.drawstr(label)
  end
  local list = view_mode == "library" and filtered_plugins(true, library_query) or filtered_plugins(false, query)
  if view_mode == "cards" then
    gfx.set(0.10, 0.12, 0.15, 1); gfx.roundrect(16, 54, gfx.w - 32, 36, 6, 1)
    controls.cards_search = { x = 16, y = 54, w = gfx.w - 32, h = 36 }
    if cards_search_focused then gfx.set(0.20, 0.61, 0.83, 1); gfx.roundrect(16, 54, gfx.w - 32, 36, 6, 0) end
    gfx.setfont(1, "Arial", 19); gfx.set(0.94, 0.96, 0.99, 1)
    gfx.x, gfx.y = 27, 62; gfx.drawstr(query == "" and "Click to search categorized plugins..." or query)
    gfx.setfont(1, "Arial", 15); gfx.set(0.62, 0.70, 0.78, 1)
    gfx.x, gfx.y = gfx.w - 104, 64; gfx.drawstr(tostring(#list) .. " effects")
  else
    gfx.setfont(1, "Arial", 15); gfx.set(0.60, 0.68, 0.76, 1)
    gfx.x, gfx.y = 20, 65; gfx.drawstr("Search and page through the full scanned plugin list below")
    gfx.x, gfx.y = gfx.w - 104, 65; gfx.drawstr(tostring(#list) .. " effects")
  end
  draw_category_bars()
  local columns, page = 1, 1
  local library_list, library_visible, library_pages
  if view_mode == "library" then library_list, library_visible, library_pages = draw_library()
  else columns, page = draw_cards(list) end
  gfx.setfont(1, "Arial", 14); gfx.set(0.61, 0.67, 0.73, 1)
  gfx.x, gfx.y = 18, gfx.h - 23
  gfx.drawstr(view_mode == "library" and "Click the filter field to enter text • Previous/Next or mouse wheel browses all scan results • Add to category captures an image first • Esc closes" or "Click the search field to enter text • Click a card to insert and capture it • Right-click for image/category options • Use + to create categories • Esc closes")
  gfx.update()
  return list, columns, page, library_list, library_visible, library_pages
end

local function create_category_from_prompt(parent)
  local title = parent and ("New subcategory under " .. category_label(parent)) or "New main category"
  local ok, name = reaper.GetUserInputs(title, 1, "Name", "")
  if ok then create_category(name, parent) end
end

local function show_category_control(x, y)
  local target = active_category
  local options = { "New main category...", "New subcategory...", "Rename selected category...", "Delete selected category", "Auto-match artwork folder..." }
  if target == ALL or target == OTHER then options[3], options[4] = "#Rename selected category...", "#Delete selected category" end
  local choice = popup(table.concat(options, "|"), x, y)
  if choice == 1 then create_category_from_prompt(nil)
  elseif choice == 2 then
    local parent = category_parent(target) or target
    if parent == ALL or parent == OTHER then
      local mains, names = main_categories(), {}
      for _, name in ipairs(mains) do if name ~= ALL and name ~= OTHER then names[#names + 1] = name end end
      if #names > 0 then parent = names[popup(table.concat(names, "|"), x, y)] end
    end
    if parent and parent ~= ALL and parent ~= OTHER then create_category_from_prompt(parent) end
  elseif choice == 3 then
    local ok, name = reaper.GetUserInputs("Rename category", 1, "Name", category_name(target))
    if ok then rename_category(target, name) end
  elseif choice == 4 then delete_category(target)
  elseif choice == 5 then auto_match_images() end
end

local function manage_tab(path, x, y)
  active_category = path
  local options = { "Add subcategory...", "Rename...", "Delete..." }
  if path == ALL or path == OTHER then options[2], options[3] = "#Rename...", "#Delete..." end
  local choice = popup(table.concat(options, "|"), x, y)
  if choice == 1 then
    local parent = category_parent(path) or path
    if parent ~= ALL and parent ~= OTHER then create_category_from_prompt(parent) end
  elseif choice == 2 then
    local ok, name = reaper.GetUserInputs("Rename category", 1, "Name", category_name(path))
    if ok then rename_category(path, name) end
  elseif choice == 3 then delete_category(path) end
end

local function assignment_menu(fx, x, y)
  local options = { "Choose screenshot/image...", "Use metadata artwork", "#Add to category/subcategory" }
  for _, path in ipairs(categories) do
    if path ~= ALL then options[#options + 1] = (has_category(fx, path) and "!" or "") .. category_label(path) end
  end
  options[#options + 1] = "Auto-match artwork folder..."
  local choice = popup(table.concat(options, "|"), x, y)
  if choice == 1 then choose_image(fx)
  elseif choice == 2 then plugin_images[fx.ident] = nil; save_state()
  elseif choice >= 4 and choice < #options then toggle_category(fx, categories[choice - 2]); save_state()
  elseif choice == #options then auto_match_images() end
end

local function in_box(x, y, box)
  return box and x >= box.x and y >= box.y and x < box.x + box.w and y < box.y + box.h
end

local function loop()
  local list, columns, page, library_list, library_visible, library_pages = draw()
  local ch = gfx.getchar()
  if ch < 0 or ch == 27 then gfx.quit(); return end
  local selection_list = view_mode == "library" and library_list or list
  local search_is_library = library_search_focused or (view_mode == "library" and not cards_search_focused)
  if ch == 13 then
    if not library_search_focused and not cards_search_focused and selection_list and selection_list[selected] and insert_plugin(selection_list[selected]) then gfx.quit(); return end
  elseif ch == 8 then
    if search_is_library then library_query = library_query:sub(1, -2); library_page = 1
    else query = query:sub(1, -2) end
    selected, scroll = 1, 0
  elseif ch == 30064 then selected = math.max(1, selected - (view_mode == "library" and 1 or columns))
  elseif ch == 30065 then selected = math.min(#(selection_list or {}), selected + (view_mode == "library" and 1 or columns))
  elseif ch == 30066 then selected = math.max(1, selected - 1)
  elseif ch == 30067 then selected = math.min(#(selection_list or {}), selected + 1)
  elseif ch >= 32 and ch <= 255 then
    if search_is_library then library_query = library_query .. string.char(ch); library_page = 1
    else query = query .. string.char(ch) end
    selected, scroll = 1, 0
  end
  if #(selection_list or {}) == 0 then selected, scroll = 1, 0
  else
    local page_size = view_mode == "library" and library_visible or page
    if selected < scroll + 1 then scroll = selected - 1 end
    if selected > scroll + page_size then scroll = selected - page_size end
  end
  if view_mode == "library" and library_visible and library_visible > 0 then
    library_page = math.max(1, math.min(math.ceil(math.max(1, #(selection_list or {})) / library_visible), math.floor((selected - 1) / library_visible) + 1))
  end
  local wheel = gfx.mouse_wheel
  if wheel ~= 0 then
    if view_mode == "library" then
      library_page = math.max(1, math.min(library_pages or 1, library_page + (wheel > 0 and -1 or 1)))
      selected = math.min(#(selection_list or {}), (library_page - 1) * (library_visible or 1) + 1)
    else
      local max_scroll = math.max(0, #(selection_list or {}) - page)
      scroll = math.max(0, math.min(max_scroll, scroll - (wheel > 0 and columns or -columns)))
    end
    gfx.mouse_wheel = 0
  end

  local cap = gfx.mouse_cap
  local left = cap % 2 == 1 and last_mouse_cap % 2 == 0
  local right = math.floor(cap / 2) % 2 == 1 and math.floor(last_mouse_cap / 2) % 2 == 0
  last_mouse_cap = cap
  if left or right then
    local mx, my = gfx.mouse_x, gfx.mouse_y
    if left and in_box(mx, my, controls.cards_mode) then view_mode, scroll, selected = "cards", 0, 1; cards_search_focused, library_search_focused = true, false
    elseif left and in_box(mx, my, controls.library_mode) then view_mode, scroll, selected = "library", 0, 1; library_search_focused, cards_search_focused = true, false
    elseif left and in_box(mx, my, controls.library_search) then
      local value = prompt_for_search("Filter scanned plugins", library_query)
      if value ~= nil then library_query, library_page, selected, scroll = value, 1, 1, 0 end
      library_search_focused, cards_search_focused = false, false
    elseif left and in_box(mx, my, controls.cards_search) then
      local value = prompt_for_search("Search categorized plugins", query)
      if value ~= nil then query, selected, scroll = value, 1, 0 end
      library_search_focused, cards_search_focused = false, false
    elseif left and in_box(mx, my, controls.library_clear) then library_query, library_page, selected = "", 1, 1
    elseif left and in_box(mx, my, controls.library_prev) then library_page = math.max(1, library_page - 1); selected = (library_page - 1) * (library_visible or 1) + 1
    elseif left and in_box(mx, my, controls.library_next) then library_page = math.min(library_pages or 1, library_page + 1); selected = math.min(#(library_list or {}), (library_page - 1) * (library_visible or 1) + 1)
    elseif left and in_box(mx, my, controls.main_plus) then show_category_control(controls.main_plus.x, controls.main_plus.y + controls.main_plus.h)
    elseif left and in_box(mx, my, controls.sub_plus) then
      local parent = category_parent(active_category) or active_category
      if parent == ALL or parent == OTHER then show_category_control(controls.sub_plus.x, controls.sub_plus.y + controls.sub_plus.h)
      else create_category_from_prompt(parent) end
    elseif left and in_box(mx, my, controls.main_left) then main_scroll = math.max(0, main_scroll - 1)
    elseif left and in_box(mx, my, controls.main_right) then main_scroll = math.min(math.max(0, #main_categories() - #main_tabs), main_scroll + 1)
    elseif left and in_box(mx, my, controls.sub_left) then sub_scroll = math.max(0, sub_scroll - 1)
    elseif left and in_box(mx, my, controls.sub_right) then
      local parent = category_parent(active_category) or active_category
      local total_subtabs = (parent == ALL or parent == OTHER) and 0 or (#children_of(parent) + 1)
      sub_scroll = math.min(math.max(0, total_subtabs - #sub_tabs), sub_scroll + 1)
    else
      local hit_tab = false
      for _, tab in ipairs(main_tabs) do
        if in_box(mx, my, tab) then
          if right then manage_tab(tab.name, mx, my)
          else active_category, selected, scroll, sub_scroll = tab.name, 1, 0, 0 end
          hit_tab = true; break
        end
      end
      if not hit_tab then
        for _, tab in ipairs(sub_tabs) do
          if in_box(mx, my, tab) then
            if right then manage_tab(tab.name, mx, my)
            else active_category, selected, scroll = tab.name, 1, 0 end
            hit_tab = true; break
          end
        end
      end
      if not hit_tab and view_mode == "library" then
        for _, row in ipairs(library_layout) do
          if in_box(mx, my, row.categorize) and left then library_category_menu(row.fx, mx, my); break
          elseif in_box(mx, my, row.insert) and left then
            library_search_focused, cards_search_focused = false, false
            selected = row.index
            if insert_plugin(row.fx) then gfx.quit(); return end
            break
          elseif in_box(mx, my, row) and left then selected = row.index; break end
        end
      elseif not hit_tab and view_mode == "cards" then
        for _, card in ipairs(card_layout) do
          if in_box(mx, my, card) then
            if right then assignment_menu(card.fx, mx, my)
            elseif left then library_search_focused, cards_search_focused = false, false; selected = card.index; if insert_plugin(card.fx) then gfx.quit(); return end end
            break
          end
        end
      end
    end
  end
  reaper.defer(loop)
end

load_state()
refresh_plugins()
gfx.init(TITLE, WIDTH, HEIGHT, 0, 100, 60)
reaper.defer(loop)
