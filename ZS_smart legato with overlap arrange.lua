--[[
   * Category:    Arrange + MIDI Inline Editor
   * Description: Legato with overlap - selected notes, razor areas, time selection or selected items
   * Based on:    Archie - Set note ends to start of next note (legato)
   * Version:     1.4
   * Changelog:   v1.4 + selected notes only count when run from the inline editor
   *                     (leftover selections hijacked razor / time selection in arrange)
   *              v1.3 + one script for arrange and the inline editor
   *                   + priority: selected notes > razor areas > time selection > selected items
   *                   + with no item selected, the item under the mouse is used
   *              v1.2 + razor edits (take priority over item selection)
   *                   + ignore muted notes, muted items and notes outside the visible item
   *              v1.1 + repeated notes get no overlap; they end 30 ms before the next note
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
    -- and inside rStart..rEnd (project time; nil = whole item); with selOnly, only selected notes
    local function LegatoTake(take,rStart,rEnd,selOnly);
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
                if s >= rangeStartPPQ and s < rangeEndPPQ and (sel or not selOnly) then;
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
    -- What to work on, first match wins:
    -- 1. selected notes, in the selected items or the item under the mouse (inline editor only)
    -- 2. razor areas with MIDI items under them
    -- 3. time selection, on the selected items inside it
    -- 4. the selected items, whole (no item selected: the item under the mouse)
    -- Returns jobs {take,s,e,selOnly} and a label for the undo point
    local function GetJobs();
        local selItems = {};
        for i = 0,reaper.CountSelectedMediaItems(0)-1 do;
            local item = reaper.GetSelectedMediaItem(0,i);
            if MidiTake(item) then selItems[#selItems+1] = item end;
        end;
        local x,y = reaper.GetMousePosition();
        local mouseItem = reaper.GetItemFromPoint(x,y,false);
        if not MidiTake(mouseItem) then mouseItem = nil end;
        local baseItems = selItems;
        if #baseItems == 0 and mouseItem then baseItems = {mouseItem} end;

        local jobs = {};

        -- 1. selected notes, only when run from the inline editor: Reaper keeps notes selected
        -- after the editor closes, and in arrange that leftover selection is invisible
        local _,_,section = reaper.get_action_context();
        if section == 32062 then; -- MIDI Inline Editor action section
            local noteItems = {table.unpack(selItems)};
            if mouseItem and not reaper.IsMediaItemSelected(mouseItem) then noteItems[#noteItems+1] = mouseItem end;
            for _,item in ipairs(noteItems) do;
                local tk = MidiTake(item);
                if reaper.MIDI_EnumSelNotes(tk,-1) ~= -1 then jobs[#jobs+1] = {take=tk,selOnly=true} end;
            end;
            if #jobs > 0 then return jobs,"selected notes" end;
        end;

        -- 2. razor areas (track-level only; envelope razor edits are skipped)
        for t = 0,reaper.CountTracks(0)-1 do;
            local track = reaper.GetTrack(0,t);
            local _,str = reaper.GetSetMediaTrackInfo_String(track,'P_RAZOREDITS','',false);
            local ranges = {};
            for a,b,guid in str:gmatch('(%S+) (%S+) (%S+)') do;
                if guid == '""' then ranges[#ranges+1] = {tonumber(a),tonumber(b)} end;
            end;
            for i = 0,(#ranges > 0 and reaper.CountTrackMediaItems(track) or 0)-1 do;
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
        if #jobs > 0 then return jobs,"razor edits" end;

        -- 3. time selection on the selected items inside it
        local tsStart,tsEnd = reaper.GetSet_LoopTimeRange(false,false,0,0,false);
        if tsEnd > tsStart then;
            for _,item in ipairs(baseItems) do;
                local pos = reaper.GetMediaItemInfo_Value(item,'D_POSITION');
                local fin = pos + reaper.GetMediaItemInfo_Value(item,'D_LENGTH');
                if pos < tsEnd and fin > tsStart then jobs[#jobs+1] = {take=MidiTake(item),s=tsStart,e=tsEnd} end;
            end;
            if #jobs > 0 then return jobs,"time selection" end;
        end;

        -- 4. whole items
        for _,item in ipairs(baseItems) do jobs[#jobs+1] = {take=MidiTake(item)} end;
        return jobs,"selected items";
    end;
    -------------------------------------------------------


    -------------------
    local jobs,label = GetJobs();
    if #jobs == 0 then no_undo() return end;
    -------------------

    -------------------
    reaper.Undo_BeginBlock();
    reaper.PreventUIRefresh(1);
    -------------------

    for _,j in ipairs(jobs) do;
        LegatoTake(j.take,j.s,j.e,j.selOnly);
    end;

    -------------------
    reaper.PreventUIRefresh(-1);
    reaper.UpdateArrange();
    reaper.Undo_EndBlock("Legato with overlap - "..label,-1);
    -------------------
