-- @description Open the MIDI item under the mouse (or the selected items) in the inline editor showing only the CC lanes that contain data, minus an exclude list
-- @author Tim Žibrat (written with Claude)
-- @version 0.2
-- @changelog
--   v0.2 + works on the item under the mouse; falls back to selected items
-- @about
--   Like "SWS/FNG: Show only used CC lanes", but for the inline editor and
--   with exceptions. For the MIDI item under the mouse (or, with the mouse
--   over no item, each selected MIDI item), the script scans the item
--   for CC, pitch bend, program change and channel pressure data, shows a
--   lane for each type it finds (except the ones in EXCLUDE), splits the
--   space between them, then opens the inline editor.

------------------------------------------------------------------
-- SETTINGS
-- Lanes you never want this script to show, even if they contain data.
-- CC numbers 0-127, or the words "pitch", "program", "pressure".
local EXCLUDE = {  }            -- e.g. { 1, 11, 64, "pitch" }

local SHOW_VELOCITY  = false     -- true = always add the velocity lane on top
local LANES_FRACTION = 0.55      -- all lanes together, as share of the track height
local MIN_LANE_PX    = 40        -- no lane gets smaller than this
local MIN_TRACK_PX   = 300       -- track is raised to at least this height (0 = leave as is)
local EDITOR_LANE_PX = 80        -- per-lane height in the full MIDI editor, if you open it later
------------------------------------------------------------------

local OPEN_INLINE  = 40847       -- Item: Open item inline editors
local UNSELECT_ALL = 40289       -- Item: Unselect all items

-- The MIDI item under the mouse wins (a non-MIDI item there means nothing to do);
-- with the mouse over no item, the selected items are used
local function target_items()
  local x, y = reaper.GetMousePosition()
  local item = reaper.GetItemFromPoint(x, y, false)
  if item then
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then return { item }, true end
    return {}, true
  end
  local items = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    items[#items + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  return items, false
end

-- The open-inline action works on selected items, so select only this one
-- for it and put the user's selection back afterwards
local function open_inline_only(item)
  local sel = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    sel[#sel + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  reaper.Main_OnCommand(UNSELECT_ALL, 0)
  reaper.SetMediaItemSelected(item, true)
  reaper.Main_OnCommand(OPEN_INLINE, 0)
  reaper.Main_OnCommand(UNSELECT_ALL, 0)
  for _, it in ipairs(sel) do reaper.SetMediaItemSelected(it, true) end
end

-- REAPER lane numbers: 0-127 = CC, 128 = pitch bend, 129 = program, 130 = channel pressure
local NAMED = { pitch = 128, program = 129, pressure = 130 }
local MSG_LANE = { [0xE0] = 128, [0xC0] = 129, [0xD0] = 130 }

local excluded = {}
for _, v in ipairs(EXCLUDE) do
  local lane = type(v) == "number" and v or NAMED[tostring(v):lower()]
  if lane then excluded[lane] = true end
end

local function used_lanes(take)
  local found = {}
  local _, _, cc_cnt = reaper.MIDI_CountEvts(take)
  for i = 0, cc_cnt - 1 do
    local _, _, _, _, chanmsg, _, m2 = reaper.MIDI_GetCC(take, i)
    local lane = (chanmsg == 0xB0) and m2 or MSG_LANE[chanmsg]
    if lane and not excluded[lane] then found[lane] = true end
  end
  local list = {}
  for lane in pairs(found) do list[#list + 1] = lane end
  table.sort(list)
  return list
end

local function set_lanes(item, lanes, inline_px)
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then return end

  -- keep extra fields of an existing VELLANE line (format varies by version)
  local template = chunk:match("\n(VELLANE[^\n]*)")
  local extra = ""
  if template then
    local fields = {}
    for f in template:gmatch("%S+") do fields[#fields + 1] = f end
    for i = 5, #fields do extra = extra .. " " .. fields[i] end
  end

  local lines = {}
  for _, lane in ipairs(lanes) do
    lines[#lines + 1] = string.format("VELLANE %d %d %d%s", lane, EDITOR_LANE_PX, inline_px, extra)
  end
  if #lines == 0 then
    -- nothing to show: one velocity lane at zero height (an empty list
    -- would make REAPER fall back to the last remembered lanes)
    lines[1] = string.format("VELLANE -1 %d 0%s", EDITOR_LANE_PX, extra)
  end
  local block = table.concat(lines, "\n")

  chunk = chunk:gsub("\nVELLANE[^\n]*", "")
  local new, n = chunk:gsub("\nCFGEDITVIEW", "\n" .. block .. "\nCFGEDITVIEW", 1)
  if n == 0 then new, n = chunk:gsub("\nCFGEDIT", "\n" .. block .. "\nCFGEDIT", 1) end
  if n == 0 then new, n = chunk:gsub("(\n<SOURCE MIDI[^\n]*)", "%1\n" .. block, 1) end
  if n > 0 then reaper.SetItemStateChunk(item, new, false) end
end

local function main()
  local items, at_mouse = target_items()
  if #items == 0 then return end

  local label = reaper.kbd_getTextFromCmd(OPEN_INLINE, 0) or ""
  if not label:lower():find("inline") then
    reaper.MB("Action " .. OPEN_INLINE .. " isn't 'open inline editor' in this REAPER version.\n" ..
              "Find the right ID in the Actions list and edit OPEN_INLINE in the script.", "Used CC lanes", 0)
    return
  end

  local track_h = {}
  for _, item in ipairs(items) do
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local lanes = used_lanes(take)
      if SHOW_VELOCITY then table.insert(lanes, 1, -1) end

      -- final track height, worked out here (reading it back after raising
      -- it returns the old value while UI refresh is paused)
      local track = reaper.GetMediaItem_Track(item)
      local h = track_h[track]
      if not h then
        h = reaper.GetMediaTrackInfo_Value(track, "I_TCPH")
        if MIN_TRACK_PX > 0 and h < MIN_TRACK_PX then
          reaper.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", MIN_TRACK_PX)
          h = MIN_TRACK_PX
        end
        track_h[track] = h
      end

      local per_lane = 0
      if #lanes > 0 then
        per_lane = math.max(MIN_LANE_PX, math.floor(h * LANES_FRACTION / #lanes))
      end
      set_lanes(item, lanes, per_lane)
    end
  end

  if at_mouse then open_inline_only(items[1]) else reaper.Main_OnCommand(OPEN_INLINE, 0) end
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
main()
reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Open inline editor with used CC lanes", -1)

