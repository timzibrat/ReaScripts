--[[
   * Category:    MIDI Inline Editor
   * Description: Legato with overlap - razor areas, else item under mouse, else selected items
   *              (whole item, or time selection)
   * Based on:    Archie - Set note ends to start of next note (legato)
   * Version:     1.0
   * Extension:   Reaper 6.2+
--]]

    --======================================================================================
    local OVERLAP_MS = 20; -- how far each note extends past the next note's start (milliseconds)
    local REPEAT_GAP_MS = 30; -- repeated notes (same pitch) end this much before the next one (milliseconds)
    --======================================================================================


    -------------------------------------------------------
    local function no_undo()reaper.defer(function()end)end;
    -------------------------------------------------------


    -------------------------------------------------------
    -- Legato + overlap on one take. Only unmuted notes starting inside the visible item
    -- and inside rStart..rEnd (project time; nil = whole item)
    local function LegatoTake(take,rStart,rEnd);
        local _,noteCnt = reaper.MIDI_CountEvts(take);
        if noteCnt == 0 then return 0 end;

        local item = reaper.GetMediaItemTake_Item(take);
        local itemPos = reaper.GetMediaItemInfo_Value(item,'D_POSITION');
        local itemEnd = itemPos + reaper.GetMediaItemInfo_Value(item,'D_LENGTH');
        local itemEndPPQ = reaper.MIDI_GetPPQPosFromProjTime(take,itemEnd);

        local rangeStart = math.max(itemPos,rStart or itemPos);
        local rangeEnd   = math.min(itemEnd,rEnd or itemEnd);
        if rangeEnd <= rangeStart then return 0 end;
        local rangeStartPPQ = reaper.MIDI_GetPPQPosFromProjTime(take,rangeStart);
        local rangeEndPPQ   = reaper.MIDI_GetPPQPosFromProjTime(take,rangeEnd);

        local targets,samePitch = {},{};
        for i = 0,noteCnt-1 do;
            local _,sel,muted,s,e,chan,pitch = reaper.MIDI_GetNote(take,i);
            if not muted then; -- muted notes are ignored completely
                local k = chan*128+pitch;
                samePitch[k] = samePitch[k] or {};
                samePitch[k][#samePitch[k]+1] = s;
                if s >= rangeStartPPQ and s < rangeEndPPQ then;
                    targets[#targets+1] = {idx=i,s=s,e=e,chan=chan,pitch=pitch};
                end;
            end;
        end;

        local starts = {};
        for _,n in ipairs(targets) do starts[#starts+1] = n.s end;
        table.sort(starts);

        local changed = 0;
        for _,n in ipairs(targets) do;
            local nextStart;
            for _,s in ipairs(starts) do;
                if s > n.s then nextStart = s break end;
            end;

            if nextStart then; -- last note of the group stays as is
                local t = reaper.MIDI_GetProjTimeFromPPQPos(take,nextStart);
                local newEnd = reaper.MIDI_GetPPQPosFromProjTime(take,t+OVERLAP_MS/1000);
                newEnd = math.floor(newEnd+0.5);
                -- overlap may not run past the item end
                newEnd = math.min(newEnd,itemEndPPQ);
                -- repeated note (same pitch/channel would be hit): no overlap, end REPEAT_GAP_MS early
                local repStart;
                for _,s in ipairs(samePitch[n.chan*128+n.pitch]) do;
                    if s > n.s and s < newEnd and (not repStart or s < repStart) then repStart = s end;
                end;
                if repStart then;
                    local rt = reaper.MIDI_GetProjTimeFromPPQPos(take,repStart);
                    newEnd = math.floor(reaper.MIDI_GetPPQPosFromProjTime(take,rt-REPEAT_GAP_MS/1000)+0.5);
                end;
                if newEnd > n.s and newEnd ~= n.e then;
                    reaper.MIDI_SetNote(take,n.idx,nil,nil,nil,newEnd,nil,nil,nil,true);
                    changed = changed+1;
                end;
            end;
        end;

        if changed > 0 then reaper.MIDI_Sort(take) end;
        return changed;
    end;
    -------------------------------------------------------


    -------------------------------------------------------
    -- Active MIDI take of an unmuted item, or nil
    local function MidiTake(item);
        if not item or reaper.GetMediaItemInfo_Value(item,'B_MUTE') ~= 0 then return end;
        local tk = reaper.GetActiveTake(item);
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
        local x,y = reaper.GetMousePosition();
        local tk = MidiTake((reaper.GetItemFromPoint(x,y,false)));
        if tk then;
            jobs[1] = {take=tk,s=useTS and tsStart,e=useTS and tsEnd};
        else;
            for i = 0,reaper.CountSelectedMediaItems(0)-1 do;
                tk = MidiTake(reaper.GetSelectedMediaItem(0,i));
                if tk then jobs[#jobs+1] = {take=tk,s=useTS and tsStart,e=useTS and tsEnd} end;
            end;
        end;
    end;
    if #jobs == 0 then no_undo() return end;
    -------------------

    -------------------
    reaper.Undo_BeginBlock();
    reaper.PreventUIRefresh(1);
    -------------------

    for _,j in ipairs(jobs) do;
        LegatoTake(j.take,j.s,j.e);
    end;

    -------------------
    reaper.PreventUIRefresh(-1);
    reaper.UpdateArrange();
    reaper.Undo_EndBlock("Legato with overlap"..(useRazor and " - razor edits" or " - inline editor")
                         ..(useTS and " (time selection)" or ""),-1);
    -------------------
