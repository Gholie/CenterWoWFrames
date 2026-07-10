local ADDON_NAME, CWF = ...

CWF.DB_DEFAULTS = {
    enabled     = true,
    ratioWidth  = 16,
    ratioHeight = 9,
    debugBorder = false,
}

function CWF.GetRatio()
    if CWF.db and CWF.db.enabled ~= false then
        return CWF.db.ratioWidth / CWF.db.ratioHeight
    end
    -- Disabled: match screen ratio exactly (CenterFrame == UIParent, no effect)
    return UIParent:GetWidth() / UIParent:GetHeight()
end

function CWF.InitDB()
    if type(CenterWoWFramesDB) ~= "table" then
        CenterWoWFramesDB = {}
    end
    for k, v in pairs(CWF.DB_DEFAULTS) do
        if CenterWoWFramesDB[k] == nil then
            CenterWoWFramesDB[k] = v
        end
    end
    CWF.db = CenterWoWFramesDB
end

-- Debug: orange border showing the CenterFrame bounds
local borderLines

local function EnsureBorderLines()
    if borderLines then return end
    borderLines = {}
    local f = CWF.CenterFrame  -- defined by Core.lua before any runtime calls
    local function edge(a, b, horiz)
        local t = f:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 0.5, 0, 1)
        t:SetPoint(a, f, a)
        t:SetPoint(b, f, b)
        if horiz then t:SetHeight(2) else t:SetWidth(2) end
        return t
    end
    borderLines[1] = edge("TOPLEFT",    "TOPRIGHT",    true)
    borderLines[2] = edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    borderLines[3] = edge("TOPLEFT",    "BOTTOMLEFT",  false)
    borderLines[4] = edge("TOPRIGHT",   "BOTTOMRIGHT", false)
end

function CWF.SetDebugBorder(show)
    EnsureBorderLines()
    for _, t in ipairs(borderLines) do
        if show then t:Show() else t:Hide() end
    end
end

-- Debug: report which FRAME_LIST names currently resolve to real frames.
-- Uses the same guard as Core's capture (frame and frame.GetNumPoints), so a
-- "missing" entry is exactly one the addon would silently skip. Note that some
-- entries are legitimately absent depending on game state (boss/arena frames,
-- load-on-demand panels) — a name only indicates a typo if it never resolves in
-- a context where the frame should exist.
function CWF.ReportFrames()
    local found, missing = 0, {}
    for _, name in ipairs(CWF.FRAME_LIST) do
        local f = _G[name]
        if f and f.GetNumPoints then
            found = found + 1
        else
            missing[#missing + 1] = name
        end
    end
    print(string.format(
        "|cff00aaff[CWF]|r Frames: %d/%d resolved.", found, #CWF.FRAME_LIST))
    if #missing > 0 then
        print("|cff00aaff[CWF]|r Not present now (state-dependent or bad name): "
            .. table.concat(missing, ", "))
    end
end

-- Slash commands
SLASH_CENTERWOWFRAMES1 = "/cwf"
SlashCmdList["CENTERWOWFRAMES"] = function(msg)
    local parts = {}
    for w in msg:gmatch("%S+") do parts[#parts + 1] = w end
    local cmd = (parts[1] or ""):lower()

    if cmd == "ratio" then
        local w, h = (parts[2] or ""):match("^(%d+)[:/](%d+)$")
        w, h = tonumber(w), tonumber(h)
        if w and h and w > 0 and h > 0 then
            CWF.db.ratioWidth  = w
            CWF.db.ratioHeight = h
            if InCombatLockdown() then
                -- Resizing CenterFrame mid-combat would move protected frames
                -- anchored to it and poke the panel manager — both blocked.
                -- Defer to Core.lua's PLAYER_REGEN_ENABLED handler.
                CWF._pendingGeometryUpdate = true
                print(string.format("|cff00aaff[CWF]|r Ratio set to %d:%d — applying after combat.", w, h))
            else
                CWF.UpdateCenterFrameGeometry()
                print(string.format("|cff00aaff[CWF]|r Ratio set to %d:%d.", w, h))
            end
        else
            print("|cff00aaff[CWF]|r Usage: /cwf ratio 16:9 (both numbers must be > 0)")
        end

    elseif cmd == "toggle" then
        CWF.db.enabled = not CWF.db.enabled
        if InCombatLockdown() then
            CWF._pendingGeometryUpdate = true
            if CWF.db.enabled then
                print("|cff00aaff[CWF]|r Enabled — applying after combat.")
            else
                print("|cff00aaff[CWF]|r Disabled — applying after combat.")
            end
        else
            CWF.UpdateCenterFrameGeometry()
            if CWF.db.enabled then
                print("|cff00aaff[CWF]|r Enabled.")
            else
                print("|cff00aaff[CWF]|r Disabled — CenterFrame now matches UIParent.")
            end
        end

    elseif cmd == "debug" then
        CWF.db.debugBorder = not CWF.db.debugBorder
        CWF.SetDebugBorder(CWF.db.debugBorder)
        print("|cff00aaff[CWF]|r Debug border " .. (CWF.db.debugBorder and "on" or "off") .. ".")
        CWF.ReportFrames()

    elseif cmd == "reload" then
        CWF.CaptureAndApplyAll()
        if InCombatLockdown() then
            -- CaptureAndApplyAll early-returned; it'll run for real on the
            -- next PLAYER_REGEN_ENABLED.
            print("|cff00aaff[CWF]|r In combat — refresh queued for after combat.")
        else
            print("|cff00aaff[CWF]|r Anchors refreshed.")
        end

    elseif cmd == "status" then
        local screen = UIParent:GetWidth() / UIParent:GetHeight()
        print(string.format(
            "|cff00aaff[CWF]|r enabled=%s  target=%d:%d  screen=%.4f:1",
            tostring(CWF.db.enabled),
            CWF.db.ratioWidth, CWF.db.ratioHeight,
            screen
        ))

    else
        print("|cff00aaff[CWF]|r Commands:")
        print("  /cwf ratio 16:9   — set aspect ratio (e.g. 16:9, 21:9)")
        print("  /cwf toggle       — enable / disable")
        print("  /cwf debug        — toggle center-zone border + list resolved/missing frames")
        print("  /cwf reload       — force-refresh all frame anchors")
        print("  /cwf status       — show current settings and screen ratio")
    end
end
