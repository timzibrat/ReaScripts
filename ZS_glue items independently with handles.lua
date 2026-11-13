-- @description Glue selected items independently with handles (the edit stays in place)
-- @author Zibrat Studio
-- @version 1.0
-- @changelog
--   v1.0 + first version
-- @about
--   Glues every selected item on its own, with up to 4 s of extra source audio
--   rendered before and after the cut, then trims the glued item back to the
--   original edit. Position, length, fades, snap offset, take name and colours
--   stay as they were; drag the item edges out to reach the handles.
--   Handles are shorter where the source runs out. MIDI items are glued without
--   handles. Locked items are skipped.

------------------------------------------------------------------
-- SETTINGS
local HANDLE_S = 4   -- handle length on each side (seconds)
------------------------------------------------------------------

local GLUE = 40362          -- Item: Glue items, ignoring time selection
local UNSELECT_ALL = 40289  -- Item: Unselect all items

local FADE_KEYS = { "D_FADEINLEN", "D_FADEOUTLEN", "D_FADEINLEN_AUTO", "D_FADEOUTLEN_AUTO",
                    "C_FADEINSHAPE", "C_FADEOUTSHAPE", "D_FADEINDIR", "D_FADEOUTDIR" }

local function get(item, key) return reaper.GetMediaItemInfo_Value(item, key) end
local function set(item, key, v) reaper.SetMediaItemInfo_Value(item, key, v) end

-- How much source audio exists before and after the visible part, in project seconds
local function available_handles(take, len)
  if reaper.TakeIsMIDI(take) then return 0, 0 end
  local src = reaper.GetMediaItemTake_Source(take)
  local src_len, is_qn = reaper.GetMediaSourceLength(src)
  if is_qn then return 0, 0 end
  local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local before = math.max(0, offs / rate)
  local after = math.max(0, (src_len - offs) / rate - len)
  return math.min(HANDLE_S, before), math.min(HANDLE_S, after)
end

local function glue_with_handles(item)
  local take = reaper.GetActiveTake(item)
  if not take or get(item, "C_LOCK") ~= 0 then return nil end

  local pos, len = get(item, "D_POSITION"), get(item, "D_LENGTH")
  local pre, post = available_handles(take, len)

  -- remember what glue would change or bake in
  local fades = {}
  for _, k in ipairs(FADE_KEYS) do fades[k] = get(item, k) end
  local snap = get(item, "D_SNAPOFFSET")
  local item_color = get(item, "I_CUSTOMCOLOR")
  local take_color = reaper.GetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR")
  local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)

  -- no fades in the render, or the handles would come out silent
  for _, k in ipairs({ "D_FADEINLEN", "D_FADEOUTLEN", "D_FADEINLEN_AUTO", "D_FADEOUTLEN_AUTO" }) do
    set(item, k, 0)
  end

  -- open the item out into the handles
  if pre > 0 or post > 0 then
    local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", offs - pre * rate)
    set(item, "D_POSITION", pos - pre)
    set(item, "D_LENGTH", len + pre + post)
  end

  reaper.Main_OnCommand(UNSELECT_ALL, 0)
  reaper.SetMediaItemSelected(item, true)
  reaper.Main_OnCommand(GLUE, 0)
  local glued = reaper.GetSelectedMediaItem(0, 0)
  if not glued then return nil end
  local gtake = reaper.GetActiveTake(glued)

  -- trim back to the original edit; the glued file plays at rate 1 from its start
  set(glued, "D_POSITION", pos)
  set(glued, "D_LENGTH", len)
  if gtake then
    reaper.SetMediaItemTakeInfo_Value(gtake, "D_STARTOFFS", pre)
    reaper.GetSetMediaItemTakeInfo_String(gtake, "P_NAME", name, true)
    if take_color ~= 0 then reaper.SetMediaItemTakeInfo_Value(gtake, "I_CUSTOMCOLOR", take_color) end
  end
  for _, k in ipairs(FADE_KEYS) do set(glued, k, fades[k]) end
  set(glued, "D_SNAPOFFSET", snap)
  set(glued, "I_CUSTOMCOLOR", item_color)
  return glued
end

local items = {}
for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
  items[#items + 1] = reaper.GetSelectedMediaItem(0, i)
end
if #items == 0 then return end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local result = {}
for _, item in ipairs(items) do
  local glued = glue_with_handles(item)
  result[#result + 1] = glued or item
end

reaper.Main_OnCommand(UNSELECT_ALL, 0)
for _, item in ipairs(result) do
  if reaper.ValidatePtr(item, "MediaItem*") then reaper.SetMediaItemSelected(item, true) end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Glue items independently with " .. HANDLE_S .. " s handles", -1)
