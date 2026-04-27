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
            CWF.UpdateCenterFrameGeometry()
            print(string.format("|cff00aaff[CWF]|r Ratio set to %d:%d.", w, h))
        else
            print("|cff00aaff[CWF]|r Usage: /cwf ratio 16:9 (both numbers must be > 0)")
        end

    elseif cmd == "toggle" then
        CWF.db.enabled = not CWF.db.enabled
        CWF.UpdateCenterFrameGeometry()
        if CWF.db.enabled then
            print("|cff00aaff[CWF]|r Enabled.")
        else
            print("|cff00aaff[CWF]|r Disabled — CenterFrame now matches UIParent.")
        end

    elseif cmd == "debug" then
        CWF.db.debugBorder = not CWF.db.debugBorder
        CWF.SetDebugBorder(CWF.db.debugBorder)
        print("|cff00aaff[CWF]|r Debug border " .. (CWF.db.debugBorder and "on" or "off") .. ".")

    elseif cmd == "reload" then
        CWF.CaptureAndApplyAll()
        print("|cff00aaff[CWF]|r Anchors refreshed.")

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
        print("  /cwf debug        — toggle orange border showing center zone")
        print("  /cwf reload       — force-refresh all frame anchors")
        print("  /cwf status       — show current settings and screen ratio")
    end
end
