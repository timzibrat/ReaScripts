-- @description Split the reverb (send) tracks used by the selected tracks into private copies above them
-- @author Zibrat Studio
-- @version 1.0
-- @changelog First version
-- @about
--   For moving part of a section into a subproject together with its reverb.
--   For every track the selected tracks send to (e.g. a shared reverb):
--     1. Duplicates it (FX chain, settings, its own outgoing sends) right above
--        the topmost selected track. No items, no other receives.
--     2. Moves the sends from the selected tracks onto the copy, with all
--        send settings and send automation kept exactly.
--   The original keeps receiving from everything else.
--   Afterwards the selected tracks + the copies are selected, so you can run
--   "Move tracks to subproject" straight away.

------------------------------------------------------------------
-- SETTINGS
local NAME_SUFFIX = " (sub)"   -- added to the copy's name. "" = same name.
------------------------------------------------------------------

local GUID_PATTERN = "{%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x}"

local function track_index(tr)
  return math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 1
end

-- Receives from the selected tracks = AUXRECV line + its envelope blocks.
-- for_copy = false: the original, minus those receives.
-- for_copy = true:  the copy, with only those receives, no items, not a folder.
local function split_chunk(chunk, src_set, for_copy)
  local keep, moved = {}, {}
  local depth = 0
  local owner = nil      -- nil / "moved" / "keep" for the current top-level block
  local in_item = false

  for line in chunk:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    local target = keep

    if depth == 1 then
      local src = trimmed:match("^AUXRECV%s+(%d+)")
      if src then
        owner = src_set[tonumber(src)] and "moved" or "keep"
      elseif trimmed:match("^<AUX%u*ENV") then
        -- envelope block of the last AUXRECV: same owner
      else
        owner = nil
      end
      in_item = for_copy and trimmed:match("^<ITEM") ~= nil
      if for_copy and trimmed:match("^ISBUS") then line = "ISBUS 0 0" end
    end

    if in_item then
      target = nil
    elseif owner == "moved" then
      target = for_copy and keep or moved   -- the copy keeps them in place
    elseif owner == "keep" and for_copy then
      target = nil          -- the copy only keeps receives from the selected tracks
    end

    if target then target[#target + 1] = line end

    if trimmed:sub(1, 1) == "<" then
      depth = depth + 1
    elseif trimmed == ">" then
      depth = depth - 1
      if depth == 1 then in_item = false end
    end
  end
  return keep, moved
end

local function copy_outgoing_sends(from, to)
  local params = { "D_VOL", "D_PAN", "D_PANLAW", "B_MUTE", "B_PHASE", "B_MONO",
                   "I_SENDMODE", "I_AUTOMODE", "I_SRCCHAN", "I_DSTCHAN", "I_MIDIFLAGS" }
  for i = 0, reaper.GetTrackNumSends(from, 0) - 1 do
    local dest = reaper.GetTrackSendInfo_Value(from, 0, i, "P_DESTTRACK")
    local n = reaper.CreateTrackSend(to, dest)
    for _, p in ipairs(params) do
      reaper.SetTrackSendInfo_Value(to, 0, n, p, reaper.GetTrackSendInfo_Value(from, 0, i, p))
    end
  end
end

local function main()
  local sel = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    sel[#sel + 1] = reaper.GetSelectedTrack(0, i)
  end
  if #sel == 0 then return end

  local is_sel = {}
  for _, tr in ipairs(sel) do is_sel[tr] = true end

  -- Destinations the selected tracks send to (not other selected tracks)
  local dests, seen = {}, {}
  for _, tr in ipairs(sel) do
    for i = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      local d = reaper.GetTrackSendInfo_Value(tr, 0, i, "P_DESTTRACK")
      if not is_sel[d] and not seen[d] then
        seen[d] = true
        dests[#dests + 1] = d
      end
    end
  end
  if #dests == 0 then
    reaper.MB("The selected tracks have no sends to split.", "Split reverb send", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local copies = {}
  for _, dest in ipairs(dests) do
    -- Insert above the topmost selected track (indices shift every time)
    local top = math.huge
    for _, tr in ipairs(sel) do top = math.min(top, track_index(tr)) end
    reaper.InsertTrackAtIndex(top, false)
    local copy = reaper.GetTrack(0, top)

    -- Source indices as they are now, after the insert
    local src_set = {}
    for _, tr in ipairs(sel) do src_set[track_index(tr)] = true end

    local _, chunk = reaper.GetTrackStateChunk(dest, "", false)
    local rest = split_chunk(chunk, src_set, false)
    local copy_lines = split_chunk(chunk, src_set, true)

    -- Copy: fresh GUIDs everywhere so Reaper treats it as a new track
    local copy_chunk = table.concat(copy_lines, "\n"):gsub(GUID_PATTERN, function()
      return reaper.genGuid("")
    end)

    reaper.SetTrackStateChunk(copy, copy_chunk, false)
    reaper.SetTrackStateChunk(dest, table.concat(rest, "\n"), false)

    local _, name = reaper.GetSetMediaTrackInfo_String(dest, "P_NAME", "", false)
    reaper.GetSetMediaTrackInfo_String(copy, "P_NAME", name .. NAME_SUFFIX, true)

    copy_outgoing_sends(dest, copy)
    copies[#copies + 1] = copy
  end

  -- Select the tracks + copies, ready for "Move tracks to subproject"
  for _, c in ipairs(copies) do reaper.SetTrackSelected(c, true) end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Split reverb send for selected tracks", -1)
end

main()
