--[[
Shared helpers for the per-device ink backends (sony / supernote / onyx /
huawei). Each backend is self-contained and no-ops when its device isn't
present; main.lua drives them through the uniform setup/teardown lifecycle
and calls device-specific operations (applyPen, drain, clearOverlay, ...)
explicitly where refresh policy genuinely differs per device.

Every backend function takes the plugin instance `p` as its first argument
and operates on the same state fields main.lua reads (sony_dhw_active,
supernote_ink_active, onyx_scribble_active, huawei_ahw_*), so the refresh
policy branches in main.lua keep working unchanged.
--]]

local Device = require("device")
local Screen = Device.screen

local common = {}

-- Tool identifiers; must match main.lua's TOOL_PEN/TOOL_HIGHLIGHTER/TOOL_ERASER.
common.TOOL_PEN = "pen"
common.TOOL_HIGHLIGHTER = "highlighter"
common.TOOL_ERASER = "eraser"

-- 12.5 Hz drain while pencil is active (Onyx and Huawei poll loops).
common.POLL_INTERVAL_S = 0.08

-- How many pixels the pen can move while "still" (hold-to-picker trigger).
-- main.lua's own picker tracking reads this same value.
common.COLOR_PICKER_TOLERANCE_PIXELS = 15

-- Parse a "x1,y1;x2,y2;..." / "x1,y1,x2,y2,..." point string (any separator
-- between pairs) into a point list plus its bounding box.
function common.parsePoints(s)
    local points = {}
    local minx, miny, maxx, maxy
    for sx, sy in s:gmatch("(-?%d+),(-?%d+)") do
        local x, y = tonumber(sx), tonumber(sy)
        table.insert(points, { x = x, y = y })
        if not minx or x < minx then minx = x end
        if not maxx or x > maxx then maxx = x end
        if not miny or y < miny then miny = y end
        if not maxy or y > maxy then maxy = y end
    end
    return points, minx, miny, maxx, maxy
end

-- Append a firmware-captured stroke to the plugin model (strokes list, page
-- index, undo stack, annotation group, deferred save) and paint it into
-- Screen.bb — KOReader's persistent buffer — so the ink survives overlay
-- buffer swaps. Refresh policy is the caller's. Returns the stroke width so
-- callers can pad their refresh bbox.
function common.bakeStroke(p, points)
    local page = p:getCurrentPage()
    local tool = p.current_tool
    local tool_settings = p.tool_settings[tool] or p.tool_settings[common.TOOL_PEN]
    local stroke = {
        page = page,
        tool = tool,
        points = points,
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }
    table.insert(p.strokes, stroke)
    p:indexStroke(#p.strokes, page)
    table.insert(p.undo_stack, { type = "add", stroke_idx = #p.strokes })
    p:assignStrokeToGroup(#p.strokes)
    p:scheduleDeferredWork()

    local width = tool_settings.width
    local color = tool_settings.color
    local half_w = math.floor(width / 2)
    if #points == 1 then
        Screen.bb:paintRectRGB32(points[1].x - half_w, points[1].y - half_w,
                                 width, width, color)
    else
        for i = 1, #points - 1 do
            p:drawLineSegment(Screen.bb,
                points[i].x, points[i].y,
                points[i + 1].x, points[i + 1].y,
                width, color)
        end
    end
    return width
end

return common
