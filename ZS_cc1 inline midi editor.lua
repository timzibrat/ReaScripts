-- @description Open the MIDI item under the mouse (or the selected items) in the inline editor showing only CC1, enlarged
-- @author Tim Žibrat (written with Claude)
-- @version 0.3
-- @changelog
--   v0.3 + works on the item under the mouse; falls back to selected items
-- @about
--   For the MIDI item under the mouse (or, with the mouse over no item, each
--   selected MIDI item): sets its CC lanes to just CC1 (velocity and
--   all other lanes hidden), makes the CC1 lane take a large share of the
--   inline editor, makes the track tall enough to work in, then opens the
--   inline editor.

------------------------------------------------------------------
-- SETTINGS
local CC_NUM        = 1     -- lane to show (1 = mod wheel, 11 = expression, -1 = velocity)
local LANE_FRACTION = 0.65  -- CC lane height as share of the track height (0.65 = 65 %)
local MIN_TRACK_PX  = 300   -- track is raised to at least this height (0 = leave as is)
local EDITOR_LANE_PX = 120  -- lane height in the full MIDI editor, if you open it later
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

local function set_lanes(item, inline_px)
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
  local line = string.format("VELLANE %d %d %d%s", CC_NUM, EDITOR_LANE_PX, inline_px, extra)

  -- remove all lanes, then insert ours
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
              "Find the right ID in the Actions list and edit OPEN_INLINE in the script.", "CC1 inline", 0)
    return
  end

  local done_tracks = {}
  for _, item in ipairs(items) do
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local track = reaper.GetMediaItem_Track(item)
      -- work out the final track height ourselves: reading it back after
      -- raising it returns the old value while UI refresh is paused
      local h = done_tracks[track]
      if not h then
        h = reaper.GetMediaTrackInfo_Value(track, "I_TCPH")
        if MIN_TRACK_PX > 0 and h < MIN_TRACK_PX then
          reaper.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", MIN_TRACK_PX)
          h = MIN_TRACK_PX
        end
        done_tracks[track] = h
      end
      set_lanes(item, math.max(40, math.floor(h * LANE_FRACTION)))
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
reaper.Undo_EndBlock("Open inline editor with only CC" .. CC_NUM, -1)

