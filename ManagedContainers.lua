local _, CWF = ...

-- Frames Blizzard re-anchors to a UIParent edge from code on every layout
-- pass, so a one-time capture in Core.lua's FRAME_LIST can't hold them:
--
--  * RightManagedFrameContainer — holds every RightManagedFrameTemplate
--    frame (Boss1-5TargetFrame, CompactArenaFrame, DurabilityFrame,
--    VehicleSeatIndicator, QuestTimerFrame, UIWidgetBelowMinimapContainer,
--    and the objective tracker when it isn't user-placed). The secure
--    FramePositionDelegate re-pins it to UIParent TOPRIGHT in
--    ManageRightFrameContainer() on every ManageFramePositions() call.
--
--  * Bag frames (ContainerFrame1..N / ContainerFrameCombinedBags) — the
--    first open bag is pinned to its parent's BOTTOMRIGHT by
--    UpdateContainerFrameAnchors(); its parent is ContainerFrameContainer
--    (setAllPoints on UIParent) or UIParent itself. Every other bag chains
--    off the first, so moving the first moves the column.
--
-- Same approach as UIPanels.lua: hooksecurefunc the public globals and,
-- after Blizzard's pass, swap the screen-sized relativeTo for CenterFrame
-- (offsets unchanged). Both functions exist in retail and in WoW Forever
-- (Mainline family; identical code in Blizzard_UIParentPanelManager and
-- Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua).

-- True when `rel` spans the whole screen horizontally, i.e. anchoring to
-- its LEFT/RIGHT edge means "the physical screen edge".
local function isScreenSized(rel)
    if rel == UIParent then return true end
    if rel == nil or rel == CWF.CenterFrame then return false end
    return rel == _G.ContainerFrameContainer
end

local function isHorizontalEdge(p)
    return p and (p:find("LEFT") or p:find("RIGHT")) and true or false
end

-- Protected (or implicitly protected, e.g. parent of secure Boss unit
-- buttons) frames can't be moved in combat; doing so wouldn't throw, it
-- would raise ADDON_ACTION_BLOCKED (not a catchable Lua error). Skip; Core's
-- PLAYER_REGEN_ENABLED handler calls AdjustManagedContainers() to retry.
local function canMove(frame)
    if not InCombatLockdown() then return true end
    return not (frame.IsProtected and frame:IsProtected())
end

-- Rewrites every screen-edge anchor of `frame` to CenterFrame. Idempotent:
-- a frame already anchored to CenterFrame is left untouched.
local function reanchorToCenter(frame)
    if not (frame and frame.GetNumPoints and frame:GetNumPoints() > 0) then return end
    local cf = CWF.CenterFrame
    if not cf or cf:GetWidth() == 0 then return end  -- before PLAYER_LOGIN

    local pts, changed = {}, false
    for i = 1, frame:GetNumPoints() do
        local pt, rel, relPt, x, y = frame:GetPoint(i)
        if isScreenSized(rel) and isHorizontalEdge(relPt or pt) then
            rel = cf
            changed = true
        end
        pts[i] = {pt, rel, relPt, x, y}
    end
    if not changed or not canMove(frame) then return end

    pcall(function()
        frame:ClearAllPoints()
        for _, p in ipairs(pts) do
            frame:SetPoint(p[1], p[2], p[3], p[4], p[5])
        end
    end)
end

local function AdjustRightContainer()
    reanchorToCenter(_G.RightManagedFrameContainer)
end

local function AdjustBags()
    local mgr = _G.ContainerFrameSettingsManager
    if not (mgr and mgr.GetBagsShown) then return end
    local ok, bags = pcall(mgr.GetBagsShown, mgr)
    if not ok or type(bags) ~= "table" then return end
    reanchorToCenter(bags[1])
end

function CWF.AdjustManagedContainers()
    AdjustRightContainer()
    AdjustBags()
end

-- Hook lazily: both globals normally exist by the time user addons load,
-- but retry on ADDON_LOADED in case a client flavor moves either into a
-- load-on-demand addon. Each hook is installed at most once.
local HOOKS = {
    ManageFramePositions        = AdjustRightContainer,
    UpdateContainerFrameAnchors = AdjustBags,
}
local hooked = {}
local function tryHook()
    for fname, fn in pairs(HOOKS) do
        if not hooked[fname] and type(_G[fname]) == "function" then
            hooksecurefunc(fname, fn)
            hooked[fname] = true
        end
    end
end
tryHook()

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:SetScript("OnEvent", tryHook)
