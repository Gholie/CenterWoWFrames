# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A World of Warcraft addon that re-anchors native Blizzard UI frames to a user-chosen aspect ratio (e.g. 16:9, 21:9), centered on screen. Targets retail WoW Patch 12.0 / Midnight (`## Interface: 120007`) — i.e. the post-"addon disarmament" API era.

> **Keep this in sync:** whenever you bump `## Interface:` in `CenterWoWFrames.toc`, update the version referenced above in the same change. The `.toc` is the source of truth; this doc must not drift from it.

There is no build, lint, or test tooling. This is a pure Lua addon; iteration is in-game. To test changes, the directory must live at `<WoW>/_retail_/Interface/AddOns/CenterWoWFrames/` (symlink the repo there) and reload with `/reload` or `/console reloadui`. In-game slash command is `/cwf` (see `Config.lua` for subcommands: `ratio`, `toggle`, `debug`, `reload`, `status`).

## Architecture

**The CenterFrame indirection.** The core trick is in `Core.lua`: a single invisible `CWF_CenterFrame` is created as a child of `UIParent`, sized to `(UIParent.height * targetRatio) × UIParent.height`, and pinned to `UIParent`'s CENTER. Every managed Blizzard frame has its anchor list rewritten so any reference to `UIParent` is replaced with `CenterFrame`. UIParent itself is **never** modified — this is a hard invariant. When the user changes ratio, only `CenterFrame`'s size changes; WoW's layout engine re-flows everything anchored to it for free.

**Capture-then-apply, not a fixed mapping.** `Capture(frame)` reads each frame's *current* `GetPoint(i)` values (whatever Blizzard or Edit Mode set) and replays them via `SetPoint`, substituting `UIParent → CenterFrame` *only* for anchors whose relativePoint contains `LEFT` or `RIGHT` (i.e. has a horizontal-edge component). `CENTER`, `TOP`, and `BOTTOM` anchors sit on UIParent's vertical axis — which CenterFrame already shares — so rewriting them would be a visual no-op and is skipped. This means the addon respects user Edit Mode customizations and leaves screen-horizontally-centered frames where they natively are.

**Two re-anchor paths, different purposes:**
- `CaptureAndApplyAll()` — re-reads anchors from Blizzard. Called on PLAYER_ENTERING_WORLD, EDIT_MODE_LAYOUTS_UPDATED, UI_SCALE_CHANGED, DISPLAY_SIZE_CHANGED. Always deferred one frame via `C_Timer.After(0, ...)` so Blizzard finishes its own anchoring first. If it bails out on `InCombatLockdown()`, it sets a module-local `captureDropped` flag so the request isn't silently lost.
- `ReapplyStored()` — replays anchors from `storedAnchors`, but *only* for the frames recorded in the module-local `failedApplies` set (frames whose most recent `Apply` failed, typically protected frames skipped mid-combat). Frames that already applied cleanly are left alone, so legitimate mid-combat Blizzard repositioning (vehicle bar swaps, stance bar reflow, objective tracker collapse, ...) isn't reverted every time combat ends. Does not re-read from Blizzard.

On `PLAYER_REGEN_ENABLED`, Core.lua first applies any ratio/toggle change Config.lua deferred during combat (`CWF._pendingGeometryUpdate`), then calls `CaptureAndApplyAll()` if `captureDropped` is set or `storedAnchors` is still empty, otherwise `ReapplyStored()` — only after that does it call `AdjustOpenPanels()`.

**Combat safety.** Both re-anchor paths early-return on `InCombatLockdown()`. The per-frame `Apply` call is wrapped in `pcall` so a single protected frame failure can't break the loop; `storedAnchors[name]` is only updated on success (a frame that fails mid-combat keeps its last-known-good anchors), and its name is tracked in `failedApplies` until a retry succeeds. If both the apply and the backup-restore `pcall` fail, `Apply` prints a one-line `[CWF]` warning instead of leaving the corruption silent. `/cwf ratio` and `/cwf toggle` also respect combat lockdown: they save the db change immediately but defer the actual `UpdateCenterFrameGeometry()` call (and the panel-manager poke it triggers) to the next `PLAYER_REGEN_ENABLED` via `CWF._pendingGeometryUpdate`.

**Event lifecycle.** `ADDON_LOADED` does *only* `InitDB()` (SavedVariables are valid here, but UI work is not yet safe). `PLAYER_LOGIN` is the first event where touching UI (e.g. building debug-border textures) is safe. The split matters — moving UI work into ADDON_LOADED will break.

**The UI Panel subsystem (`UIPanels.lua`) is separate from the FRAME_LIST capture-and-apply.** Frames managed by Blizzard's `Blizzard_UIParentPanelManager` — `CharacterFrame`, `SpellBookFrame`, `BankFrame`, `MerchantFrame`, `MailFrame`, `PlayerTalentFrame`, `WorldMapFrame`, `AchievementFrame`, etc. — are not statically anchored. They are repositioned on every show/hide/move by a forbidden `FramePositionDelegate` frame, which assigns each open `area = "left" | "right"` panel a slot: the outermost panel on a side anchors straight to UIParent's edge, and each subsequent panel on that side anchors relative to the *actual current edge* of the panel ahead of it (a cascade). Adding these to `FRAME_LIST` doesn't work: the panel manager re-runs on every panel state change and overwrites our anchors. Instead, `UIPanels.lua` hooks the public global wrappers (`ShowUIPanel`, `HideUIPanel`, `UpdateUIPanelPositions`) via `hooksecurefunc` and, after Blizzard's pass, shifts panels inward by `(UIParent.width - CenterFrame.width) / 2` *overlap-aware*, processing each side outermost-first (edges compared in screen space): the outermost panel always gets the shift; each panel behind it is shifted only if it would now overlap the post-shift panel ahead of it — i.e. Blizzard cascaded it off pre-shift geometry that pass. Panels already cascaded off shifted geometry are left alone, so the inset is never double-counted regardless of whether the delegate's pass read canonical or live positions. This also means `WorldMapFrame`/`AchievementFrame` (registered as area "left" in some Midnight builds) are treated like any other left panel rather than force-centered: force-centering one while it still occupied a left slot desynced Blizzard's slot accounting and scrambled every other open panel's position. Center/full/doublewide/centerOrLeft panels are intentionally not adjusted (center panels use `TOP`-anchor, no horizontal offset to fix; the others are out of scope for v1). When `CenterFrame` geometry changes, `UpdateCenterFrameGeometry()` calls `UpdateUIPanelPositions(nil)` to make Blizzard reflow open panels through our hook. The system reads `UIPanelWindows[name].area` directly — that table is a normal global in 12.0.

## File load order

Defined in `CenterWoWFrames.toc`: `FrameList.lua → Config.lua → Core.lua → UIPanels.lua`. Load-time only. `Config.lua` references `CWF.CenterFrame` (created in `Core.lua`) inside `EnsureBorderLines`, but that function only runs at PLAYER_LOGIN or later. `UIPanels.lua` calls `hooksecurefunc` on Blizzard panel-manager globals at top level, which requires `Blizzard_UIParentPanelManager` to already be loaded — true for system addons by the time user addons execute. If you add new top-level code that touches `CWF.CenterFrame`, it must go in `Core.lua` or be deferred to PLAYER_LOGIN.

## Adding a new managed frame

Append to the `CWF.FRAME_LIST` table in `FrameList.lua`. Unknown/missing globals are silently skipped (`if frame and frame.GetNumPoints ...`), so it's safe to list frames that may not exist in every game state (boss frames, arena frames, etc.).

## SavedVariables

`CenterWoWFramesDB` (declared in the .toc). Defaults live in `CWF.DB_DEFAULTS` in `Config.lua`; `InitDB()` shallow-merges defaults into the saved table so adding a new default key is non-destructive for existing users.
