local ADDON_NAME, CWF = ...

-- Virtual frame representing the target aspect ratio, centered on screen.
-- Native frames are re-anchored to this instead of UIParent.
-- UIParent is never modified.
local CenterFrame = CreateFrame("Frame", "CWF_CenterFrame", UIParent)
CWF.CenterFrame = CenterFrame

-- [frameName] = {{point, relativeTo, relPoint, x, y}, ...}
local storedAnchors = {}

function CWF.UpdateCenterFrameGeometry()
    local uiW = UIParent:GetWidth()
    local uiH = UIParent:GetHeight()
    local w   = math.min(uiH * CWF.GetRatio(), uiW)
    CenterFrame:SetSize(w, uiH)
    CenterFrame:ClearAllPoints()
    CenterFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    -- Frames already anchored to CenterFrame reposition automatically via WoW's layout engine.
    -- Already-open Blizzard UI panels (CharacterFrame, etc.) need an explicit
    -- reflow so UIPanels.lua's hook can re-shift them to the new CenterFrame edge.
    if UpdateUIPanelPositions then UpdateUIPanelPositions(nil) end
end

-- Only horizontal-edge anchor points (TOPLEFT, LEFT, BOTTOMRIGHT, ...) need
-- the UIParent → CenterFrame rewrite. CENTER/TOP/BOTTOM sit on UIParent's
-- vertical axis, which is shared with CenterFrame, so rewriting them would
-- be a no-op visually — leave the original anchor alone.
local function isHorizontalEdge(p)
    return p and (p:find("LEFT") or p:find("RIGHT"))
end

local function Capture(frame)
    local result = {}
    for i = 1, frame:GetNumPoints() do
        local pt, rel, relPt, x, y = frame:GetPoint(i)
        -- relPt defaults to pt when nil; the meaningful side is the one on UIParent.
        if rel == UIParent and isHorizontalEdge(relPt or pt) then
            rel = CenterFrame
        end
        result[i] = {pt, rel, relPt, x, y}
    end
    return result
end

local function applyPoints(frame, anchors)
    frame:ClearAllPoints()
    for _, a in ipairs(anchors) do
        frame:SetPoint(a[1], a[2], a[3], a[4], a[5])
    end
end

-- Snapshot current points before mutating, so a partial SetPoint failure
-- doesn't leave the frame anchorless. Returns true on success.
local function Apply(name, anchors)
    local frame = _G[name]
    if not frame or not anchors then return false end
    local backup = {}
    for i = 1, frame:GetNumPoints() do
        backup[i] = {frame:GetPoint(i)}
    end
    local ok = pcall(applyPoints, frame, anchors)
    if not ok then
        pcall(applyPoints, frame, backup)
        return false
    end
    return true
end

-- Re-reads each frame's current anchors (set by Blizzard or Edit Mode),
-- replaces UIParent with CenterFrame, and applies. Safe to call on every
-- login, zone change, and Edit Mode update.
function CWF.CaptureAndApplyAll()
    if InCombatLockdown() then return end
    CWF.UpdateCenterFrameGeometry()
    for _, name in ipairs(CWF.FRAME_LIST) do
        local frame = _G[name]
        if frame and frame.GetNumPoints and frame:GetNumPoints() > 0 then
            local anchors = Capture(frame)
            if Apply(name, anchors) then
                storedAnchors[name] = anchors
            end
        end
    end
end

-- Re-applies already-stored anchors without re-reading from Blizzard.
-- Used after combat ends to catch any protected frames that were skipped.
function CWF.ReapplyStored()
    if InCombatLockdown() then return end
    for name, anchors in pairs(storedAnchors) do
        Apply(name, anchors)
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("UI_SCALE_CHANGED")
events:RegisterEvent("DISPLAY_SIZE_CHANGED")
events:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            CWF.InitDB()  -- SavedVariables are ready; no UI work here
        end

    elseif event == "PLAYER_LOGIN" then
        -- UI is safe to touch from this point on. Size the CenterFrame before
        -- showing the border so it doesn't render around a 0x0 region.
        CWF.UpdateCenterFrameGeometry()
        if CWF.db and CWF.db.debugBorder then
            CWF.SetDebugBorder(true)
        end

    elseif event == "PLAYER_ENTERING_WORLD"
        or event == "EDIT_MODE_LAYOUTS_UPDATED"
        or event == "UI_SCALE_CHANGED"
        or event == "DISPLAY_SIZE_CHANGED" then
        -- Defer one frame so Blizzard finishes applying its own anchors first.
        C_Timer.After(0, CWF.CaptureAndApplyAll)

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Logging in during combat causes the deferred CaptureAndApplyAll to
        -- early-return, leaving storedAnchors empty. Detect that here and run
        -- a full capture instead of replaying nothing.
        if next(storedAnchors) then
            CWF.ReapplyStored()
        else
            CWF.CaptureAndApplyAll()
        end
        -- UI panels opened mid-combat were skipped by AdjustOpenPanels'
        -- combat-lockdown guard; re-shift them now.
        if CWF.AdjustOpenPanels then CWF.AdjustOpenPanels() end
    end
end)
