-- Offline smoke tests for CenterWoWFrames. Run from the repo root:
--   lua5.1 tests/run.lua
-- Each scenario loads the addon fresh into a sandboxed global table backed
-- by tests/mock_wow.lua, so no game client is needed. This does NOT replace
-- in-game testing — it catches load-order errors, nil derefs, and logic
-- regressions in the anchor/panel math.

local ADDON = "CenterWoWFrames"
local failures, passes = 0, 0

local function check(cond, msg)
    if cond then passes = passes + 1
    else failures = failures + 1; print("  FAIL: " .. msg) end
end

local function near(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.01 end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

-- Parse a .toc: returns {interface = {numbers}, files = {...}, directives = {}}
local function parseToc(path)
    local src = readFile(path)
    if not src then return nil end
    local toc = { interface = {}, files = {}, directives = {} }
    for line in (src .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local k, v = line:match("^##%s*([^:]+):%s*(.-)%s*$")
        if k then
            toc.directives[k] = v
            if k == "Interface" then
                for n in v:gmatch("[^,%s]+") do table.insert(toc.interface, n) end
            end
        elseif line:match("%S") and not line:match("^#") then
            table.insert(toc.files, (line:gsub("^%s+", ""):gsub("%s+$", "")))
        end
    end
    return toc
end

-- Load the addon into a fresh sandbox. setup(env) runs after the mock is
-- built but before addon files load (create Blizzard frames there).
local function loadAddon(opts, setup, tocName)
    local sandbox = setmetatable({}, { __index = _G })
    sandbox._G = sandbox

    local mockChunk = assert(loadfile("tests/mock_wow.lua"))
    setfenv(mockChunk, sandbox)
    local env = mockChunk()(opts)
    env.G = sandbox

    if setup then setfenv(setup, sandbox); setup(env) end

    tocName = tocName or (ADDON .. ".toc")
    local toc = assert(parseToc(tocName), tocName .. " missing")
    local ns = {}
    for _, file in ipairs(toc.files) do
        local chunk, err = loadfile(file)
        if not chunk then error("syntax error in " .. file .. ": " .. tostring(err)) end
        setfenv(chunk, sandbox)
        chunk(ADDON, ns)
    end
    env.ns = ns
    return env
end

local function login(env)
    env.fire("ADDON_LOADED", ADDON)
    env.fire("PLAYER_LOGIN")
    env.fire("PLAYER_ENTERING_WORLD", true, false)
    env.flushTimers()
end

local function standardFrames(env)
    local UIParent = env.UIParent
    local function mk(name, pt, relPt, x, w, protected)
        local f = env.newFrame(name, UIParent)
        f:SetSize(w or 200, 50)
        f:SetPoint(pt, UIParent, relPt, x, 0)
        f._protected = protected or false
        return f
    end
    mk("MainActionBar", "BOTTOM", "BOTTOM", 0, 600, true)
    mk("PlayerFrame", "TOPLEFT", "TOPLEFT", 20, 230)
    mk("TargetFrame", "TOPLEFT", "TOPLEFT", 250, 230)
    mk("MinimapCluster", "TOPRIGHT", "TOPRIGHT", -10, 220)
    mk("MultiBarRight", "RIGHT", "RIGHT", -5, 40, true)
    mk("UIErrorsFrame", "TOP", "TOP", 0, 512)
end

local scenarios = {}

-- Flavor TOCs the client picks over the unsuffixed one. Interface numbers
-- each must use (Lua pattern), and the client they target.
local FLAVOR_TOCS = {
    { suffix = "_Forever", interface = "^16%d%d%d$", client = "WoW Forever" },
}

scenarios["toc files are well-formed and deploy to every client"] = function()
    local mainName = ADDON .. ".toc"
    local main = parseToc(mainName)
    check(main ~= nil, "main " .. mainName .. " missing")
    if not main then return end

    local tocs = { { name = mainName, toc = main } }
    for _, flavor in ipairs(FLAVOR_TOCS) do
        local name = ADDON .. flavor.suffix .. ".toc"
        local toc = parseToc(name)
        check(toc ~= nil, name .. " missing (needed for " .. flavor.client .. ")")
        if toc then
            table.insert(tocs, { name = name, toc = toc })
            check(#toc.interface > 0, name .. ": missing ## Interface")
            local mainSet = {}
            for _, n in ipairs(main.interface) do mainSet[n] = true end
            for _, n in ipairs(toc.interface) do
                check(n:match(flavor.interface) ~= nil, name .. ": interface " .. n .. " is not a " .. flavor.client .. " interface")
                -- BigWigsMods/packager only reads game versions from the
                -- unsuffixed TOC (and _Camelot, not _Forever). If the main
                -- TOC drops a flavor's interface, releases silently stop
                -- being uploaded for that client.
                check(mainSet[n], mainName .. " must also list " .. n .. " so the packager uploads for " .. flavor.client)
            end
        end
    end

    local hasRetail = false
    for _, n in ipairs(main.interface) do
        if n:match("^1[1-9]%d%d%d%d$") then hasRetail = true end
    end
    check(hasRetail, mainName .. ": no retail (12xxxx-style) interface")

    for _, entry in ipairs(tocs) do
        local name, toc = entry.name, entry.toc
        for _, n in ipairs(toc.interface) do
            check(n:match("^%d+$") ~= nil, name .. ": non-numeric interface '" .. n .. "'")
        end
        for _, key in ipairs({ "Title", "SavedVariables", "Version", "X-Curse-Project-ID" }) do
            check(toc.directives[key] == main.directives[key], name .. ": ## " .. key .. " differs from " .. mainName)
        end
        check(#toc.files > 0, name .. ": lists no files")
        for _, file in ipairs(toc.files) do
            check(readFile(file) ~= nil, name .. ": lists missing file " .. file)
        end
    end
end

scenarios["every flavor TOC loads and re-anchors"] = function()
    for _, flavor in ipairs(FLAVOR_TOCS) do
        local name = ADDON .. flavor.suffix .. ".toc"
        if readFile(name) then
            local env = loadAddon({}, standardFrames, name)
            login(env)
            local _, rel = env.G.PlayerFrame:GetPoint(1)
            check(rel == env.G.CWF_CenterFrame, name .. ": PlayerFrame should anchor to CenterFrame")
        end
    end
end

scenarios["login re-anchors edge frames to CenterFrame, leaves centered ones"] = function()
    local env = loadAddon({}, standardFrames)
    login(env)
    local G = env.G
    local cf = G.CWF_CenterFrame
    check(near(cf:GetWidth(), 1440 * 16 / 9), "CenterFrame width should be 16:9 of height, got " .. tostring(cf:GetWidth()))
    local inset = (3440 - 2560) / 2
    local _, rel = G.PlayerFrame:GetPoint(1)
    check(rel == cf, "PlayerFrame should anchor to CenterFrame")
    check(near(G.PlayerFrame:GetLeft(), inset + 20), "PlayerFrame left should be inset+20, got " .. tostring(G.PlayerFrame:GetLeft()))
    check(near(G.MinimapCluster:GetRight(), 3440 - inset - 10), "MinimapCluster right edge wrong")
    _, rel = G.MainActionBar:GetPoint(1)
    check(rel == G.UIParent, "MainActionBar (BOTTOM anchor) must stay on UIParent")
    _, rel = G.UIErrorsFrame:GetPoint(1)
    check(rel == G.UIParent, "UIErrorsFrame (TOP anchor) must stay on UIParent")
    check(G.UIParent:GetNumPoints() == 0 and near(G.UIParent:GetWidth(), 3440), "UIParent must never be modified")
end

scenarios["capture requested in combat is deferred until regen"] = function()
    local env = loadAddon({}, standardFrames)
    env.fire("ADDON_LOADED", ADDON)
    env.fire("PLAYER_LOGIN")
    env.combat = true
    env.fire("PLAYER_ENTERING_WORLD", false, true)
    env.flushTimers()
    local G = env.G
    local _, rel = G.MultiBarRight:GetPoint(1)
    check(rel == G.UIParent, "nothing should move during combat")
    env.combat = false
    env.fire("PLAYER_REGEN_ENABLED")
    _, rel = G.MultiBarRight:GetPoint(1)
    check(rel == G.CWF_CenterFrame, "MultiBarRight should be re-anchored after combat")
end

scenarios["slash commands: ratio, toggle, status, combat deferral"] = function()
    local env = loadAddon({}, standardFrames)
    login(env)
    local G = env.G
    local slash = G.SlashCmdList.CENTERWOWFRAMES
    check(type(slash) == "function", "/cwf handler missing")
    slash("ratio 21:9")
    check(near(G.CWF_CenterFrame:GetWidth(), 3360), "21:9 width wrong")
    slash("ratio 32:9")
    check(near(G.CWF_CenterFrame:GetWidth(), 3440), "32:9 on a 3440x1440 screen should clamp to full width")
    slash("ratio 4:3")
    check(near(G.CWF_CenterFrame:GetWidth(), 1920), "4:3 width wrong")
    slash("ratio banana")
    check(near(G.CWF_CenterFrame:GetWidth(), 1920), "bad input must not change ratio")
    slash("toggle")
    check(near(G.CWF_CenterFrame:GetWidth(), 3440), "disabled should match UIParent")
    env.combat = true
    slash("toggle")
    check(near(G.CWF_CenterFrame:GetWidth(), 3440), "toggle in combat must defer geometry")
    env.combat = false
    env.fire("PLAYER_REGEN_ENABLED")
    check(near(G.CWF_CenterFrame:GetWidth(), 1920), "deferred toggle should apply on regen")
    slash("status"); slash("debug"); slash("debug"); slash("reload"); slash("")
    check(G.CenterWoWFramesDB.ratioWidth == 4 and G.CenterWoWFramesDB.ratioHeight == 3, "db not persisted")
end

scenarios["UI panels shift inward, cascade without overlap, reflow on close"] = function()
    local env = loadAddon({}, function(env)
        standardFrames(env)
        for _, n in ipairs({ "CharacterFrame", "SpellBookFrame" }) do
            local f = env.newFrame(n, env.UIParent); f:SetSize(400, 500); f._shown = false
            UIPanelWindows[n] = { area = "left" }
        end
        local m = env.newFrame("MerchantFrame", env.UIParent); m:SetSize(350, 500); m._shown = false
        UIPanelWindows.MerchantFrame = { area = "right" }
    end)
    login(env)
    local G = env.G
    local inset = (3440 - 2560) / 2
    G.ShowUIPanel(G.CharacterFrame)
    check(near(G.CharacterFrame:GetLeft(), inset + 16), "CharacterFrame should shift by inset, left=" .. tostring(G.CharacterFrame:GetLeft()))
    G.ShowUIPanel(G.SpellBookFrame)
    check(near(G.CharacterFrame:GetLeft(), inset + 16), "CharacterFrame must not double-shift")
    check(G.SpellBookFrame:GetLeft() >= G.CharacterFrame:GetRight() - 0.5, "SpellBookFrame overlaps CharacterFrame")
    G.HideUIPanel(G.CharacterFrame)
    check(near(G.SpellBookFrame:GetLeft(), inset + 16), "SpellBookFrame should become outermost and shift, left=" .. tostring(G.SpellBookFrame:GetLeft()))
    G.ShowUIPanel(G.MerchantFrame)
    check(near(G.MerchantFrame:GetRight(), 3440 - inset - 16), "MerchantFrame right edge should shift inward")
end

scenarios["right-managed container (boss frames) follows CenterFrame, deferred in combat"] = function()
    local env = loadAddon({}, standardFrames)
    login(env)
    local G = env.G
    local inset = (3440 - 2560) / 2
    local rmc = G.RightManagedFrameContainer
    local _, rel = rmc:GetPoint(1)
    check(rel == G.CWF_CenterFrame, "container should be re-anchored at login capture")
    G.ManageFramePositions()
    _, rel = rmc:GetPoint(1)
    check(rel == G.CWF_CenterFrame, "container should be re-anchored after ManageFramePositions")
    check(near(rmc:GetRight(), 3440 - inset - 45), "container right edge wrong: " .. tostring(rmc:GetRight()))
    -- Encounter start: secure code re-pins it mid-combat; container is
    -- implicitly protected (secure Boss unit buttons inside).
    rmc._protected = true
    env.combat = true
    G.ManageFramePositions()
    _, rel = rmc:GetPoint(1)
    check(rel == G.UIParent, "protected container must not be moved in combat")
    env.combat = false
    env.fire("PLAYER_REGEN_ENABLED")
    _, rel = rmc:GetPoint(1)
    check(rel == G.CWF_CenterFrame, "container should be fixed after combat")
end

scenarios["right action bars re-pinned by Edit Mode follow CenterFrame"] = function()
    local env = loadAddon({}, standardFrames)
    login(env)
    local G = env.G
    G.EditModeManagerFrame.UpdateRightActionBarPositions()
    local _, rel = G.MultiBarRight:GetPoint(1)
    check(rel == G.CWF_CenterFrame, "MultiBarRight should be re-anchored after Edit Mode re-pins it")
    _, rel = G.RightManagedFrameContainer:GetPoint(1)
    check(rel == G.CWF_CenterFrame, "right container should stay on CenterFrame")
    env.combat = true  -- protected bars: skipped in combat, fixed on regen
    G.EditModeManagerFrame.UpdateRightActionBarPositions()
    _, rel = G.MultiBarRight:GetPoint(1)
    check(rel == G.UIParent, "protected bar must not be moved in combat")
    env.combat = false
    env.fire("PLAYER_REGEN_ENABLED")
    _, rel = G.MultiBarRight:GetPoint(1)
    check(rel == G.CWF_CenterFrame, "bar should be fixed after combat")
end

scenarios["bags open inside the center zone"] = function()
    local env = loadAddon({}, standardFrames)
    login(env)
    local G = env.G
    local inset = (3440 - 2560) / 2
    local b1 = env.newFrame("ContainerFrame1", G.ContainerFrameContainer); b1:SetSize(200, 300)
    local b2 = env.newFrame("ContainerFrame2", G.ContainerFrameContainer); b2:SetSize(200, 300)
    env.bagsShown = { b1, b2 }
    -- Outside Blizzard's own pass the addon must not fill the lazy cache.
    env.ns.AdjustManagedContainers()
    check(rawget(G.ContainerFrameSettingsManager, "bagsShown") == nil, "addon must not populate Blizzard's bagsShown cache")
    G.UpdateContainerFrameAnchors()
    local _, rel = b1:GetPoint(1)
    check(rel == G.CWF_CenterFrame, "first bag should anchor to CenterFrame")
    check(near(b1:GetRight(), 3440 - inset - 4), "first bag right edge wrong: " .. tostring(b1:GetRight()))
    _, rel = b2:GetPoint(1)
    check(rel == b1, "later bags keep chaining off the first")
    env.combat = true  -- bags aren't protected: still fixed in combat
    G.UpdateContainerFrameAnchors()
    _, rel = b1:GetPoint(1)
    check(rel == G.CWF_CenterFrame, "bags opened in combat should still be centered")
end

scenarios["Forever spellbook: live UIPanelLayout-area attribute wins over UIPanelWindows"] = function()
    local env = loadAddon({}, function(env)
        standardFrames(env)
        local f = env.newFrame("PlayerSpellsFrame", env.UIParent); f:SetSize(400, 500)
        UIPanelWindows.PlayerSpellsFrame = { area = "centerOrLeft" }
    end)
    login(env)
    local G = env.G
    local f = G.PlayerSpellsFrame
    local inset = (3440 - 2560) / 2
    local function blizzardLeftSlot() f._points = { {"TOPLEFT", G.UIParent, "TOPLEFT", 16, -100} } end

    -- Not yet shown through the panel manager: no layout attributes, so the
    -- registered "centerOrLeft" applies and it is left alone.
    blizzardLeftSlot()
    env.ns.AdjustOpenPanels()
    check(near(f:GetLeft(), 16), "centerOrLeft panel must not be shifted, left=" .. tostring(f:GetLeft()))

    -- Minimized spellbook: SetUIPanelAttribute flipped the live area to "left".
    f:SetAttribute("UIPanelLayout-defined", true)
    f:SetAttribute("UIPanelLayout-area", "left")
    blizzardLeftSlot()
    env.ns.AdjustOpenPanels()
    check(near(f:GetLeft(), inset + 16), "minimized spellbook should shift as a left panel, left=" .. tostring(f:GetLeft()))
end

scenarios["loads cleanly on a client without Edit Mode or panel manager"] = function()
    local env = loadAddon({ noEditMode = true, noPanelManager = true, noSecretValues = true, noManagedFrames = true }, standardFrames)
    login(env)
    local _, rel = env.G.PlayerFrame:GetPoint(1)
    check(rel == env.G.CWF_CenterFrame, "core re-anchoring should still work")
end

-- Run
local names = {}
for name in pairs(scenarios) do table.insert(names, name) end
table.sort(names)
for _, name in ipairs(names) do
    print("* " .. name)
    local ok, err = pcall(scenarios[name])
    if not ok then failures = failures + 1; print("  ERROR: " .. tostring(err)) end
end
print(string.format("\n%d checks passed, %d failed", passes, failures))
if failures > 0 then os.exit(1) end
