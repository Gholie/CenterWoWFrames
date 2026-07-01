local _, CWF = ...

-- Blizzard's UI Panel system (Blizzard_UIParentPanelManager) positions panels
-- like CharacterFrame, SpellBookFrame, BankFrame, MerchantFrame, etc. via
-- SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y) on every show/hide/move,
-- driven by a forbidden FramePositionDelegate frame whose methods we cannot
-- hook directly. The public global wrappers (ShowUIPanel, HideUIPanel,
-- UpdateUIPanelPositions) call SetAttribute on the delegate, which fires the
-- positioning handler synchronously — so a hooksecurefunc on those globals
-- runs after the panel has already been anchored to UIParent.
--
-- Strategy: after Blizzard's pass, walk all currently-shown UIPanelWindows
-- entries with area "left" or "right" and shift them horizontally by the
-- CenterFrame inset. Runs synchronously (no timer deferral) to avoid a
-- one-frame blink at the unshifted position.
--
-- Idempotency: ShowUIPanel internally calls UpdateUIPanelPositions, so both
-- hooks fire for a single open event. panelState tracks the last Blizzard-
-- assigned x and our applied shift per panel. On re-entry, the frame is
-- already at baseX+shift — we detect that and leave it untouched rather than
-- doubling the offset.

local function inset()
    return (UIParent:GetWidth() - CWF.CenterFrame:GetWidth()) / 2
end

local panelState = {}  -- [frameName] = { baseX = number, shift = number }

-- Frames excluded from the UIPanelWindows loop — handled by their own logic.
local SKIP_PANELS = {
    WorldMapFrame    = true,
    AchievementFrame = true,
}

-- Frames to force-center on UIParent. Blizzard registers these as area "left"
-- in some Midnight builds, which would otherwise pin them to the screen edge.
local CENTER_FRAMES = {
    "WorldMapFrame",
    "AchievementFrame",
}

-- Frames to treat as area="left" regardless of their UIPanelWindows entry.
-- Used for frames not registered as left/right in all Midnight builds.
local EXTRA_LEFT_PANELS = {
    "AuctionHouseFrame",
}

local function shiftFrame(frame, name, sign)
    if not (frame and frame:IsShown() and frame:GetNumPoints() > 0) then
        panelState[name] = nil
        return
    end

    local pt1, rel1, relPt1, x1, y1 = frame:GetPoint(1)
    if rel1 ~= UIParent then
        panelState[name] = nil
        return
    end

    local px = inset()
    if px < 0.5 then return end

    local newShift = sign * px * UIParent:GetEffectiveScale() / frame:GetEffectiveScale()

    -- If the frame is already at baseX+shift (hook fired again for the same
    -- positioning event), use the stored base rather than stacking the shift.
    local s = panelState[name]
    local baseX
    if s and math.abs(x1 - (s.baseX + s.shift)) < 1.0 then
        baseX = s.baseX
    else
        baseX = x1  -- fresh position from Blizzard
    end

    -- Preserve all anchor points; shift only UIParent-relative ones.
    -- Dropping secondary anchors (e.g. a BOTTOMRIGHT for frame sizing)
    -- collapses the height on frames like FriendsFrame / CommunitiesFrame.
    local n = frame:GetNumPoints()
    local pts = {}
    pts[1] = {pt1, rel1, relPt1, baseX + newShift, y1}
    for i = 2, n do
        local pt, rel, relPt, x, y = frame:GetPoint(i)
        if rel == UIParent then x = x + newShift end
        pts[i] = {pt, rel, relPt, x, y}
    end

    local ok = pcall(function()
        frame:ClearAllPoints()
        for _, p in ipairs(pts) do
            frame:SetPoint(p[1], p[2], p[3], p[4], p[5])
        end
    end)
    if ok then
        panelState[name] = {baseX = baseX, shift = newShift}
    end
end

local function DoAdjustOpenPanels()
    if InCombatLockdown() then return end
    if not UIPanelWindows then return end

    for name, attrs in pairs(UIPanelWindows) do
        if not SKIP_PANELS[name] then
            local area = attrs and attrs.area
            if area == "left" or area == "right" then
                shiftFrame(_G[name], name, area == "left" and 1 or -1)
            end
        end
    end

    for _, name in ipairs(EXTRA_LEFT_PANELS) do
        shiftFrame(_G[name], name, 1)
    end
end

CWF.AdjustOpenPanels = DoAdjustOpenPanels

hooksecurefunc("ShowUIPanel",            DoAdjustOpenPanels)
hooksecurefunc("HideUIPanel",            DoAdjustOpenPanels)
hooksecurefunc("UpdateUIPanelPositions", DoAdjustOpenPanels)

-- Force-center listed frames on UIParent regardless of panel system.
-- Both hooks run synchronously — the hooksecurefunc fires after ShowUIPanel
-- returns (all Blizzard positioning done), and OnShow fires after the panel
-- manager's SetAttribute call has already placed the frame, so reading and
-- overriding the position here is safe with no deferral needed.
-- The center op is naturally idempotent so firing from both hooks is harmless.
local centerNames = {}
for _, name in ipairs(CENTER_FRAMES) do centerNames[name] = true end

local function centerFrame(frame)
    if frame and frame:IsShown() then
        pcall(function()
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end)
    end
end

-- Match by GetName(), not frame pointer — load-on-demand frames like
-- AchievementFrame (Blizzard_AchievementUI) don't exist at addon load.
hooksecurefunc("ShowUIPanel", function(frame)
    if frame and frame.GetName and centerNames[frame:GetName()] then
        centerFrame(frame)
    end
end)

-- Attach OnShow hooks for direct Show() calls. Retry on ADDON_LOADED so
-- load-on-demand frames get hooked when their owning addon is finally loaded.
local hookedOnShow = {}
local function tryHookOnShow()
    for _, name in ipairs(CENTER_FRAMES) do
        if not hookedOnShow[name] then
            local frame = _G[name]
            if frame and frame.HookScript then
                frame:HookScript("OnShow", centerFrame)
                hookedOnShow[name] = true
            end
        end
    end
    -- EXTRA_LEFT_PANELS frames (e.g. AuctionHouseFrame) are load-on-demand and can
    -- open via NPC Show() calls that bypass ShowUIPanel. Hook DoAdjustOpenPanels on
    -- OnShow here so we catch them regardless of how they were opened.
    for _, name in ipairs(EXTRA_LEFT_PANELS) do
        local key = "adj_" .. name
        if not hookedOnShow[key] then
            local frame = _G[name]
            if frame and frame.HookScript then
                frame:HookScript("OnShow", DoAdjustOpenPanels)
                hookedOnShow[key] = true
            end
        end
    end
end

tryHookOnShow()

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:SetScript("OnEvent", tryHookOnShow)
