# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A World of Warcraft addon that re-anchors native Blizzard UI frames to a user-chosen aspect ratio (e.g. 16:9, 21:9), centered on screen. Targets retail WoW Patch 12.0 / Midnight (`## Interface: 120005`) — i.e. the post-"addon disarmament" API era.

There is no build, lint, or test tooling. This is a pure Lua addon; iteration is in-game. To test changes, the directory must live at `<WoW>/_retail_/Interface/AddOns/CenterWoWFrames/` (symlink the repo there) and reload with `/reload` or `/console reloadui`. In-game slash command is `/cwf` (see `Config.lua` for subcommands: `ratio`, `toggle`, `debug`, `reload`, `status`).

## Architecture

**The CenterFrame indirection.** The core trick is in `Core.lua`: a single invisible `CWF_CenterFrame` is created as a child of `UIParent`, sized to `(UIParent.height * targetRatio) × UIParent.height`, and pinned to `UIParent`'s CENTER. Every managed Blizzard frame has its anchor list rewritten so any reference to `UIParent` is replaced with `CenterFrame`. UIParent itself is **never** modified — this is a hard invariant. When the user changes ratio, only `CenterFrame`'s size changes; WoW's layout engine re-flows everything anchored to it for free.

**Capture-then-apply, not a fixed mapping.** `Capture(frame)` reads each frame's *current* `GetPoint(i)` values (whatever Blizzard or Edit Mode set) and replays them via `SetPoint`, substituting `UIParent → CenterFrame` *only* for anchors whose relativePoint contains `LEFT` or `RIGHT` (i.e. has a horizontal-edge component). `CENTER`, `TOP`, and `BOTTOM` anchors sit on UIParent's vertical axis — which CenterFrame already shares — so rewriting them would be a visual no-op and is skipped. This means the addon respects user Edit Mode customizations and leaves screen-horizontally-centered frames where they natively are.

**Two re-anchor paths, different purposes:**
- `CaptureAndApplyAll()` — re-reads anchors from Blizzard. Called on PLAYER_ENTERING_WORLD, EDIT_MODE_LAYOUTS_UPDATED, UI_SCALE_CHANGED, DISPLAY_SIZE_CHANGED. Always deferred one frame via `C_Timer.After(0, ...)` so Blizzard finishes its own anchoring first.
- `ReapplyStored()` — replays the *already-captured* anchors from `storedAnchors`. Called on PLAYER_REGEN_ENABLED to catch protected frames (action bars, unit frames) that were skipped because the previous capture happened mid-combat. Do not re-read from Blizzard here.

**Combat safety.** Both paths early-return on `InCombatLockdown()`. The per-frame `Apply` call is wrapped in `pcall` so a single protected frame failure can't break the loop, and `storedAnchors[name]` is only updated on success — meaning a frame that fails mid-combat keeps its last-known-good anchors for the next ReapplyStored.

**Event lifecycle.** `ADDON_LOADED` does *only* `InitDB()` (SavedVariables are valid here, but UI work is not yet safe). `PLAYER_LOGIN` is the first event where touching UI (e.g. building debug-border textures) is safe. The split matters — moving UI work into ADDON_LOADED will break.

**The UI Panel subsystem (`UIPanels.lua`) is separate from the FRAME_LIST capture-and-apply.** Frames managed by Blizzard's `Blizzard_UIParentPanelManager` — `CharacterFrame`, `SpellBookFrame`, `BankFrame`, `MerchantFrame`, `MailFrame`, `PlayerTalentFrame`, etc. — are not statically anchored. They are repositioned on every show/hide/move by a forbidden `FramePositionDelegate` frame, which always anchors `area = "left" | "right"` panels to UIParent's edge. Adding these to `FRAME_LIST` doesn't work: the panel manager re-runs on every panel state change and overwrites our anchors. Instead, `UIPanels.lua` hooks the public global wrappers (`ShowUIPanel`, `HideUIPanel`, `UpdateUIPanelPositions`) via `hooksecurefunc` and shifts each visible "left"/"right" panel inward by `(UIParent.width - CenterFrame.width) / 2` after Blizzard's pass. Center/full/doublewide/centerOrLeft panels are intentionally not adjusted (center panels use `TOP`-anchor, no horizontal offset to fix; the others are out of scope for v1). When `CenterFrame` geometry changes, `UpdateCenterFrameGeometry()` calls `UpdateUIPanelPositions(nil)` to make Blizzard reflow open panels through our hook. The system reads `UIPanelWindows[name].area` directly — that table is a normal global in 12.0.

## File load order

Defined in `CenterWoWFrames.toc`: `FrameList.lua → Config.lua → Core.lua → UIPanels.lua`. Load-time only. `Config.lua` references `CWF.CenterFrame` (created in `Core.lua`) inside `EnsureBorderLines`, but that function only runs at PLAYER_LOGIN or later. `UIPanels.lua` calls `hooksecurefunc` on Blizzard panel-manager globals at top level, which requires `Blizzard_UIParentPanelManager` to already be loaded — true for system addons by the time user addons execute. If you add new top-level code that touches `CWF.CenterFrame`, it must go in `Core.lua` or be deferred to PLAYER_LOGIN.

## Adding a new managed frame

Append to the `CWF.FRAME_LIST` table in `FrameList.lua`. Unknown/missing globals are silently skipped (`if frame and frame.GetNumPoints ...`), so it's safe to list frames that may not exist in every game state (boss frames, arena frames, etc.).

## SavedVariables

`CenterWoWFramesDB` (declared in the .toc). Defaults live in `CWF.DB_DEFAULTS` in `Config.lua`; `InitDB()` shallow-merges defaults into the saved table so adding a new default key is non-destructive for existing users.
