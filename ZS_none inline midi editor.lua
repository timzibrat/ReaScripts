-- @description Open the MIDI item under the mouse (or the selected items) in the inline editor with no CC lanes (notes only)
-- @author Tim Žibrat (written with Claude)
-- @version 0.3
-- @changelog
--   v0.3 + works on the item under the mouse; falls back to selected items
-- @about
--   For the MIDI item under the mouse (or, with the mouse over no item, each
--   selected MIDI item): hides every lane (velocity and all CCs) so
--   the whole inline editor is piano roll, makes the track tall enough to
--   work in, then opens the inline editor.

------------------------------------------------------------------
-- SETTINGS
local MIN_TRACK_PX   = 300   -- track is raised to at least this height (0 = leave as is)
local EDITOR_LANE_PX = 120   -- velocity lane height in the full MIDI editor, if you open it later
------------------------------------------------------------------

local OPEN_INLINE  = 40847  -- Item: Open item inline editors
local UNSELECT_ALL = 40289  -- Item: Unselect all items

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

-- An item with no lane entries makes REAPER fall back to the last remembered
-- lanes, so instead we keep exactly one lane (velocity) at zero inline height.
local function clear_lanes(item)
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
  local line = string.format("VELLANE -1 %d 0%s", EDITOR_LANE_PX, extra)

  chunk = chunk:gsub("\nVELLANE[^\n]*", "")
  local new, n = chunk:gsub("\nCFGEDITVIEW", "\n" .. line .. "\nCFGEDITVIEW", 1)
  if n == 0 then new, n = chunk:gsub("\nCFGEDIT", "\n" .. line .. "\nCFGEDIT", 1) end
  if n == 0 then new, n = chunk:gsub("(\n<SOURCE MIDI[^\n]*)", "%1\n" .. line, 1) end
  if n > 0 then reaper.SetItemStateChunk(item, new, false) end
end

local function main()
  local items, at_mouse = target_items()
  if #items == 0 then return end

  local label = reaper.kbd_getTextFromCmd(OPEN_INLINE, 0) or ""
  if not label:lower():find("inline") then
    reaper.MB("Action " .. OPEN_INLINE .. " isn't 'open inline editor' in this REAPER version.\n" ..
              "Find the right ID in the Actions list and edit OPEN_INLINE in the script.", "Notes-only inline", 0)
    return
  end

  local done_tracks = {}
  for _, item in ipairs(items) do
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local track = reaper.GetMediaItem_Track(item)
      if MIN_TRACK_PX > 0 and not done_tracks[track] then
        if reaper.GetMediaTrackInfo_Value(track, "I_TCPH") < MIN_TRACK_PX then
          reaper.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", MIN_TRACK_PX)
        end
        done_tracks[track] = true
      end
      clear_lanes(item)
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
reaper.Undo_EndBlock("Open inline editor with no CC lanes", -1)

