local _, CWF = ...

-- Native Blizzard frames to re-anchor relative to the virtual center frame.
-- Unknown or missing frame names are silently skipped, so one list serves
-- both retail and WoW Forever (some entries exist in only one client).
CWF.FRAME_LIST = {
    -- Action bars (protected in combat — applied on PLAYER_REGEN_ENABLED if skipped)
    "MainActionBar",
    "MultiBarBottomLeft",
    "MultiBarBottomRight",
    "MultiBarLeft",
    "MultiBarRight",
    "MultiBar5",
    "MultiBar6",
    "MultiBar7",
    "PetActionBar",
    "StanceBar",
    "PossessActionBar",
    "MultiCastActionBarFrame",  -- shaman totem bar (WoW Forever only)
    -- Micro menu + bags: in retail's default layout MicroMenuContainer and
    -- BagsBar both anchor to MicroButtonAndBagsBar, which is the frame
    -- actually pinned to UIParent BOTTOMRIGHT. MicroMenu itself is a child
    -- of MicroMenuContainer (never anchored to UIParent), so it's not listed.
    -- In WoW Forever's classic layout MicroMenuContainer is BOTTOM-anchored
    -- and the others chain off it, so these are no-ops there unless moved.
    "MicroButtonAndBagsBar",
    "MicroMenuContainer",
    "BagsBar",
    "OverrideActionBar",
    "ExtraActionBarFrame",
    "ZoneAbilityFrame",

    -- Unit frames
    "PlayerFrame",
    "TargetFrame",
    "FocusFrame",
    "PartyFrame",
    "CompactPartyFrame",

    -- Boss / Arena. Boss1-5TargetFrame are children of BossTargetFrameContainer
    -- (never anchored to UIParent), so the container is what's listed. By
    -- default both containers sit inside RightManagedFrameContainer (handled
    -- by ManagedContainers.lua); listing them covers the user-placed case,
    -- where Edit Mode reparents them to UIParent. CompactArenaFrame is
    -- retail-only (not loaded in WoW Forever).
    "BossTargetFrameContainer",
    "CompactArenaFrame",

    -- Minimap
    "MinimapCluster",

    -- Objective tracker
    "ObjectiveTrackerFrame",

    -- Chat frames are intentionally NOT managed here: ChatFrame1-N are positioned
    -- by the FCF_* dock manager (FCF_SavePositionAndDimensions, FCF_DockUpdate),
    -- which fights direct SetPoint calls. Let users position chat via Edit Mode.

    -- Auras
    "BuffFrame",
    "DebuffFrame",

    -- Cast bars / swing timers (swing timers are WoW Forever only)
    "PlayerCastingBarFrame",
    "SwingTimerMainHandFrame",
    "SwingTimerOffHandFrame",
    "SwingTimerRangedFrame",

    -- Status / XP / Rep / Honor bars (all children of StatusTrackingBarManager;
    -- the manager itself is the anchored parent frame)
    "StatusTrackingBarManager",

    -- Encounter / raid
    "EncounterBar",
    -- CompactRaidFrameManager is intentionally NOT managed: its collapsed tab is
    -- designed to hug the left screen edge, so re-anchoring it to CenterFrame
    -- would float it in the middle of the play area.

    -- Alerts and floating UI
    "AlertFrame",
    "TalkingHeadFrame",
    "RaidWarningFrame",

    -- Misc
    "LootFrame",
    "DurabilityFrame",
    "VehicleSeatIndicator",
    "ZoneTextFrame",
    "SubZoneTextFrame",
    "UIErrorsFrame",
    "TicketStatusFrame",
}
