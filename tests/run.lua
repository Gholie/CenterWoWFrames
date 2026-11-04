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
local function loadAddon(opts, setup)
    local sandbox = setmetatable({}, { __index = _G })
    sandbox._G = sandbox

    local mockChunk = assert(loadfile("tests/mock_wow.lua"))
    setfenv(mockChunk, sandbox)
    local env = mockChunk()(opts)
    env.G = sandbox

    if setup then setfenv(setup, sandbox); setup(env) end

    local toc = assert(parseToc(ADDON .. ".toc"), "main .toc missing")
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

scenarios["toc files are well-formed and reference existing files"] = function()
    -- Probe known flavor suffixes rather than shelling out, so this runs in
    -- embedded Lua runtimes without io.popen.
    local tocs = {}
    for _, suffix in ipairs({ "", "_Mainline", "_Camelot", "_Forever", "_Standard",
                              "_Vanilla", "_Classic", "_Mists", "_Cata" }) do
        local name = ADDON .. suffix .. ".toc"
        if readFile(name) then table.insert(tocs, name) end
    end
    check(#tocs > 0, "no .toc files found")
    local mainFiles
    for _, name in ipairs(tocs) do
        check(name:sub(1, #ADDON) == ADDON, name .. ": TOC must be named after the addon folder")
        local toc = parseToc(name)
        check(#toc.interface > 0, name .. ": missing ## Interface")
        for _, n in ipairs(toc.interface) do
            check(n:match("^%d+$") ~= nil, name .. ": non-numeric interface '" .. n .. "'")
        end
        check(toc.directives.SavedVariables == "CenterWoWFramesDB", name .. ": SavedVariables mismatch")
        for _, file in ipairs(toc.files) do
            check(readFile(file) ~= nil, name .. ": lists missing file " .. file)
        end
        local joined = table.concat(toc.files, ",")
        if mainFiles then
            check(joined == mainFiles, name .. ": file list differs from " .. tocs[1])
        else
            mainFiles = joined
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

scenarios["loads cleanly on a client without Edit Mode or panel manager"] = function()
    local env = loadAddon({ noEditMode = true, noPanelManager = true, noSecretValues = true }, standardFrames)
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
