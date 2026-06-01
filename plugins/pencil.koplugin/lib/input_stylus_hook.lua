--[[
input_stylus_hook — monkey-patch Device.input at runtime so the pencil
plugin's stylus callback path works on STOCK KOReader (which doesn't
ship `Input:registerStylusCallback` / `Input:routeStylusEvents`).

What the fork does upstream-of-plugin in `frontend/device/input.lua`:

    function Input:registerStylusCallback(cb)
        self.stylus_callback = cb
    end
    function Input:routeStylusEvents()
        for each MTSlot:
            if slot is stylus and stylus_callback returns true:
                remove from MTSlots so gesture_detector ignores it
    end
    -- and routeStylusEvents is called inside each handleTouchEv*
    -- right before gesture_detector:feedEvent.

We replicate that here by:
  1. Adding the three methods to the live Device.input instance.
  2. Wrapping `Device.input.gesture_detector:feedEvent` once so it calls
     routeStylusEvents() first, then the original feedEvent. This is the
     single common downstream of all 5 handleTouchEv* variants, so one
     hook covers them all.

What we CANNOT do from a plugin:
  - The fork also modifies `base/ffi/input_android.lua` so the stylus
    side button (Android MotionEvent buttonState bits) promotes the
    cooked tool type from PEN to ERASER. That's inside a `local
    function` in a submodule, not reachable from Lua. On stock KOReader
    the side button stays as a button press, so `slot.tool` will always
    be 1 (PEN) regardless of side-button state. Workaround: switch to
    eraser via Tools → Pencil → Tool → Eraser.
--]]

local logger = require("logger")

-- TOOL_TYPE values, must match frontend/device/input.lua.
local TOOL_TYPE_PEN = 1
local TOOL_TYPE_ERASER = 2
local TOOL_TYPE_HIGHLIGHTER = 3

local M = {}

-- Idempotent. Safe to call repeatedly.
function M.install(Input)
    if not Input then
        logger.warn("input_stylus_hook: nil Input passed, abort")
        return false
    end
    if Input.registerStylusCallback then
        -- Native (fork) API already present; nothing to do.
        return true
    end
    if Input._plugin_stylus_hook_installed then
        return true
    end

    function Input:registerStylusCallback(cb)
        self.stylus_callback = cb
        logger.info("Input(plugin-patched): stylus callback registered")
    end

    function Input:unregisterStylusCallback()
        self.stylus_callback = nil
        logger.info("Input(plugin-patched): stylus callback unregistered")
    end

    function Input:routeStylusEvents()
        if not self.stylus_callback then return end
        local slots = self.MTSlots
        if not slots or #slots == 0 then return end
        local dominated_indices = {}
        for i, slot in ipairs(slots) do
            -- Identify stylus by tool type or by sitting in the dedicated
            -- pen slot (matches the fork's heuristic).
            local is_stylus = slot.tool == TOOL_TYPE_PEN
                              or slot.tool == TOOL_TYPE_ERASER
                              or slot.tool == TOOL_TYPE_HIGHLIGHTER
                              or (self.pen_slot and slot.slot == self.pen_slot)
            if is_stylus then
                local dominated = self.stylus_callback(self, slot)
                if dominated then
                    table.insert(dominated_indices, i)
                end
            end
        end
        for i = #dominated_indices, 1, -1 do
            table.remove(slots, dominated_indices[i])
        end
    end

    -- Wrap gesture_detector:feedEvent so routeStylusEvents fires before
    -- gesture detection sees the frame. handleTouchEv* always calls
    -- feedEvent at the end of an event frame; tev_list is the same table
    -- as Input.MTSlots, so removing slots in routeStylusEvents also
    -- removes them from what feedEvent sees.
    local gd = Input.gesture_detector
    if gd and not gd._plugin_stylus_feed_wrapped then
        local orig_feedEvent = gd.feedEvent
        gd.feedEvent = function(gd_self, tev_list)
            Input:routeStylusEvents()
            return orig_feedEvent(gd_self, tev_list)
        end
        gd._plugin_stylus_feed_wrapped = true
        logger.info("input_stylus_hook: gesture_detector.feedEvent wrapped")
    else
        logger.warn("input_stylus_hook: gesture_detector not present yet")
    end

    Input._plugin_stylus_hook_installed = true
    return true
end

return M
