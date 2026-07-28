--[[
Supernote backend (Ratta A5X2 family — Nomad / Manta / etc.): the firmware
paints stroke ink to the EPDC overlay via the `service_myservice` binder, so
KOReader does not need a second SurfaceView, lockCanvas, or kernel DHW
toggle the way Sony does. The plugin's job is just to configure the
firmware pen, gate the framebuffer so mid-stroke Lua refreshes don't
fight the EPDC ink, and clear the firmware overlay once the finished
stroke has been baked into Screen.bb (in scheduleDelayedRefresh).

All firmware comms run through lib/supernote_ink.lua, a pure-Lua/JNI
binder client. No KOReader launcher patches are required — drop this
plugin onto an official KOReader install and the Supernote path lights
up at runtime if the binder is present.
--]]

local Device = require("device")
local logger = require("logger")
local common = require("lib/backends/common")
local SupernoteInk = require("lib/supernote_ink")

local Supernote = { name = "supernote" }

-- Convert KOReader pen width (3..9 logical pixels) to Supernote EMR units.
-- The firmware penSizeArray for Nomad's Needle pen runs 200..2400 with the
-- thin/mid/thick triples around 200/900/2400. KOReader's pixel widths are
-- small (3-9 logical px), so we hug the thin end of that row:
--   w=3 -> 300, w=5 -> 500, w=7 -> 700, w=9 -> 900.
-- Earlier formula (w*200+200) put w=3 at 800, which visibly over-inked
-- compared to KOReader's drawLineSegment width.
local function pencilWidthToSupernoteEmr(width)
    local w = tonumber(width) or 3
    local emr = math.floor(w * 100)
    if emr < 200 then emr = 200 end
    if emr > 1200 then emr = 1200 end
    return emr
end

function Supernote.setup(p)
    if not Device:isAndroid() then return end
    if not SupernoteInk.isAvailable() then
        logger.info("Pencil: Supernote ink unavailable")
        return
    end
    -- Claim the EPDC pen ownership for KOReader. Both calls are required:
    -- sendWriteAppInfo tells the firmware "this app owns pen events",
    -- enableFullUiAuto(true) makes ink paint everywhere on screen (not
    -- just inside the firmware's whitelisted apps).
    SupernoteInk.sendWriteAppInfo()
    SupernoteInk.enableFullUiAuto(true)
    SupernoteInk.clearDisableAreas()

    p.supernote_ink_active = true
    p.supernote_last_tool = nil  -- forces applyPen() to push state next call
    Supernote.applyPen(p)
    logger.info("Pencil: Supernote ink enabled")
end

function Supernote.teardown(p)
    if not p.supernote_ink_active then return end
    -- Disable ink everywhere while pencil is off so the firmware doesn't
    -- keep painting under finger taps in the document view, then release
    -- our enableFullUiAuto claim.
    local Screen = Device.screen
    if Screen then
        SupernoteInk.setFullScreenDisable(Screen:getWidth(), Screen:getHeight())
    end
    SupernoteInk.clearAll()
    SupernoteInk.enableFullUiAuto(false)
    p.supernote_ink_active = false
    p.supernote_last_tool = nil
    logger.info("Pencil: Supernote ink disabled")
end

-- Push the current pencil tool (pen tip vs eraser) down to the firmware.
-- Called whenever the effective tool may have changed: on plugin start,
-- on slot.tool flipping in handleStylusSlot, and on the menu callbacks
-- that switch between TOOL_PEN and TOOL_ERASER.
function Supernote.applyPen(p)
    if not p.supernote_ink_active then return end
    -- Effective tool: if the physical eraser end / button is engaged, the
    -- firmware should show the eraser shape; otherwise use the menu tool.
    local effective
    if p.eraser_button_active or p.eraser_tool_active
            or p.current_tool == common.TOOL_ERASER then
        effective = common.TOOL_ERASER
    else
        effective = p.current_tool
    end
    if effective == p.supernote_last_tool then return end
    p.supernote_last_tool = effective
    if effective == common.TOOL_ERASER then
        local er_width = (p.tool_settings[common.TOOL_ERASER] or {}).width or 20
        SupernoteInk.setEraser(false, math.max(400, er_width * 50))
        logger.dbg("Pencil: Supernote pen -> eraser, width=", er_width)
    else
        local pen = p.tool_settings[common.TOOL_PEN] or {}
        -- Pen type 10 = Needle (ballpoint, uniform width). This matches
        -- KOReader's drawLineSegment which paints uniform-width round-cap
        -- lines — Ink (16) and Calligraphy (15) both vary width with
        -- pressure/angle so the EPDC overlay disagrees with the baked
        -- Screen.bb stroke. Mark (11) is highlighter.
        -- Color 0 = firmware BLACK. The firmware is grayscale, so KOReader
        -- color RGB choices can't be conveyed faithfully — the persistent
        -- stroke baked into Screen.bb keeps the color, but the live
        -- in-stroke preview is black ink.
        SupernoteInk.setPen(SupernoteInk.Pen.NEEDLE,
                            pencilWidthToSupernoteEmr(pen.width),
                            SupernoteInk.Color.BLACK)
        logger.dbg("Pencil: Supernote pen -> ink, width=", pen.width)
    end
end

-- Wipe the firmware's EPDC ink overlay (used by the delayed-refresh commit
-- after the stroke has been baked into Screen.bb and presented).
function Supernote.clearOverlay()
    SupernoteInk.clearAll()
end

-- Release firmware ink ownership across a device sleep so a foregrounded
-- app (e.g. the launcher) doesn't keep painting under finger taps using
-- our last-set pen config. resume() re-claims.
function Supernote.suspend(p)
    if not p.supernote_ink_active then return end
    SupernoteInk.clearAll()
    SupernoteInk.enableFullUiAuto(false)
end

-- Re-claim firmware ink ownership and re-push the current pen config.
-- Skip if pencil never set itself up (e.g. plugin disabled or non-Supernote
-- device — SupernoteInk.isAvailable() returns false).
function Supernote.resume(p)
    if not p.supernote_ink_active then return end
    SupernoteInk.sendWriteAppInfo()
    SupernoteInk.enableFullUiAuto(true)
    SupernoteInk.clearDisableAreas()
    -- Force applyPen() to re-push setPen even though current_tool looks
    -- unchanged — the firmware lost our state during pause.
    p.supernote_last_tool = nil
    Supernote.applyPen(p)
end

return Supernote
