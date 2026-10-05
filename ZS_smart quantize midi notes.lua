--[[
   * Category:    Arrange
   * Description: Quantize MIDI notes - razor areas, or selected items (whole item, or time selection)
   * Based on:    me2beats - Quantize MIDI note positions to project grid
   * Version:     1.1
   * Changelog:   v1.1 + razor edits (take priority over item selection)
   * Extension:   Reaper 6.2+
--]]

    --======================================================================================
    local STRENGTH = 100;  -- quantize strength in % (100 = snap to grid, 50 = halfway)
    local GRID     = 0;    -- 0 = project grid, or e.g. 1/16, 1/8, 1/12 (1/8 triplets), 1/4
    --======================================================================================


    -------------------------------------------------------
    local function no_undo()reaper.defer(function()end)end;
    -------------------------------------------------------


    -------------------------------------------------------
    -- Grid size in quarter notes
    local function GridQN();
        local div = GRID;
        if not div or div <= 0 then;
            local _,projDiv = reaper.GetSetProjectGrid(0,false);
            div = projDiv;
        end;
        return div*4;
    end;
    -------------------------------------------------------


    -------------------------------------------------------
    -- Quantize one take. With rStart/rEnd (project time), only notes starting inside that range
    local function QuantizeTake(take,gridQN,rStart,rEnd);
        local _,noteCnt = reaper.MIDI_CountEvts(take);
        if noteCnt == 0 then return 0 end;

        local rStartPPQ,rEndPPQ;
        if rStart then;
            rStartPPQ = reaper.MIDI_GetPPQPosFromProjTime(take,rStart);
            rEndPPQ   = reaper.MIDI_GetPPQPosFromProjTime(take,rEnd);
        end;

        local changed = 0;
        for i = 0,noteCnt-1 do;
            local _,sel,muted,s,e = reaper.MIDI_GetNote(take,i);
            if not rStart or (s >= rStartPPQ and s < rEndPPQ) then;
                local qn = reaper.MIDI_GetProjQNFromPPQPos(take,s);
                local gridPPQ = reaper.MIDI_GetPPQPosFromProjQN(take,math.floor(qn/gridQN+0.5)*gridQN);
                local newStart = math.floor(s + (gridPPQ-s)*STRENGTH/100 + 0.5);
                if newStart ~= s then;
                    reaper.MIDI_SetNote(take,i,nil,nil,newStart,newStart+(e-s),nil,nil,nil,true);
                    changed = changed+1;
                end;
            end;
        end;

        if changed > 0 then reaper.MIDI_Sort(take) end;
        return changed;
    end;
    -------------------------------------------------------


    -------------------------------------------------------
    -- Active MIDI take of an item, or nil
    local function MidiTake(item);
        local tk = item and reaper.GetActiveTake(item);
        if tk and reaper.TakeIsMIDI(tk) then return tk end;
    end;
    -------------------------------------------------------


    -------------------------------------------------------
    -- Jobs {take,s,e} from track-level razor edits; second value = whether any razor edit exists
    local function RazorJobs();
        local jobs,anyRazor = {},false;
        for t = 0,reaper.CountTracks(0)-1 do;
            local track = reaper.GetTrack(0,t);
            local _,str = reaper.GetSetMediaTrackInfo_String(track,'P_RAZOREDITS','',false);
            local ranges = {};
            for a,b,guid in str:gmatch('(%S+) (%S+) (%S+)') do;
                if guid == '""' then ranges[#ranges+1] = {tonumber(a),tonumber(b)} end;
            end;
            if #ranges > 0 then;
                anyRazor = true;
                for i = 0,reaper.CountTrackMediaItems(track)-1 do;
                    local item = reaper.GetTrackMediaItem(track,i);
                    local tk = MidiTake(item);
                    if tk then;
                        local pos = reaper.GetMediaItemInfo_Value(item,'D_POSITION');
                        local fin = pos + reaper.GetMediaItemInfo_Value(item,'D_LENGTH');
                        for _,r in ipairs(ranges) do;
                            if r[1] < fin and r[2] > pos then jobs[#jobs+1] = {take=tk,s=r[1],e=r[2]} end;
                        end;
                    end;
                end;
            end;
        end;
        return jobs,anyRazor;
    end;
    -------------------------------------------------------


    -------------------
    local jobs,useRazor = RazorJobs();
    local tsStart,tsEnd = reaper.GetSet_LoopTimeRange(false,false,0,0,false);
    local useTS = not useRazor and tsEnd > tsStart;

    if not useRazor then;
        for i = 0,reaper.CountSelectedMediaItems(0)-1 do;
            local tk = MidiTake(reaper.GetSelectedMediaItem(0,i));
            if tk then jobs[#jobs+1] = {take=tk,s=useTS and tsStart or nil,e=useTS and tsEnd or nil} end;
        end;
    end;
    if #jobs == 0 then no_undo() return end;
    local gridQN = GridQN();
    -------------------

    -------------------
    reaper.Undo_BeginBlock();
    reaper.PreventUIRefresh(1);
    -------------------

    for _,j in ipairs(jobs) do;
        QuantizeTake(j.take,gridQN,j.s,j.e);
    end;

    -------------------
    reaper.PreventUIRefresh(-1);
    reaper.UpdateArrange();
    reaper.Undo_EndBlock("Quantize notes ("..STRENGTH.."%)"..(useRazor and " - razor edits" or " - selected items")
                         ..(useTS and " (time selection)" or ""),-1);
    -------------------
