--[[
   * Category:    Arrange
   * Description: Legato with overlap - selected items (whole item, or time selection)
   * Based on:    Archie - Set note ends to start of next note (legato)
   * Version:     1.2
   * Changelog:   v1.2 + ignore muted notes and muted items
   *              v1.1 + ignore notes outside the visible item
   * Extension:   Reaper 6.2+
--]]

    --======================================================================================
    local OVERLAP_MS = 20; -- how far each note extends past the next note's start (milliseconds)
    --======================================================================================


    -------------------------------------------------------
    local function no_undo()reaper.defer(function()end)end;
    -------------------------------------------------------


    -------------------------------------------------------
    -- Legato + overlap on one take. Only unmuted notes starting inside the visible item
    -- (and inside tsStart..tsEnd if useTS)
    local function LegatoTake(take,useTS,tsStart,tsEnd);
        local _,noteCnt = reaper.MIDI_CountEvts(take);
        if noteCnt == 0 then return 0 end;

        local item = reaper.GetMediaItemTake_Item(take);
        local itemPos = reaper.GetMediaItemInfo_Value(item,'D_POSITION');
        local itemEnd = itemPos + reaper.GetMediaItemInfo_Value(item,'D_LENGTH');
        local itemEndPPQ = reaper.MIDI_GetPPQPosFromProjTime(take,itemEnd);

        local rangeStart,rangeEnd = itemPos,itemEnd;
        if useTS then;
            rangeStart = math.max(rangeStart,tsStart);
            rangeEnd   = math.min(rangeEnd,tsEnd);
            if rangeEnd <= rangeStart then return 0 end;
        end;
        local rangeStartPPQ = reaper.MIDI_GetPPQPosFromProjTime(take,rangeStart);
        local rangeEndPPQ   = reaper.MIDI_GetPPQPosFromProjTime(take,rangeEnd);

        local targets,samePitch = {},{};
        for i = 0,noteCnt-1 do;
            local _,sel,muted,s,e,chan,pitch,vel = reaper.MIDI_GetNote(take,i);
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
                -- never run into the next note of the same pitch/channel
                for _,s in ipairs(samePitch[n.chan*128+n.pitch]) do;
                    if s > n.s and s < newEnd then newEnd = s end;
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


    -------------------
    -- Collect MIDI takes of selected, unmuted items
    local takes = {};
    for i = 0,reaper.CountSelectedMediaItems(0)-1 do;
        local it = reaper.GetSelectedMediaItem(0,i);
        if reaper.GetMediaItemInfo_Value(it,'B_MUTE') == 0 then;
            local tk = reaper.GetActiveTake(it);
            if tk and reaper.TakeIsMIDI(tk) then takes[#takes+1] = tk end;
        end;
    end;
    if #takes == 0 then no_undo() return end;

    local tsStart,tsEnd = reaper.GetSet_LoopTimeRange(false,false,0,0,false);
    local useTS = tsEnd > tsStart;
    -------------------

    -------------------
    reaper.Undo_BeginBlock();
    reaper.PreventUIRefresh(1);
    -------------------

    for _,tk in ipairs(takes) do;
        LegatoTake(tk,useTS,tsStart,tsEnd);
    end;

    -------------------
    reaper.PreventUIRefresh(-1);
    reaper.UpdateArrange();
    reaper.Undo_EndBlock("Legato with overlap - selected items"..(useTS and " (time selection)" or ""),-1);
    -------------------
