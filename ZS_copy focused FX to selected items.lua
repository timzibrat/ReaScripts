-- @description Copy the focused FX (floating window) to the selected items, or to the selected tracks
-- @author Zibrat Studio
-- @version 1.0
-- @changelog
--   v1.0 + first version
-- @about
--   Click an FX in the Project Bay (or any floating FX window), select the target
--   items, run this: the FX is copied with its current settings to the end of each
--   selected item's active take FX chain. With no item selected, it goes to the
--   selected tracks instead. Works for track FX and item FX as the source.

local r = reaper

local function msg(t) r.ShowMessageBox(t, "Copy focused FX", 0) end

-- The last focused FX window; it stays known after clicking an item, as long as it's open
local ok, trackidx, itemidx, takeidx, fxidx = r.GetTouchedOrFocusedFX(1)
if not ok then msg("Click an FX window first (e.g. an FX in the Project Bay).") return end

local src_track = trackidx == -1 and r.GetMasterTrack(0) or r.GetTrack(0, trackidx)
if not src_track then msg("Couldn't find the FX's track.") return end

local src_take
if itemidx >= 0 then
  local item = r.GetTrackMediaItem(src_track, itemidx)
  src_take = item and r.GetTake(item, takeidx)
  if not src_take then msg("Couldn't find the FX's item.") return end
end

local function copy_to_take(dest)
  if src_take then
    if dest == src_take then return false end
    r.TakeFX_CopyToTake(src_take, fxidx, dest, r.TakeFX_GetCount(dest), false)
  else
    r.TrackFX_CopyToTake(src_track, fxidx, dest, r.TakeFX_GetCount(dest), false)
  end
  return true
end

local function copy_to_track(dest)
  if src_take then
    r.TakeFX_CopyToTrack(src_take, fxidx, dest, r.TrackFX_GetCount(dest), false)
  else
    if dest == src_track then return false end
    r.TrackFX_CopyToTrack(src_track, fxidx, dest, r.TrackFX_GetCount(dest), false)
  end
  return true
end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)

local copied, target = 0, "items"
local n_items = r.CountSelectedMediaItems(0)
if n_items > 0 then
  for i = 0, n_items - 1 do
    local take = r.GetActiveTake(r.GetSelectedMediaItem(0, i))
    if take and copy_to_take(take) then copied = copied + 1 end
  end
else
  target = "tracks"
  for i = 0, r.CountSelectedTracks(0) - 1 do
    if copy_to_track(r.GetSelectedTrack(0, i)) then copied = copied + 1 end
  end
end

r.PreventUIRefresh(-1)
r.Undo_EndBlock("Copy focused FX to " .. copied .. " selected " .. target, -1)

if copied == 0 then msg("Select the items (or tracks) to copy the FX to.") end
