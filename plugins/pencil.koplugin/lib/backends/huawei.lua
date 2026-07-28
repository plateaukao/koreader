--[[
Huawei MatePad Paper backend (Kirin e-ink): the firmware paints stylus ink
to an HWSurfaceView overlay via Auto-HandWrite (android.eink.*), reporting
the captured pen points back through IAhwTouchListener. Like Onyx, the
firmware owns the live ink and KOReader drains finished strokes to bake
them into Screen.bb for persistence, then clears the overlay so the
firmware ink doesn't double-print on top of the persistent stroke. The
eraser is NOT auto-captured, so it falls through to KOReader's normal
erase handling.
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local common = require("lib/backends/common")

local Huawei = { name = "huawei" }

function Huawei.setup(p)
    if not Device:isAndroid() then return end
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    if not android.huaweiAhwAvailable or not android.huaweiAhwAvailable() then
        logger.info("Pencil: Huawei AHW unavailable")
        return
    end
    local pen = p.tool_settings[common.TOOL_PEN] or {}
    local pen_width = math.max(1, tonumber(pen.width) or 4)
    if android.huaweiAhwSetPen then
        -- color 0 => firmware black (the panel is grayscale; the persistent
        -- stroke baked into Screen.bb keeps KOReader's real color).
        android.huaweiAhwSetPen(pen_width, 0)
    end
    p.huawei_ahw_active = true
    -- enable() can fail if the overlay's FB surface isn't created yet; the poll
    -- loop retries until it sticks (huawei_ahw_enabled).
    p.huawei_ahw_enabled = (android.huaweiAhwEnable and android.huaweiAhwEnable()) or false
    Huawei.schedulePoll(p)
    logger.info("Pencil: Huawei AHW setup, pen=", pen_width,
                "enabled=", tostring(p.huawei_ahw_enabled))
end

function Huawei.teardown(p)
    if not p.huawei_ahw_active then return end
    Huawei.cancelPoll(p)
    local ok, android = pcall(require, "android")
    if ok and android then
        if android.huaweiAhwDisable then android.huaweiAhwDisable() end
        if android.huaweiAhwClear then android.huaweiAhwClear() end
    end
    p.huawei_ahw_active = false
    p.huawei_ahw_enabled = false
    p.huawei_pen_down = false
    p.huawei_picker_dropped = false
    p.huawei_last_pen_width = nil
    logger.info("Pencil: Huawei AHW disabled")
end

-- Wipe the firmware ink overlay (delayed-refresh commit and page turns).
function Huawei.clearOverlay()
    local ok, android = pcall(require, "android")
    if ok and android and android.huaweiAhwClear then
        android.huaweiAhwClear()
    end
end

function Huawei.schedulePoll(p)
    if not p.huawei_ahw_active then return end
    Huawei.cancelPoll(p)
    local action = function()
        p.huawei_poll_pending = nil
        if not p.huawei_ahw_active then return end
        local ok, android = pcall(require, "android")
        if ok and android then
            Huawei.pollHoldGesture(p, android)  -- hold-still -> open picker
            Huawei.reconcile(p, android)        -- AHW on/off by tool + picker
        end
        Huawei.drain(p)
        Huawei.schedulePoll(p)
    end
    p.huawei_poll_pending = action
    UIManager:scheduleIn(common.POLL_INTERVAL_S, action)
end

function Huawei.cancelPoll(p)
    if p.huawei_poll_pending then
        UIManager:unschedule(p.huawei_poll_pending)
        p.huawei_poll_pending = nil
    end
end

-- Drain every finished pen stroke the firmware captured and bake it.
function Huawei.drain(p)
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    local got = false
    if android.huaweiAhwPollStroke then
        while true do
            local s = android.huaweiAhwPollStroke()
            if not s or s == "" then break end
            Huawei.onOverlayStroke(p, s)
            got = true
        end
    end
    if got then
        p:_markPenActivity()
        -- The firmware shows the live ink; defer a single clean reconciliation
        -- (page refresh + overlay clear, in scheduleDelayedRefresh) instead of a
        -- partial refresh per stroke, which would ghost rectangular blocks.
        p:scheduleDelayedRefresh()
    end
end

-- Bake one firmware-captured pen stroke into Screen.bb + the model WITHOUT a
-- per-stroke refresh. On the MatePad the firmware already displays the ink
-- live, so KOReader only persists the stroke; the screen is reconciled once on
-- the delayed timer (see scheduleDelayedRefresh's huawei branch). This avoids
-- the per-stroke partial-refresh ghosting blocks.
function Huawei.onOverlayStroke(p, s)
    -- AHW is off in eraser mode, so polled strokes are always pen strokes;
    -- guard against the brief race right after a tool switch.
    if p.current_tool == common.TOOL_ERASER then return end
    local points = common.parsePoints(s)
    if #points == 0 then return end
    common.bakeStroke(p, points)
    -- No refresh here on purpose (see function comment).
end

-- Re-create the hold-to-picker gesture from the firmware pen stream. The
-- firmware consumes the stylus, so KOReader's normal detection in
-- handleStylusSlot never fires; instead we poll the AHW pen state each tick and
-- drive the SAME color_picker tracking + checkColorPickerTrigger. Once the pen
-- has been held still (within tolerance) past the configured hold time the
-- picker opens; we then pause AHW so the selection taps reach KOReader's
-- gesture system (handleStylusSlot early-returns while an overlay is up), and
-- drop the hold's ink dot. AHW resumes when the picker closes.
function Huawei.pollHoldGesture(p, android)
    -- Only meaningful when a hold-triggered picker is actually configured.
    if not (p.experimental_color_picker or p.experimental_pen_width
            or p.experimental_tool_toggle) then return end
    if not android.huaweiAhwPollPenState then return end
    local st = android.huaweiAhwPollPenState()
    if st and st:sub(1, 4) == "down" then
        local sx, sy, sdisp = st:match("down,(-?%d+),(-?%d+),(%d+)")
        if sx then
            local x, y, disp = tonumber(sx), tonumber(sy), tonumber(sdisp)
            p.pen_x = x
            p.pen_y = y
            if not p.huawei_pen_down then
                p.huawei_pen_down = true
                p.color_picker_start_x = x
                p.color_picker_start_y = y
                p.color_picker_start_time = time.now()
            elseif disp > common.COLOR_PICKER_TOLERANCE_PIXELS then
                -- Travelled too far: this is a real stroke, not a hold.
                p:resetColorPickerTracking()
            end
            p:checkColorPickerTrigger()
        end
    elseif p.huawei_pen_down then
        p.huawei_pen_down = false
        p:resetColorPickerTracking()
    end
    -- When the picker opens, discard the hold's ink dot once (the firmware
    -- painted it during the hold). reconcile() pauses capture so the
    -- selection taps reach KOReader, and resumes it when the picker closes.
    if p.color_picker_showing then
        if not p.huawei_picker_dropped then
            p.huawei_picker_dropped = true
            if android.huaweiAhwDropCurrentStroke then android.huaweiAhwDropCurrentStroke() end
        end
    else
        p.huawei_picker_dropped = false
    end
end

-- Keep firmware Auto-HandWrite enabled only when it should be inking: OFF in
-- eraser mode (so the pen tip reaches KOReader's erase path instead of being
-- painted as ink), and OFF while the picker is up (so selection taps reach
-- KOReader's gesture system). Also pushes the current pen width to the firmware
-- preview. Runs every poll tick, so tool/picker changes reconcile within ~80ms.
function Huawei.reconcile(p, android)
    if not p.huawei_ahw_active then return end
    local is_eraser = p.eraser_button_active or p.eraser_tool_active
                      or p.current_tool == common.TOOL_ERASER
    local want_ink = not p.color_picker_showing and not is_eraser
    if want_ink then
        if not p.huawei_ahw_enabled and android.huaweiAhwEnable then
            p.huawei_ahw_enabled = android.huaweiAhwEnable()
        end
        if p.huawei_ahw_enabled and android.huaweiAhwSetPen then
            local pen = p.tool_settings[common.TOOL_PEN] or {}
            local w = math.max(1, tonumber(pen.width) or 4)
            if w ~= p.huawei_last_pen_width then
                android.huaweiAhwSetPen(w, 0)
                p.huawei_last_pen_width = w
            end
        end
    elseif p.huawei_ahw_enabled then
        if android.huaweiAhwDisable then android.huaweiAhwDisable() end
        p.huawei_ahw_enabled = false
    end
end

return Huawei
