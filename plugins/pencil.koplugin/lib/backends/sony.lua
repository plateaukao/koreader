--[[
Sony DPT backend: instead of routing the stroke through Lua + KOReader's
render path, hand it off to the Java StylusView overlay (ported from
sony_draw). That view owns: the SurfaceView, DHW, and the RenderingThread
that locks the canvas in Sony's DU/GC16 EPD modes — i.e. the exact path
sony_draw uses to get sub-50ms ink-under-pen latency.

setup() enables Direct Handwriting (kernel-fast pen preview) and marks the
plugin so addRawPoint switches its mid-stroke refresh from refreshUI (GC16,
~450ms) to refreshFast (DU, ~120ms). Pencil's own Lua paintRectRGB32 →
ANativeWindow blit is what makes the ink stick; DHW is the optional
sub-50ms "ink under the pen" preview on top.
--]]

local Device = require("device")
local Screen = Device.screen
local logger = require("logger")
local common = require("lib/backends/common")

local Sony = { name = "sony" }

function Sony.setup(p)
    if not Device:isAndroid() then return end
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    if not android.stylusDhwAvailable or not android.stylusDhwAvailable() then
        logger.info("Pencil: Sony DHW unavailable")
        return
    end
    local tool_settings = p.tool_settings[common.TOOL_PEN] or {}
    local pen_width = math.max(1, math.floor(tool_settings.width or 3))
    local rotation = Screen:getRotationMode()
    local rotation_deg = (rotation == 1 or rotation == 3) and 90 or 0
    android.stylusDhwSetArea(0, 0, Screen:getWidth(), Screen:getHeight(),
                             pen_width, rotation_deg)
    android.stylusDhwEnable()
    -- StylusView's per-segment NOCONVERT_DU draw uses its own pen width;
    -- sync it to the pencil tool width so the live preview matches the
    -- final stroke baked into the page.
    if android.stylusOverlaySetPenWidth then
        android.stylusOverlaySetPenWidth(pen_width)
    end
    p.sony_dhw_active = true
    logger.info("Pencil: Sony DHW enabled, pen=", pen_width, "rot=", rotation_deg)
end

function Sony.teardown(p)
    if not p.sony_dhw_active then return end
    local ok, android = pcall(require, "android")
    if ok and android then
        if android.stylusDhwDisable then android.stylusDhwDisable() end
        if android.stylusDhwClearArea then android.stylusDhwClearArea() end
    end
    p.sony_dhw_active = false
    logger.info("Pencil: Sony stylus overlay disabled")
end

-- Wipe the Java StylusView overlay (used by the delayed-refresh commit after
-- KOReader has repainted the page with the baked strokes).
function Sony.clearOverlay()
    local ok, android = pcall(require, "android")
    if ok and android and android.stylusOverlayClear then
        android.stylusOverlayClear()
    end
end

-- Convert "x1,y1,x2,y2,..." -> a stroke record matching the plugin's schema,
-- bake it into Screen.bb, and trigger a partial EPD refresh of just the
-- stroke bounding box (Sony's DU partial refresh).
--
-- NOTE: currently unused on this branch — Sony strokes arrive through the
-- registerStylusCallback Lua path and DHW is preview-only. Kept for the
-- overlay-drain arrangement, which some launcher builds still use.
function Sony.onOverlayStroke(p, s)
    local points, minx, miny, maxx, maxy = common.parsePoints(s)
    if #points == 0 then return end
    local width = common.bakeStroke(p, points)
    -- Flush the bbox to the screen via Sony's DU partial refresh.
    local pad = width + 4
    local rx = math.max(0, math.floor(minx - pad))
    local ry = math.max(0, math.floor(miny - pad))
    local rw = math.min(Screen:getWidth() - rx,  (maxx - minx) + pad * 2)
    local rh = math.min(Screen:getHeight() - ry, (maxy - miny) + pad * 2)
    Screen:refreshFast(rx, ry, rw, rh)
    logger.dbg("Pencil: Sony overlay stroke captured,", #points,
               "points  refresh=", rx, ry, rw, rh)
end

return Sony
