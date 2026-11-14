-- @description Open the subproject of each selected item in a new tab, with FX offline
-- @author Zibrat Studio
-- @version 1.0
-- @changelog
--   v1.0 + first version in the repository
-- @about
--   Opens every selected subproject in its own project tab with all FX offline,
--   so heavy subprojects load fast. Needs REAPER with Main_openProject "fxoffline:" support.

local r = reaper
local n = r.CountSelectedMediaItems(0)
local paths, seen = {}, {}
for i = 0, n - 1 do
  local it = r.GetSelectedMediaItem(0, i)
  local tk = it and r.GetActiveTake(it)
  local src = tk and r.GetMediaItemTake_Source(tk)
  if src then
    local typ = r.GetMediaSourceType(src, "")
    local fn = r.GetMediaSourceFileName(src, "")
    if (typ == "RPP_PROJECT" or fn:lower():match("%.rpp$")) and not seen[fn] then
      seen[fn] = true; paths[#paths + 1] = fn
    end
  end
end
if #paths == 0 then
  r.ShowMessageBox("Select a subproject item first.", "Open subproject (FX offline)", 0)
  return
end
for _, p in ipairs(paths) do
  r.Main_OnCommand(40859, 0)                       -- new project tab
  r.Main_openProject("noprompt:fxoffline:" .. p)   -- opens into that empty tab
end
