-- @description Toggle CC1 between MIDI item and an editable take envelope
-- @author Tim Žibrat (written with Claude)
-- @version 0.1
-- @about
--   Toolbar toggle. Press once: CC1 (mod wheel) events are cut out of the
--   selected MIDI items and turned into an envelope drawn right on the item
--   (a take FX envelope), so you can edit them in the arrange view.
--   The envelope still plays back as CC1 while you edit.
--   Press again: the envelope is printed back into the items as MIDI CC1
--   (point shapes/curves kept) and the helper FX is removed.
--
--   If ANY selected item is currently in "envelope mode", the press prints
--   all selected items back. Otherwise it sends all selected items to envelopes.

------------------------------------------------------------------
-- SETTINGS
local CC_NUM  = 11      -- controller to move (1 = mod wheel, 11 = expression ...)
------------------------------------------------------------------

local FX_TAG  = "CC Env Bridge"
local JS_DIR  = reaper.GetResourcePath() .. "/Effects/Tim"
local JS_FILE = JS_DIR .. "/cc_env_bridge.jsfx"
local EXT_KEY = "P_EXT:tim_ccbridge_chan"

-- Small JSFX that turns its slider into the CC, so playback works while editing
local JSFX = [[
desc:CC Env Bridge (Tim)
slider1:0<0,1,0.0001>CC value (0-1)
slider2:1<0,127,1>CC number
slider3:0<0,15,1>MIDI channel (0 = ch 1)
in_pin:none
out_pin:none

@init
last = -1;

@block
while (midirecv(ofs, m1, m2, m3)) (
  midisend(ofs, m1, m2, m3);
);
v = floor(slider1 * 127 + 0.5);
v != last ? (
  midisend(0, $xB0 + slider3, slider2, v);
  last = v;
);
]]

-- MIDI CC shapes and envelope shapes use different numbers for square/linear
local CC2ENV = { [0] = 1, [1] = 0, [2] = 2, [3] = 3, [4] = 4, [5] = 5 }
local ENV2CC = { [0] = 1, [1] = 0, [2] = 2, [3] = 3, [4] = 4, [5] = 5 }

local function ensure_jsfx()
  if reaper.file_exists(JS_FILE) then return true end
  reaper.RecursiveCreateDirectory(JS_DIR, 0)
  local f = io.open(JS_FILE, "w")
  if not f then return false end
  f:write(JSFX)
  f:close()
  return true
end

local function find_bridge(take)
  for i = 0, reaper.TakeFX_GetCount(take) - 1 do
    local _, name = reaper.TakeFX_GetFXName(take, i, "")
    if name:find(FX_TAG, 1, true) then return i end
  end
  return nil
end

local function show_envelope(env)
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if not ok then return end
  chunk = chunk:gsub("\nVIS %d+", "\nVIS 1", 1)
  reaper.SetEnvelopeStateChunk(env, chunk, false)
end

------------------------------------------------------------------
-- MIDI -> envelope
local function to_envelope(item, take)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local _, _, cc_cnt = reaper.MIDI_CountEvts(take)

  -- collect CC events (first channel found wins; other channels untouched)
  local chan, pts, idxs = nil, {}, {}
  for i = 0, cc_cnt - 1 do
    local _, _, _, ppq, chanmsg, ch, m2, m3 = reaper.MIDI_GetCC(take, i)
    if chanmsg == 0xB0 and m2 == CC_NUM and (chan == nil or ch == chan) then
      chan = ch
      local _, shape, tension = reaper.MIDI_GetCCShape(take, i)
      local t = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq) - item_pos
      pts[#pts + 1] = { t = t, v = m3 / 127, shape = CC2ENV[shape] or 0, tension = tension }
      idxs[#idxs + 1] = i
    end
  end
  chan = chan or 0

  -- cut them out of the item
  for k = #idxs, 1, -1 do reaper.MIDI_DeleteCC(take, idxs[k]) end

  -- add helper FX
  local fx = reaper.TakeFX_AddByName(take, "JS:Tim/cc_env_bridge.jsfx", -1)
  if fx < 0 then fx = reaper.TakeFX_AddByName(take, "JS: CC Env Bridge (Tim)", -1) end
  if fx < 0 then return false, "could not load the helper JSFX" end
  reaper.TakeFX_SetParam(take, fx, 1, CC_NUM)
  reaper.TakeFX_SetParam(take, fx, 2, chan)
  reaper.TakeFX_Show(take, fx, 2) -- make sure no floating window pops up

  -- build the envelope
  local env = reaper.TakeFX_GetEnvelope(take, fx, 0, true)
  if not env then return false, "could not create envelope" end
  reaper.DeleteEnvelopePointRange(env, -1e9, 1e9)
  if #pts == 0 then
    reaper.InsertEnvelopePoint(env, 0, 0, 0, 0, false, true)
  else
    for _, p in ipairs(pts) do
      reaper.InsertEnvelopePoint(env, p.t, p.v, p.shape, p.tension, false, true)
    end
  end
  reaper.Envelope_SortPoints(env)
  show_envelope(env)

  reaper.GetSetMediaItemTakeInfo_String(take, EXT_KEY, tostring(chan), true)
  return true
end

------------------------------------------------------------------
-- envelope -> MIDI
local function to_midi(item, take, fx)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local env = reaper.TakeFX_GetEnvelope(take, fx, 0, false)
  local _, chan_str = reaper.GetSetMediaItemTakeInfo_String(take, EXT_KEY, "", false)
  local chan = tonumber(chan_str) or 0

  -- remove any CCs of this number that crept in meanwhile
  local _, _, cc_cnt = reaper.MIDI_CountEvts(take)
  for i = cc_cnt - 1, 0, -1 do
    local _, _, _, _, chanmsg, ch, m2 = reaper.MIDI_GetCC(take, i)
    if chanmsg == 0xB0 and m2 == CC_NUM and ch == chan then reaper.MIDI_DeleteCC(take, i) end
  end

  if env then
    local shapes = {}
    reaper.MIDI_DisableSort(take)
    for i = 0, reaper.CountEnvelopePointsEx(env, -1) - 1 do
      local _, t, v, shape, tension = reaper.GetEnvelopePointEx(env, -1, i)
      local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_pos + t)
      local val = math.max(0, math.min(127, math.floor(v * 127 + 0.5)))
      reaper.MIDI_InsertCC(take, false, false, ppq, 0xB0, chan, CC_NUM, val)
      shapes[math.floor(ppq + 0.5)] = { ENV2CC[shape] or 1, tension }
    end
    reaper.MIDI_Sort(take)

    -- restore curve shapes
    _, _, cc_cnt = reaper.MIDI_CountEvts(take)
    for i = 0, cc_cnt - 1 do
      local _, _, _, ppq, chanmsg, ch, m2 = reaper.MIDI_GetCC(take, i)
      if chanmsg == 0xB0 and m2 == CC_NUM and ch == chan then
        local s = shapes[math.floor(ppq + 0.5)]
        if s then reaper.MIDI_SetCCShape(take, i, s[1], s[2], true) end
      end
    end
    reaper.MIDI_Sort(take)
  end

  reaper.TakeFX_Delete(take, fx) -- also removes its envelope
  reaper.GetSetMediaItemTakeInfo_String(take, EXT_KEY, "", true)
  return true
end

------------------------------------------------------------------
-- main
local function main()
  local n = reaper.CountSelectedMediaItems(0)
  if n == 0 then return end
  if not ensure_jsfx() then
    reaper.MB("Couldn't write the helper JSFX to:\n" .. JS_FILE, "CC toggle", 0)
    return
  end

  -- gather MIDI items, decide direction
  local items, any_env = {}, false
  for i = 0, n - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local fx = find_bridge(take)
      if fx then any_env = true end
      items[#items + 1] = { item = item, take = take, fx = fx }
    end
  end

  local skipped = 0
  for _, e in ipairs(items) do
    local rate = reaper.GetMediaItemTakeInfo_Value(e.take, "D_PLAYRATE")
    if math.abs(rate - 1) > 1e-9 then
      skipped = skipped + 1
    elseif any_env then
      if e.fx then to_midi(e.item, e.take, e.fx) end
    else
      to_envelope(e.item, e.take)
    end
    reaper.UpdateItemInProject(e.item)
  end

  -- toolbar button state
  local _, _, sec, cmd = reaper.get_action_context()
  reaper.SetToggleCommandState(sec, cmd, any_env and 0 or 1)
  reaper.RefreshToolbar2(sec, cmd)

  if skipped > 0 then
    reaper.MB(skipped .. " item(s) skipped because their playrate isn't 1.0.", "CC toggle", 0)
  end
  return any_env
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
local was_env = main()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock(was_env and ("Print CC" .. CC_NUM .. " envelope back to MIDI")
                              or ("Move CC" .. CC_NUM .. " to take envelope"), -1)

