-- @description Open the subproject of each selected item in a new tab, with FX offline
-- @author Zibrat Studio
-- @version 1.2
-- @changelog
--   v1.2 + a project saved while FX were offline keeps its stored list when opened again
--   v1.1 + remembers which FX were online in the file, for "ZS_restore FX online state and save"
--   v1.0 + first version in the repository
-- @about
--   Opens every selected subproject in its own project tab with all FX offline,
--   so heavy subprojects load fast. Before opening, it reads the .rpp and stores
--   which FX were online. Run "ZS_restore FX online state and save" before saving:
--   it brings back only those FX, so FX that were offline in the file stay offline.
--   Needs REAPER with Main_openProject "fxoffline:" support.

local r = reaper
local EXT = "ZS_FXOFFLINE"

-- GUIDs of the FX that are online in the file. In an .rpp each FX has a
-- "BYPASS <bypassed> <offline> ..." line before it and an "FXID {guid}" line after it.
local function online_fx(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local guids, offline = {}, nil
  for line in f:lines() do
    local o = line:match("^%s*BYPASS %d+ (%d+)")
    if o then
      offline = o ~= "0"
    else
      local guid = line:match("^%s*FXID (%b{})")
      if guid then
        if offline == false then guids[#guids + 1] = guid end
        offline = nil
      end
    end
  end
  f:close()
  return guids
end

local function same_file(a, b)
  return a and b and a:gsub("\\", "/"):lower() == b:gsub("\\", "/"):lower()
end

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

local missed = {}
for _, p in ipairs(paths) do
  local guids = online_fx(p)
  r.Main_OnCommand(40859, 0)                       -- new project tab
  r.Main_openProject("noprompt:fxoffline:" .. p)   -- opens into that empty tab
  local proj, fn = r.EnumProjects(-1, "")
  local _, already = r.GetProjExtState(proj, EXT, "opened")
  if already == "1" and same_file(fn, p) then
    -- saved earlier while FX were offline: the file's own list is the true one, keep it
  elseif guids and same_file(fn, p) then
    r.SetProjExtState(proj, EXT, "opened", "1")
    r.SetProjExtState(proj, EXT, "online", table.concat(guids, " "))
  else
    missed[#missed + 1] = p
  end
end

if #missed > 0 then
  r.ShowMessageBox("Couldn't record the FX state for:\n" .. table.concat(missed, "\n") ..
    "\n\nDon't save these tabs before putting the right FX back online by hand.",
    "Open subproject (FX offline)", 0)
end
