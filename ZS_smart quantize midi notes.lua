--[[
   * Category:    Arrange
   * Description: Quantize MIDI notes - selected items (whole item, or time selection)
   * Based on:    me2beats - Quantize MIDI note positions to project grid
   * Version:     1.0
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
    -- Quantize one take. If useTS, only notes starting inside tsStart..tsEnd
    local function QuantizeTake(take,gridQN,useTS,tsStart,tsEnd);
        local _,noteCnt = reaper.MIDI_CountEvts(take);
        if noteCnt == 0 then return 0 end;

        local tsStartPPQ,tsEndPPQ;
        if useTS then;
            tsStartPPQ = reaper.MIDI_GetPPQPosFromProjTime(take,tsStart);
            tsEndPPQ   = reaper.MIDI_GetPPQPosFromProjTime(take,tsEnd);
        end;

        local changed = 0;
        for i = 0,noteCnt-1 do;
            local _,sel,muted,s,e = reaper.MIDI_GetNote(take,i);
            if not useTS or (s >= tsStartPPQ and s < tsEndPPQ) then;
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


    -------------------
    -- Collect MIDI takes of selected items
    local takes = {};
    for i = 0,reaper.CountSelectedMediaItems(0)-1 do;
        local tk = reaper.GetActiveTake(reaper.GetSelectedMediaItem(0,i));
        if tk and reaper.TakeIsMIDI(tk) then takes[#takes+1] = tk end;
    end;
    if #takes == 0 then no_undo() return end;

    local tsStart,tsEnd = reaper.GetSet_LoopTimeRange(false,false,0,0,false);
    local useTS = tsEnd > tsStart;
    local gridQN = GridQN();
    -------------------

    -------------------
    reaper.Undo_BeginBlock();
    reaper.PreventUIRefresh(1);
    -------------------

    for _,tk in ipairs(takes) do;
        QuantizeTake(tk,gridQN,useTS,tsStart,tsEnd);
    end;

    -------------------
    reaper.PreventUIRefresh(-1);
    reaper.UpdateArrange();
    reaper.Undo_EndBlock("Quantize notes ("..STRENGTH.."%) - selected items"..(useTS and " (time selection)" or ""),-1);
    -------------------
