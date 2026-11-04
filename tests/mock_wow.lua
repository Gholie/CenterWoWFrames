-- Minimal mock of the WoW client API surface CenterWoWFrames touches.
-- Pure Lua 5.1 (the WoW client's dialect). Only horizontal geometry is
-- modelled, since that's all the addon reasons about.
--
-- Usage: local env = dofile("tests/mock_wow.lua")(opts)
--   opts.screenW / opts.screenH : UIParent size (default 3440 x 1440 -> 21:9)
--   opts.noEditMode             : client without EDIT_MODE_LAYOUTS_UPDATED
--   opts.noPanelManager         : client without ShowUIPanel & friends
--   opts.noSecretValues         : client without issecretvalue
--   opts.noManagedFrames        : client without ManageFramePositions / bag anchoring

return function(opts)
    opts = opts or {}
    local W, H = opts.screenW or 3440, opts.screenH or 1440

    local env = {
        timers = {},
        combat = false,
        printed = {},
        eventFrames = {},
        validEvents = {
            ADDON_LOADED = true, PLAYER_LOGIN = true, PLAYER_ENTERING_WORLD = true,
            PLAYER_REGEN_ENABLED = true, UI_SCALE_CHANGED = true,
            DISPLAY_SIZE_CHANGED = true, EDIT_MODE_LAYOUTS_UPDATED = true,
        },
    }
    if opts.noEditMode then env.validEvents.EDIT_MODE_LAYOUTS_UPDATED = nil end

    ------------------------------------------------------------------ frames
    local Frame = {}
    Frame.__index = Frame

    local function newFrame(name, parent)
        local f = setmetatable({
            _name = name, _parent = parent, _points = {}, _w = 0, _h = 0,
            _shown = true, _scale = 1, _scripts = {}, _hooks = {}, _events = {},
            _protected = false, _level = 1,
        }, Frame)
        if name then _G[name] = f end
        return f
    end
    env.newFrame = newFrame

    function Frame:GetName() return self._name end
    function Frame:GetNumPoints() return #self._points end
    function Frame:GetPoint(i)
        local p = self._points[i or 1]
        if not p then return nil end
        return p[1], p[2], p[3], p[4], p[5]
    end
    function Frame:ClearAllPoints()
        if self._protected and env.combat then error("ADDON_ACTION_BLOCKED ClearAllPoints") end
        self._points = {}
    end
    function Frame:SetPoint(pt, rel, relPt, x, y)
        if self._protected and env.combat then error("ADDON_ACTION_BLOCKED SetPoint") end
        if type(rel) == "string" then rel = _G[rel] end
        if type(rel) == "number" then rel, relPt, x, y = self._parent, pt, rel, relPt end
        rel = rel or self._parent
        relPt = relPt or pt
        for i, p in ipairs(self._points) do
            if p[1] == pt then table.remove(self._points, i) break end
        end
        table.insert(self._points, {pt, rel, relPt, x or 0, y or 0})
    end
    function Frame:SetSize(w, h) self._w, self._h = w, h end
    function Frame:SetWidth(w) self._w = w end
    function Frame:SetHeight(h) self._h = h end
    function Frame:GetWidth() return self._w end
    function Frame:GetHeight() return self._h end
    function Frame:GetEffectiveScale() return self._scale end
    function Frame:IsShown() return self._shown end
    function Frame:Show() self._shown = true; self:_fire("OnShow") end
    function Frame:Hide() self._shown = false end
    function Frame:Raise() self._level = self._level + 1 end
    function Frame:SetScript(s, fn) self._scripts[s] = fn end
    function Frame:HookScript(s, fn)
        self._hooks[s] = self._hooks[s] or {}
        table.insert(self._hooks[s], fn)
    end
    function Frame:_fire(s, ...)
        if self._scripts[s] then self._scripts[s](self, ...) end
        for _, fn in ipairs(self._hooks[s] or {}) do fn(self, ...) end
    end
    function Frame:RegisterEvent(e)
        if not env.validEvents[e] then
            error("Attempt to register unknown event \"" .. tostring(e) .. "\"")
        end
        self._events[e] = true
        env.eventFrames[self] = true
    end
    function Frame:GetAttribute(k) return self._attrs and self._attrs[k] end
    function Frame:SetAttribute(k, v) self._attrs = self._attrs or {}; self._attrs[k] = v end
    function Frame:IsProtected() return self._protected end
    function Frame:SetScale(s) self._scale = s end
    function Frame:GetParent() return self._parent end
    function Frame:CreateTexture()
        local t = newFrame(nil, self)
        function t.SetColorTexture() end
        return t
    end

    -- Horizontal-only layout resolution.
    local function hcomp(p)
        if p:find("LEFT") then return "LEFT" elseif p:find("RIGHT") then return "RIGHT" end
        return "CENTER"
    end
    function Frame:GetLeft()
        if self == env.UIParent then return 0 end
        local p = self._points[1]
        if not p then return nil end
        local relLeft = p[2]:GetLeft()
        if not relLeft then return nil end
        local rw = p[2]:GetWidth()
        local relX = relLeft + ({LEFT = 0, CENTER = rw / 2, RIGHT = rw})[hcomp(p[3])]
        local off = ({LEFT = 0, CENTER = self._w / 2, RIGHT = self._w})[hcomp(p[1])]
        return relX + p[4] - off
    end
    function Frame:GetRight()
        local l = self:GetLeft()
        return l and (l + self._w)
    end

    ----------------------------------------------------------------- globals
    env.UIParent = newFrame("UIParent", nil)
    env.UIParent:SetSize(W, H)

    _G.CreateFrame = function(_, name, parent) return newFrame(name, parent) end
    _G.InCombatLockdown = function() return env.combat end
    _G.C_Timer = { After = function(_, fn) table.insert(env.timers, fn) end }
    _G.C_EventUtils = { IsEventValid = function(e) return env.validEvents[e] == true end }
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        table.insert(env.printed, table.concat(parts, " "))
    end
    _G.SlashCmdList = {}
    _G.hooksecurefunc = function(a, b, c)
        local tbl, name, fn = _G, a, b
        if type(a) == "table" then tbl, name, fn = a, b, c end
        local orig = tbl[name]
        if type(orig) ~= "function" then error("hooksecurefunc(): " .. tostring(name) .. " is not a function") end
        tbl[name] = function(...)
            local r = { orig(...) }
            fn(...)
            return unpack(r)
        end
    end
    if not opts.noSecretValues then
        _G.issecretvalue = function() return false end
    end

    ------------------------------------------------------ UI panel manager
    -- Simplified FramePositionDelegate: left panels cascade from the left
    -- screen edge, right panels from the right edge, using live edges.
    _G.UIPanelWindows = {}
    if not opts.noPanelManager then
        local openOrder = {}
        local function relayout()
            local x = 16
            for _, f in ipairs(openOrder) do
                local attrs = UIPanelWindows[f._name]
                if attrs and attrs.area == "left" and f:IsShown() then
                    f._points = {}
                    f._points[1] = {"TOPLEFT", env.UIParent, "TOPLEFT", x, -100}
                    x = x + f._w + 10
                end
            end
            local rx = -16
            for _, f in ipairs(openOrder) do
                local attrs = UIPanelWindows[f._name]
                if attrs and attrs.area == "right" and f:IsShown() then
                    f._points = {}
                    f._points[1] = {"TOPRIGHT", env.UIParent, "TOPRIGHT", rx, -100}
                    rx = rx - f._w - 10
                end
            end
        end
        _G.UpdateUIPanelPositions = function() relayout() end
        _G.ShowUIPanel = function(f)
            local found = false
            for _, o in ipairs(openOrder) do if o == f then found = true end end
            if not found then table.insert(openOrder, f) end
            f._shown = true
            UpdateUIPanelPositions(f)
        end
        _G.HideUIPanel = function(f)
            f._shown = false
            for i, o in ipairs(openOrder) do if o == f then table.remove(openOrder, i) break end end
            UpdateUIPanelPositions()
        end
    end

    ------------------------------------- managed containers (Mainline)
    if not opts.noManagedFrames then
        local rmc = newFrame("RightManagedFrameContainer", env.UIParent)
        rmc:SetSize(300, 800)
        rmc._points = { {"TOPRIGHT", env.UIParent, "TOPRIGHT", -45, -260} }
        _G.EditModeManagerFrame = {
            GetRightActionBars = function() return { _G.MultiBarRight, _G.MultiBarLeft } end,
            -- Secure Edit Mode code: re-pins default-position right bars.
            UpdateRightActionBarPositions = function()
                if _G.MultiBarRight then
                    _G.MultiBarRight._points = { {"RIGHT", env.UIParent, "RIGHT", -5, 0} }
                end
                ManageFramePositions()
            end,
        }
        _G.ManageFramePositions = function()
            -- FramePositionDelegate:ManageRightFrameContainer (secure; may
            -- run in combat). Bypasses the addon-side protection check.
            rmc._points = { {"TOPRIGHT", env.UIParent, "TOPRIGHT", -45, -260} }
            UpdateContainerFrameAnchors()
        end
        local cfc = newFrame("ContainerFrameContainer", env.UIParent)
        cfc:SetSize(W, H)
        cfc._points = { {"TOPLEFT", env.UIParent, "TOPLEFT", 0, 0} }
        env.bagsShown = {}
        _G.ContainerFrameSettingsManager = {}
        function ContainerFrameSettingsManager:GetBagsShown()
            if not self.bagsShown then self.bagsShown = env.bagsShown end
            return self.bagsShown
        end
        function ContainerFrameSettingsManager:MarkBagsShownDirty() self.bagsShown = nil end
        _G.UpdateContainerFrameAnchors = function()
            local prev
            for i, f in ipairs(ContainerFrameSettingsManager:GetBagsShown()) do
                f._points = {}
                if i == 1 then
                    f._points[1] = {"BOTTOMRIGHT", f._parent, "BOTTOMRIGHT", -4, 85}
                else
                    f._points[1] = {"BOTTOMRIGHT", prev, "TOPRIGHT", 0, 5}
                end
                prev = f
            end
        end
    end

    ------------------------------------------------------------- helpers
    function env.fire(event, ...)
        for f in pairs(env.eventFrames) do
            if f._events[event] then f:_fire("OnEvent", event, ...) end
        end
    end
    function env.flushTimers()
        local t = env.timers
        env.timers = {}
        for _, fn in ipairs(t) do fn() end
    end

    return env
end
