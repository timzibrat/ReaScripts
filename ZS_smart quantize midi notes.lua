--[[
   * Category:    Arrange + MIDI Inline Editor
   * Description: Quantize MIDI notes - selected notes, razor areas, time selection or selected items
   * Based on:    me2beats - Quantize MIDI note positions to project grid
   * Version:     1.2
   * Changelog:   v1.2 + one script for arrange and the inline editor
   *                   + priority: selected notes > razor areas > time selection > selected items
   *                   + with no item selected, the item under the mouse is used
   *                   + muted items are skipped
   *              v1.1 + razor edits (take priority over item selection)
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
    -- Quantize one take. With rStart/rEnd (project time), only notes starting inside that range;
    -- with selOnly, only selected notes
    local function QuantizeTake(take,gridQN,rStart,rEnd,selOnly);
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
            if (sel or not selOnly) and (not rStart or (s >= rStartPPQ and s < rEndPPQ)) then;
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
    -- Active MIDI take of an unmuted item, or nil
    local function MidiTake(item);
        if not item or reaper.GetMediaItemInfo_Value(item,'B_MUTE') ~= 0 then return end;
        local tk = reaper.GetActiveTake(item);
        if tk and reaper.TakeIsMIDI(tk) then return tk end;
    end;
    -------------------------------------------------------


    -------------------------------------------------------
    -- What to work on, first match wins:
    -- 1. selected notes, in the selected items or the item under the mouse
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

        -- 1. selected notes
        local noteItems = {table.unpack(selItems)};
        if mouseItem and not reaper.IsMediaItemSelected(mouseItem) then noteItems[#noteItems+1] = mouseItem end;
        for _,item in ipairs(noteItems) do;
            local tk = MidiTake(item);
            if reaper.MIDI_EnumSelNotes(tk,-1) ~= -1 then jobs[#jobs+1] = {take=tk,selOnly=true} end;
        end;
        if #jobs > 0 then return jobs,"selected notes" end;

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
    local gridQN = GridQN();
    -------------------

    -------------------
    reaper.Undo_BeginBlock();
    reaper.PreventUIRefresh(1);
    -------------------

    for _,j in ipairs(jobs) do;
        QuantizeTake(j.take,gridQN,j.s,j.e,j.selOnly);
    end;

    -------------------
    reaper.PreventUIRefresh(-1);
    reaper.UpdateArrange();
    reaper.Undo_EndBlock("Quantize notes ("..STRENGTH.."%) - "..label,-1);
    -------------------
