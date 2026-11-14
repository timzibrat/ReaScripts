-- @description Restore the FX that were online before "open subproject (FX offline)"
-- @author Zibrat Studio
-- @version 2.0
-- @changelog
--   v2.0 + no longer saves; renamed from "ZS_restore FX online state and save"
--   v1.1 + closes the FX windows that reopen when an FX comes back online
--   v1.0 + first version
-- @about
--   For a project opened with "ZS_open selected subproject (FX offline, new tab)":
--   brings back online exactly the FX that were online in the file (track, master,
--   input and take FX) without opening their windows, and leaves the rest offline.
--   Does not save.

local r = reaper
local EXT = "ZS_FXOFFLINE"

local _, opened = r.GetProjExtState(0, EXT, "opened")
local _, list = r.GetProjExtState(0, EXT, "online")
if opened ~= "1" then
  r.ShowMessageBox("This project wasn't opened with the FX-offline script, so there's nothing to restore.",
    "Restore FX online state", 0)
  return
end

local want = {}
for guid in list:gmatch("%b{}") do want[guid] = true end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)

local restored = 0

-- Bringing an FX online reopens any window it had open when the file was saved:
-- close its floating window and the FX chain window right away.
local function online_track_fx(tr, idx)
  r.TrackFX_SetOffline(tr, idx, false)
  r.TrackFX_Show(tr, idx, 2)  -- hide floating window
  r.TrackFX_Show(tr, idx, 0)  -- hide FX chain window
  restored = restored + 1
end

local function track_fx(tr)
  for i = 0, r.TrackFX_GetCount(tr) - 1 do
    if want[r.TrackFX_GetFXGUID(tr, i)] then online_track_fx(tr, i) end
  end
  for i = 0, r.TrackFX_GetRecCount(tr) - 1 do  -- input FX
    local idx = 0x1000000 + i
    if want[r.TrackFX_GetFXGUID(tr, idx)] then online_track_fx(tr, idx) end
  end
end

track_fx(r.GetMasterTrack(0))
for t = 0, r.CountTracks(0) - 1 do track_fx(r.GetTrack(0, t)) end

for i = 0, r.CountMediaItems(0) - 1 do
  local item = r.GetMediaItem(0, i)
  for k = 0, r.CountTakes(item) - 1 do
    local tk = r.GetTake(item, k)
    if tk then
      for f = 0, r.TakeFX_GetCount(tk) - 1 do
        if want[r.TakeFX_GetFXGUID(tk, f)] then
          r.TakeFX_SetOffline(tk, f, false)
          r.TakeFX_Show(tk, f, 2)
          r.TakeFX_Show(tk, f, 0)
          restored = restored + 1
        end
      end
    end
  end
end

-- done: don't carry the list into the file on the next save
r.SetProjExtState(0, EXT, "opened", "")
r.SetProjExtState(0, EXT, "online", "")

r.PreventUIRefresh(-1)
r.Undo_EndBlock("Restore " .. restored .. " FX online", -1)
