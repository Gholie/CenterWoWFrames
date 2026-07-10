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
-- entries with area "left" or "right" and shift the EDGE-MOST one of each
-- side horizontally by the CenterFrame inset. Runs synchronously (no timer
-- deferral) to avoid a one-frame blink at the unshifted position.
--
-- Why edge-most only, not every open panel: Blizzard's FramePositionDelegate
-- assigns each open panel a "slot" and positions slot 2+ panels relative to
-- the ACTUAL current edge of the panel in the preceding slot (roughly
-- leftPanel:GetRight() + spacing), not relative to UIParent directly. Only
-- the panel occupying the outermost slot on a side is anchored straight to
-- UIParent and needs our shift; every other panel on that side is already
-- correctly cascaded off the (now-shifted) edge-most panel's real position,
-- and shifting it too would double-count the inset. We used to also
-- force-center WorldMapFrame/AchievementFrame here (they register as area
-- "left" in some Midnight builds), but secretly moving a panel to screen
-- center while it was still occupying a left slot broke the delegate's slot
-- accounting for every OTHER open panel — subsequent panels cascade off
-- WorldMapFrame/AchievementFrame's real (centered) edge, not its registered
-- slot position, scrambling their layout. Leaving them as ordinary left
-- panels — shifted inward like everything else — keeps the slot math
-- self-consistent.
--
-- Idempotency: ShowUIPanel internally calls UpdateUIPanelPositions, so both
-- hooks fire for a single open event. panelState tracks the last Blizzard-
-- assigned x and our applied shift per panel. On re-entry, the frame is
-- already at baseX+shift — we detect that and leave it untouched rather than
-- doubling the offset. Panels that are open but not currently edge-most have
-- their panelState cleared each pass so a stale baseX/shift pair can't be
-- misapplied if they later become edge-most themselves (e.g. the panel ahead
-- of them closes).

local function inset()
    return (UIParent:GetWidth() - CWF.CenterFrame:GetWidth()) / 2
end

-- True if `frame` is a real frame-like object we can safely call frame
-- methods on. Third-party addons can register UIPanelWindows entries whose
-- global resolves to nil or to a plain (non-frame) table; guard against that
-- so one bad entry can't error out the whole pass for the rest of the
-- session.
local function isFrameLike(frame)
    return type(frame) == "table" and frame.IsShown and frame.GetNumPoints
end

local panelState = {}  -- [frameName] = { baseX = number, shift = number }

-- Frames excluded from the UIPanelWindows loop entirely. Currently empty —
-- WorldMapFrame/AchievementFrame used to live here for force-centering, but
-- that's gone (see header comment). Kept as an extension point for any
-- future panel that genuinely needs to opt out of shifting.
local SKIP_PANELS = {}

-- Frames to treat as area="left" regardless of their UIPanelWindows entry.
-- Used for frames not registered as left/right in all Midnight builds.
local EXTRA_LEFT_PANELS = {
    "AuctionHouseFrame",
}

-- Returns a frame's horizontal edges in screen space (i.e. corrected for its
-- own effective scale), or nil if the frame has no computed rect yet.
local function screenLeft(frame)
    local left = frame:GetLeft()
    if not left then return nil end
    return left * frame:GetEffectiveScale()
end

local function screenRight(frame)
    local right = frame:GetRight()
    if not right then return nil end
    return right * frame:GetEffectiveScale()
end

-- A "candidate" is shown, has at least one anchor point, and is a real frame.
local function asCandidate(name)
    local frame = _G[name]
    if not isFrameLike(frame) then return nil end
    if not (frame:IsShown() and frame:GetNumPoints() > 0) then return nil end
    return frame
end

local function shiftFrame(frame, name, sign)
    if not (isFrameLike(frame) and frame:IsShown() and frame:GetNumPoints() > 0) then
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
    -- CenterFrame is created 0x0 in Core.lua and only sized at PLAYER_LOGIN.
    -- If a hooked panel function runs before that, inset() would return half
    -- the screen width and shove every panel off-screen; bail instead.
    if not CWF.CenterFrame or CWF.CenterFrame:GetWidth() == 0 then return end

    -- Gather every shown left/right candidate first, then only shift the
    -- edge-most one per side (see header comment for why). Everything else
    -- has its panelState cleared so stale base/shift pairs can't misfire.
    local leftNames, rightNames = {}, {}

    for name, attrs in pairs(UIPanelWindows) do
        if not SKIP_PANELS[name] then
            local area = attrs and attrs.area
            if area == "left" then
                leftNames[#leftNames + 1] = name
            elseif area == "right" then
                rightNames[#rightNames + 1] = name
            end
        end
    end

    for _, name in ipairs(EXTRA_LEFT_PANELS) do
        local alreadyListed = false
        for _, existing in ipairs(leftNames) do
            if existing == name then
                alreadyListed = true
                break
            end
        end
        if not alreadyListed then
            leftNames[#leftNames + 1] = name
        end
    end

    local edgeLeftName, edgeLeftValue
    for _, name in ipairs(leftNames) do
        local frame = asCandidate(name)
        if frame then
            local left = screenLeft(frame)
            if left and (not edgeLeftValue or left < edgeLeftValue) then
                edgeLeftValue = left
                edgeLeftName = name
            end
        end
    end

    local edgeRightName, edgeRightValue
    for _, name in ipairs(rightNames) do
        local frame = asCandidate(name)
        if frame then
            local right = screenRight(frame)
            if right and (not edgeRightValue or right > edgeRightValue) then
                edgeRightValue = right
                edgeRightName = name
            end
        end
    end

    for _, name in ipairs(leftNames) do
        if name == edgeLeftName then
            shiftFrame(_G[name], name, 1)
        else
            panelState[name] = nil
        end
    end

    for _, name in ipairs(rightNames) do
        if name == edgeRightName then
            shiftFrame(_G[name], name, -1)
        else
            panelState[name] = nil
        end
    end
end

CWF.AdjustOpenPanels = DoAdjustOpenPanels

hooksecurefunc("ShowUIPanel",            DoAdjustOpenPanels)
hooksecurefunc("HideUIPanel",            DoAdjustOpenPanels)
hooksecurefunc("UpdateUIPanelPositions", DoAdjustOpenPanels)

-- EXTRA_LEFT_PANELS frames (e.g. AuctionHouseFrame) are load-on-demand and can
-- open via NPC Show() calls that bypass ShowUIPanel entirely. Hook
-- DoAdjustOpenPanels on OnShow here so we catch them regardless of how they
-- were opened. Retry on ADDON_LOADED since these frames don't exist until
-- their owning addon is finally loaded.
local hookedOnShow = {}
local function tryHookOnShow()
    for _, name in ipairs(EXTRA_LEFT_PANELS) do
        if not hookedOnShow[name] then
            local frame = _G[name]
            if frame and frame.HookScript then
                frame:HookScript("OnShow", DoAdjustOpenPanels)
                hookedOnShow[name] = true
            end
        end
    end
end

tryHookOnShow()

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:SetScript("OnEvent", tryHookOnShow)
