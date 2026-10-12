-- @description Toggle the master track between stereo and 5.1 (channel count + hardware output)
-- @author Zibrat Studio
-- @version 1.0
-- @about
--   Stereo: master has 2 channels, hardware output 1-2.
--   5.1:    master has 6 channels, hardware output 1-6.
--   The current state is read from the master's channel count.
--   Put it on a toolbar: the button is lit while the master is in 5.1.

------------------------------------------------------------------
-- SETTINGS
local STEREO_CH   = 2
local SURROUND_CH = 6
local FIRST_OUT   = 1   -- hardware output the master starts on (1 = outputs 1-2 / 1-6)
------------------------------------------------------------------

local HW_OUT = 1  -- send category: hardware outputs

-- I_SRCCHAN: low 10 bits = first source channel, bits above = width
-- (0 = stereo, 1 = mono, 2 = 4 ch, 3 = 6 ch ...)
local function src_chan(channels)
  if channels == 2 then return 0 end
  return (channels // 2) << 10
end

local function toggle()
  local master = reaper.GetMasterTrack(0)
  local to51 = reaper.GetMediaTrackInfo_Value(master, "I_NCHAN") < SURROUND_CH
  local ch = to51 and SURROUND_CH or STEREO_CH

  if reaper.GetTrackNumSends(master, HW_OUT) == 0 then
    reaper.CreateTrackSend(master, nil)
  end

  reaper.SetMediaTrackInfo_Value(master, "I_NCHAN", ch)
  reaper.SetTrackSendInfo_Value(master, HW_OUT, 0, "I_SRCCHAN", src_chan(ch))
  reaper.SetTrackSendInfo_Value(master, HW_OUT, 0, "I_DSTCHAN", FIRST_OUT - 1)
  return to51
end

reaper.Undo_BeginBlock()
local is51 = toggle()
reaper.Undo_EndBlock(is51 and "Master to 5.1 (6 ch, out 1-6)" or "Master to stereo (2 ch, out 1-2)", -1)

local _, _, section, cmd = reaper.get_action_context()
reaper.SetToggleCommandState(section, cmd, is51 and 1 or 0)
reaper.RefreshToolbar2(section, cmd)
