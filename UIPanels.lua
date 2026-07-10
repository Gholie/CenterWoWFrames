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
-- entries with area "left" or "right", outermost panel first, and shift them
-- inward by the CenterFrame inset — overlap-aware (see below). Runs
-- synchronously (no timer deferral) to avoid a one-frame blink at the
-- unshifted position.
--
-- Why overlap-aware, not a blind shift of every open panel: Blizzard's
-- FramePositionDelegate assigns each open panel a "slot" and positions
-- slot 2+ panels relative to the edge of the panel in the preceding slot
-- (roughly leftPanel:GetRight() + spacing). Whether a given pass computed
-- that edge from the panel's canonical (pre-shift) position or from its
-- live (already-shifted) position cannot be assumed, so neither "shift
-- everything" (double-counts the inset in the live case) nor "shift only
-- the outermost panel" (leaves a gap-sized overlap in the canonical case)
-- is safe. Instead: the outermost panel on a side always gets the shift;
-- each panel behind it is shifted only if it would now overlap the
-- (post-shift) panel ahead of it — i.e. Blizzard positioned it against
-- pre-shift geometry this pass. Panels already cascaded off shifted
-- geometry are left alone. We used to also force-center
-- WorldMapFrame/AchievementFrame here (they register as area "left" in
-- some Midnight builds), but secretly moving a panel to screen center
-- while it was still occupying a left slot broke the delegate's slot
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
-- doubling the offset. Panels a pass decides not to shift have their
-- panelState cleared so a stale baseX/shift pair can't be misapplied if they
-- later need shifting themselves (e.g. the panel ahead of them closes).

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
-- Used for frames not registered as left/right in all Midnight builds —
-- AuctionHouseFrame isn't registered at all, and AchievementFrame registers
-- as "doublewide" (or via frame attributes) rather than "left", so the
-- area scan in DoAdjustOpenPanels never sees them. Load-on-demand is fine:
-- tryHookOnShow retries on every ADDON_LOADED, and processSide just skips
-- names whose global doesn't resolve yet.
local EXTRA_LEFT_PANELS = {
    "AuctionHouseFrame",
    "AchievementFrame",
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

-- Returns the screen-space horizontal delta actually applied (0 when nothing
-- moved), so the caller can track post-shift edges without re-querying rects.
local function shiftFrame(frame, name, sign)
    if not (isFrameLike(frame) and frame:IsShown() and frame:GetNumPoints() > 0) then
        panelState[name] = nil
        return 0
    end

    local pt1, rel1, relPt1, x1, y1 = frame:GetPoint(1)
    if rel1 ~= UIParent then
        panelState[name] = nil
        return 0
    end

    local px = inset()
    if px < 0.5 then return 0 end

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
        -- On idempotent re-entry x1 already ≈ baseX+shift, so this is ~0.
        local delta = (baseX + newShift - x1) * frame:GetEffectiveScale()
        -- Shifted panels occupy screen space that stock layout reserves for
        -- HUD frames (unit frames, trackers), and repositioning never touches
        -- frame levels — a low-level panel (e.g. PlayerSpellsFrame) ends up
        -- rendering UNDER the HUD frames it now overlaps. Raise it within its
        -- strata whenever we actually move it (not on idempotent re-entries,
        -- so we don't perpetually fight click-to-raise ordering).
        if math.abs(delta) > 0.5 and frame.Raise then
            pcall(frame.Raise, frame)
        end
        return delta
    end
    return 0
end

-- Shift one side's panels, outermost first. The outermost panel always gets
-- the inset shift; each panel behind it is shifted only if it would now
-- overlap the (post-shift) panel ahead of it — meaning Blizzard cascaded it
-- off pre-shift geometry this pass. Edges are compared in screen space so
-- panels with different scales compare correctly. sign is +1 for "left"
-- (shift rightward, compare left edges), -1 for "right".
local function processSide(names, sign)
    local list, seen = {}, {}
    for _, name in ipairs(names) do
        if not seen[name] then
            seen[name] = true
            local frame = asCandidate(name)
            local outer = frame and (sign == 1 and screenLeft(frame) or screenRight(frame))
            if outer then
                list[#list + 1] = {name = name, frame = frame, outer = outer}
            else
                -- Hidden, non-frame, or no computed rect yet: never a shift
                -- target this pass, and stale state must not survive.
                panelState[name] = nil
            end
        end
    end

    table.sort(list, function(a, b)
        if sign == 1 then return a.outer < b.outer end
        return a.outer > b.outer
    end)

    local prevInner
    for i, entry in ipairs(list) do
        local inner = (sign == 1) and screenRight(entry.frame) or screenLeft(entry.frame)
        local needsShift = (i == 1)
            or (sign == 1 and entry.outer < prevInner - 0.5)
            or (sign == -1 and entry.outer > prevInner + 0.5)
        if needsShift then
            -- Track the applied delta instead of re-reading the rect, so we
            -- don't depend on the layout engine recomputing it synchronously.
            inner = inner + shiftFrame(entry.frame, entry.name, sign)
        else
            panelState[entry.name] = nil
        end
        prevInner = inner
    end
end

local function DoAdjustOpenPanels()
    if InCombatLockdown() then return end
    if not UIPanelWindows then return end
    -- CenterFrame is created 0x0 in Core.lua and only sized at PLAYER_LOGIN.
    -- If a hooked panel function runs before that, inset() would return half
    -- the screen width and shove every panel off-screen; bail instead.
    if not CWF.CenterFrame or CWF.CenterFrame:GetWidth() == 0 then return end

    -- Gather every shown left/right candidate, then process each side
    -- outermost-first with the overlap-aware shift (see header comment).
    -- Panels a pass doesn't shift get their panelState cleared so stale
    -- base/shift pairs can't misfire.
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
        leftNames[#leftNames + 1] = name  -- processSide dedupes
    end

    processSide(leftNames, 1)
    processSide(rightNames, -1)
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
