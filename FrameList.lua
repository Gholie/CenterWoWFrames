local _, CWF = ...

-- Native Blizzard frames to re-anchor relative to the virtual center frame.
-- Unknown or missing frame names are silently skipped.
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
    "MicroMenu",
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

    -- Boss / Arena
    "Boss1TargetFrame",
    "Boss2TargetFrame",
    "Boss3TargetFrame",
    "Boss4TargetFrame",
    "Boss5TargetFrame",
    "ArenaEnemyFrames",

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
    "TemporaryEnchantFrame",

    -- Cast bars
    "PlayerCastingBarFrame",

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
    "RaidBossEmoteFrame",

    -- Misc
    "LootFrame",
    "DurabilityFrame",
    "ZoneTextFrame",
    "SubZoneTextFrame",
    "UIErrorsFrame",
    "TicketStatusFrame",
}
