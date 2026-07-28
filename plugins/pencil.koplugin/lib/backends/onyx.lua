--[[
Onyx Boox backend (onyxsdk-pen TouchHelper): like Sony, this is an
"app-owns-ink" device — the SDK paints fountain/pencil ink onto the EPD raw
layer at sub-frame latency while normal refreshes are frozen. Unlike Sony,
the pen is consumed entirely at the raw layer, so the events never reach
KOReader's registerStylusCallback path. The only way we learn about a
finished stroke is to poll the launcher's drain queue
(onyxScribblePollStroke), bake the points into Screen.bb, then toggle the
raw layer (onyxScribbleClear) so KOReader's repaint becomes the source of
truth.
--]]

local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local common = require("lib/backends/common")

local Onyx = { name = "onyx" }

function Onyx.setup(p)
    if not Device:isAndroid() then return end
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    if not android.onyxScribbleAvailable or not android.onyxScribbleAvailable() then
        logger.info("Pencil: Onyx scribble unavailable")
        return
    end
    p.onyx_scribble_active = true
    p.onyx_last_style = nil
    Onyx.applyStyle(p)
    android.onyxScribbleEnable()
    Onyx.schedulePoll(p)
    logger.info("Pencil: Onyx scribble enabled")
end

function Onyx.teardown(p)
    if not p.onyx_scribble_active then return end
    p.onyx_scribble_active = false
    Onyx.cancelPoll(p)
    local ok, android = pcall(require, "android")
    if ok and android then
        if android.onyxScribbleClear then android.onyxScribbleClear() end
        if android.onyxScribbleDisable then android.onyxScribbleDisable() end
    end
    logger.info("Pencil: Onyx scribble disabled")
end

-- Push the current tool's width + stroke style down to the SDK. Pencil tool
-- maps to STROKE_STYLE_PENCIL (1, uniform width — matches KOReader's
-- drawLineSegment); highlighter maps to fountain. Eraser keeps the pen style
-- (erasing is handled by draining pollErase, not by an SDK eraser shape).
function Onyx.applyStyle(p)
    if not p.onyx_scribble_active then return end
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    local pen = p.tool_settings[common.TOOL_PEN] or {}
    if android.onyxScribbleSetPenWidth then
        android.onyxScribbleSetPenWidth(math.max(1, tonumber(pen.width) or 3))
    end
    local style = (p.current_tool == common.TOOL_HIGHLIGHTER) and 0 or 1
    if style ~= p.onyx_last_style and android.onyxScribbleSetStrokeStyle then
        android.onyxScribbleSetStrokeStyle(style)
        p.onyx_last_style = style
    end
end

function Onyx.schedulePoll(p)
    if not p.onyx_scribble_active then return end
    Onyx.cancelPoll(p)
    local action = function()
        p.onyx_poll_pending = nil
        if not p.onyx_scribble_active then return end
        Onyx.drain(p)
        Onyx.schedulePoll(p)
    end
    p.onyx_poll_pending = action
    UIManager:scheduleIn(common.POLL_INTERVAL_S, action)
end

function Onyx.cancelPoll(p)
    if p.onyx_poll_pending then
        UIManager:unschedule(p.onyx_poll_pending)
        p.onyx_poll_pending = nil
    end
end

-- Drain every queued pen + eraser stroke from the launcher and apply it.
function Onyx.drain(p)
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    local got = false
    if android.onyxScribblePollStroke then
        while true do
            local s = android.onyxScribblePollStroke()
            if not s or s == "" then break end
            Onyx.onOverlayStroke(p, s)
            got = true
        end
    end
    if android.onyxScribblePollErase then
        while true do
            local s = android.onyxScribblePollErase()
            if not s or s == "" then break end
            Onyx.onEraseStroke(p, s)
            got = true
        end
    end
    if got then
        p:_markPenActivity()
        -- Each baked stroke already partial-refreshed its bbox (native render).
        -- Now drop the SDK raw render briefly so that native render is what
        -- remains on the EPD, then raw rendering resumes for the next stroke.
        if android.onyxScribbleResetFreeze then
            android.onyxScribbleResetFreeze()
        end
    end
end

-- Bake one finished Onyx pen stroke into Screen.bb (the persistent buffer).
-- The point string is "x,y;x,y;..." but the same "(x,y)" gmatch used for
-- Sony parses it regardless of the separator.
--
-- NOTE (on-device calibration): coordinates are taken as already-in-screen
-- space (same assumption as the working Sony path). If strokes land rotated
-- or mirrored on a rotated Onyx, wrap each (x,y) in p:transformCoordinates.
function Onyx.onOverlayStroke(p, s)
    local points, minx, miny, maxx, maxy = common.parsePoints(s)
    if #points == 0 then return end
    local width = common.bakeStroke(p, points)
    -- Partial-refresh just the stroke's bbox so KOReader's native render of the
    -- stroke appears on the page immediately (instead of lagging until the next
    -- full refresh / page change). The SDK's raw render is dropped briefly by
    -- onyxScribbleResetFreeze (called once per drained batch) so this native
    -- render is what remains on screen.
    local pad = width + 4
    local rx = math.max(0, math.floor((minx or 0) - pad))
    local ry = math.max(0, math.floor((miny or 0) - pad))
    local rw = math.min(Screen:getWidth() - rx, ((maxx or 0) - (minx or 0)) + pad * 2)
    local rh = math.min(Screen:getHeight() - ry, ((maxy or 0) - (miny or 0)) + pad * 2)
    if rw > 0 and rh > 0 then
        Screen:refreshFast(rx, ry, rw, rh)
    end
    logger.dbg("Pencil: Onyx stroke captured,", #points, "points")
end

-- Apply one finished Onyx eraser stroke: delete any strokes the eraser path
-- crossed. Reuses eraseAtPoint, the same primitive the tool-toggle eraser uses.
function Onyx.onEraseStroke(p, s)
    local page = p:getCurrentPage()
    local deleted_any = false
    for sx, sy in s:gmatch("(-?%d+),(-?%d+)") do
        local x, y = tonumber(sx), tonumber(sy)
        local deleted = p:eraseAtPoint(x, y, page)
        if deleted and #deleted > 0 then
            for _, stroke in ipairs(deleted) do
                table.insert(p.undo_stack, { type = "delete", strokes = { stroke } })
            end
            deleted_any = true
        end
    end
    if deleted_any then
        p.strokes_dirty = true
        p.view:paintTo(Screen.bb, 0, 0)
        p:paintTo(Screen.bb, 0, 0)
    end
end

return Onyx
