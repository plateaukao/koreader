--[[--
Pencil plugin for KOReader.
Enables freehand drawing and annotation with stylus on supported devices.

@module koplugin.pencil
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local Size = require("ui/size")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local time = require("ui/time")

-- Check if device supports touch input
if not Device:isTouchDevice() then
    return { disabled = true }
end

-- Tool types
local TOOL_PEN = "pen"
local TOOL_HIGHLIGHTER = "highlighter"
local TOOL_ERASER = "eraser"

-- Color picker trigger settings
local COLOR_PICKER_DELAY_MS = 300  -- Default hold-still time (ms); overridable via
                                   -- the "Long-press hold time" setting (color_picker_delay_ms)
local COLOR_PICKER_DELAY_MIN_MS = 150
local COLOR_PICKER_DELAY_MAX_MS = 1500
local COLOR_PICKER_TOLERANCE_PIXELS = 15  -- How many pixels pen can move while "still"

-- Annotation grouping constants
local GROUP_TIME_THRESHOLD_S = 10   -- seconds between strokes to be grouped
local GROUP_SPATIAL_THRESHOLD = 200 -- pixels between bboxes to be grouped

-- Annotation image constants
local IMAGE_CAPTURE_V_MARGIN_PX = 24     -- vertical padding around bbox before clamping
local IMAGE_MIN_HEIGHT_PX = 350          -- floor for captured strip height (legibility)
local IMAGE_MAX_DIM = 1280               -- only downscale captures whose longer side exceeds this
local IMAGE_JPEG_QUALITY = 85
local IMAGE_CAPTURE_DEBOUNCE_S = 4       -- seconds after last stroke before capturing
local IMAGE_BADGE_SIZE = 48              -- on-page badge edge (px) when annotation is stale
local IMAGE_BADGE_HIT_PAD = 32           -- extra pixels around badge for tap hit-test
local IMAGE_BADGE_MARGIN_GAP = 5         -- gap from text/screen edge for margin badge

-- Module-level reference to the most recently initialized Pencil instance.
-- Used by the bookmark-list hook (a class-level monkey-patch installed once)
-- to find the live plugin without coupling to KOReader internals.
local _active_pencil = nil
local _bookmark_hook_installed = false

local Pencil = InputContainer:extend{
    name = "pencil_annotation",
    is_doc_only = true,  -- Only available when a document is open
    current_stroke = nil,
    strokes = nil,       -- All strokes for current document
    current_tool = TOOL_PEN,
    touch_zones_registered = false,
    undo_stack = {},     -- For undo functionality
    eraser_tool_active = false,  -- Track if physical eraser end is in use (via BTN_TOOL_RUBBER)
    eraser_button_active = false,  -- Hardware eraser button held
    eraser_button_deleted = {},    -- Track deletions for undo
    -- Text-highlight state: true while a side-button + pen-drag is building a
    -- KOReader text-highlight selection via ReaderHighlight. Sticky through
    -- pen lift so releasing the side button mid-drag doesn't abort.
    highlighting = false,

    -- Stylus callback for lowest latency (via Input:registerStylusCallback)
    stylus_callback_registered = false,
    pen_down = false,
    erasing = false,  -- Track if currently in erase mode (for finger modifier)
    pen_x = 0,
    pen_y = 0,

    last_refresh_time = 0,
    refresh_interval_ms = 16,  -- Refresh at most every 16ms during drawing (~60fps)
    dirty_region = nil,  -- Accumulated dirty region for batch refresh

    -- Delayed refresh - only refresh after user stops writing
    pending_refresh = nil,
    refresh_delay_ms = 600, -- Wait 600ms after last stroke before final refresh

    -- Save-on-event policy: persistent disk write only on page change /
    -- doc close, not per-stroke. strokes_dirty is set whenever something
    -- mutates self.strokes and cleared on save. flushDeferredWork keys
    -- off this flag.
    strokes_dirty = false,
    pending_save = nil,   -- legacy field; cancelPendingSave still touches it
    save_delay_ms = 1500, -- unused now, kept for setting back-compat
    dirty_groups = nil, -- Set of groups awaiting syncGroupBookmark (id -> group)

    -- Tool settings
    tool_settings = {
        [TOOL_PEN] = {
            width = 3,
            color = nil,  -- Blitbuffer color, set in init
            color_name = "Black",  -- For persistence and display
            alpha = 255,
        },
        [TOOL_HIGHLIGHTER] = {
            width = 20,
            color = nil,  -- Set in init (needs Blitbuffer)
            alpha = 128,
        },
        [TOOL_ERASER] = {
            width = 20,
        },
    },

    -- Side button state
    side_button_down = false,
    side_button_used_for_highlight = false,  -- Track if button was used during a stroke

    -- Color picker state (triggered by holding pen within 5 pixels for 5 seconds)
    color_picker_start_x = nil,  -- Initial X position when pen touched down
    color_picker_start_y = nil,  -- Initial Y position when pen touched down
    color_picker_start_time = nil,  -- Timestamp when pen touched down (nil if moved too far)
    color_picker_check_pending = nil,  -- Scheduled periodic check
    color_picker_showing = false,  -- Whether color picker is currently displayed

    -- Available colors for the pen (initialized in init() with actual Blitbuffer colors)
    available_colors = {},
}

function Pencil:init()
    -- CRITICAL: Add plugin to ReaderUI widget tree so it receives ALL key events
    -- This ensures we catch Eraser button press/release events
    -- Technique borrowed from eraser.koplugin by SimonLiu <simonliu423@gmail.com>
    table.insert(self.ui, self)                -- Add to widget children for event propagation
    table.insert(self.ui.active_widgets, self) -- Always receive events even when hidden

    self.ui.menu:registerToMainMenu(self)
    self.strokes = {}
    self.page_strokes = {}  -- Index: page -> array of stroke indices
    self.annotation_groups = {}  -- Annotation groups for bookmark integration
    self.strokes_loaded = false  -- Set true after successful loadStrokes
    self.undo_stack = {}

    -- Initialize highlighter color (yellow)
    self.tool_settings[TOOL_HIGHLIGHTER].color = Blitbuffer.Color8(0xDD)  -- Light gray for e-ink

    -- Calculate gray value from highlight_lighten_factor setting
    local lighten_factor = G_reader_settings:readSetting("highlight_lighten_factor") or 0.2
    local gray_value = math.floor(255 * (1 - lighten_factor))

    -- Available colors for color picker (Blitbuffer color values)
    self.available_colors = {
        { name = "Black", color = Blitbuffer.COLOR_BLACK },
        { name = "Red", color = Blitbuffer.ColorRGB32(0xFF, 0x33, 0x00, 0xFF) },
        { name = "Orange", color = Blitbuffer.ColorRGB32(0xFF, 0x88, 0x00, 0xFF) },
        { name = "Yellow", color = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0x33, 0xFF) },
        { name = "Green", color = Blitbuffer.ColorRGB32(0x00, 0xAA, 0x66, 0xFF) },
        { name = "Olive", color = Blitbuffer.ColorRGB32(0x88, 0xFF, 0x77, 0xFF) },
        { name = "Cyan", color = Blitbuffer.ColorRGB32(0x00, 0xFF, 0xEE, 0xFF) },
        { name = "Blue", color = Blitbuffer.ColorRGB32(0x00, 0x66, 0xFF, 0xFF) },
        { name = "Purple", color = Blitbuffer.ColorRGB32(0xEE, 0x00, 0xFF, 0xFF) },
        { name = "Gray", color = Blitbuffer.Color8(gray_value) },
    }

    -- Available pen widths for the optional experimental width picker.
    -- Gated by self.experimental_pen_width; see loadSettings().
    self.available_widths = {
        { name = "w3", width = 3 },
        { name = "w5", width = 5 },
        { name = "w7", width = 7 },
        { name = "w9", width = 9 },
    }

    -- Default-on convenience gestures: registered by setupPenInput when the
    -- corresponding settings are true. See loadSettings() for the runtime
    -- values; the field defaults below only matter before loadSettings runs
    -- (e.g. if early init reads them).
    self.double_tap_toggle_tool = true

    -- Load tool and stylus button settings
    self:loadSettings()

    -- Ensure pen color has a default value (black) if not set
    if not self.tool_settings[TOOL_PEN].color then
        self.tool_settings[TOOL_PEN].color = Blitbuffer.COLOR_BLACK
        self.tool_settings[TOOL_PEN].color_name = "Black"
    end

    -- Register as view module to render strokes
    self.view = self.ui.view
    self.view:registerViewModule("pencil_strokes", self)

    -- Try to load strokes now if doc_settings is ready
    -- (backup: they'll also be loaded in onReaderReady/onReadSettings)
    if self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir then
        logger.info("Pencil: doc_settings available in init, loading strokes")
        self:loadStrokes()
    else
        logger.info("Pencil: doc_settings not ready in init, will load in onReaderReady")
    end

    -- Check if plugin is enabled globally and auto-setup
    if self:isEnabled() then
        self:setupPenInput()
    end

    -- Initialize debug logging (if debug mode enabled)
    self:initDebugLog()

    -- Register custom actions for gesture mapping
    Dispatcher:registerAction("pencil_toggle_tool", {
        category = "none",
        event = "PencilToggleTool",
        title = _("Pencil: toggle pencil/eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_toggle_enabled", {
        category = "none",
        event = "PencilToggleEnabled",
        title = _("Pencil: toggle on/off"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_pen", {
        category = "none",
        event = "PencilSelectPen",
        title = _("Pencil: select pencil"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_eraser", {
        category = "none",
        event = "PencilSelectEraser",
        title = _("Pencil: select eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_undo", {
        category = "none",
        event = "PencilUndo",
        title = _("Pencil: undo"),
        reader = true,
        separator = true,
    })

    -- Per-instance state for the annotation-image feature
    self.pending_image_captures = {}
    self.image_data_dirty = false
    _active_pencil = self

    -- Install the (class-level, one-time) bookmark list hook so taps on
    -- pencil bookmarks open the saved image.
    self:installBookmarkHook()

    -- One-time cleanup: earlier version accidentally persisted these
    G_reader_settings:delSetting("page_turns_disable_tap")
    G_reader_settings:delSetting("page_turns_disable_swipe")

    logger.info("Pencil: initialized, enabled =", self:isEnabled(), "tool =", self.current_tool, "strokes =", #self.strokes)
end

-- Paint a tiny tool-state indicator in the top-right corner: a filled
-- black square for pen, a hollow square for eraser. Direct Screen.bb
-- paint + a partial refreshFast on just the badge's region — no setDirty,
-- no widget, no scheduled close. The badge lingers until the next page
-- repaint wipes it, then re-appears on the next tool change.
local TOOL_BADGE_SIZE = 20
local TOOL_BADGE_MARGIN = 8
local TOOL_BADGE_BORDER = 2
function Pencil:showToolBadge()
    local size = TOOL_BADGE_SIZE
    local x = Screen:getWidth() - size - TOOL_BADGE_MARGIN
    local y = TOOL_BADGE_MARGIN
    if self.current_tool == TOOL_ERASER then
        Screen.bb:paintRect(x, y, size, size, Blitbuffer.COLOR_WHITE)
        Screen.bb:paintBorder(x, y, size, size, TOOL_BADGE_BORDER, Blitbuffer.COLOR_BLACK)
    else
        Screen.bb:paintRect(x, y, size, size, Blitbuffer.COLOR_BLACK)
    end
    Screen:refreshFast(x, y, size, size)
end

-- Palm rejection: while the pen tip is on the screen, any finger touch is
-- almost certainly the user's palm resting on the device. Without rejection
-- the palm becomes a Swipe gesture, which ReaderPaging interprets as a page
-- turn — pages flip out from under you while you're writing.
--
-- We reject by consuming finger gestures here (Pencil sits in
-- self.ui.active_widgets, so it gets first dibs on every gesture before
-- ReaderUI does). Gating:
--   - Only when pencil is enabled (otherwise the user is reading normally
--     and expects finger gestures to work).
--   - While self.pen_down (the obvious case).
--   - For a 1s grace window after pen lift, so a palm still on the
--     screen at lift-time can't immediately fire a swipe.
local PALM_REJECT_GRACE_MS = 1000

function Pencil:_markPenActivity()
    self._last_pen_activity = time.now()
end

function Pencil:_isPalmRejecting()
    if not self:isEnabled() then return false end
    if self.pen_down then return true end
    if self._last_pen_activity
            and time.to_ms(time.now() - self._last_pen_activity) < PALM_REJECT_GRACE_MS then
        return true
    end
    return false
end

local function _palmRejectMaybe(self, ges, label)
    if self:_isPalmRejecting() then
        if self.input_debug_mode then
            self:writeDebugLog(string.format("palm-reject: %s ges=%s",
                label, ges and ges.ges or "?"))
        end
        return true  -- consume; ReaderUI never sees it
    end
end

function Pencil:onTap(arg, ges)           return _palmRejectMaybe(self, ges, "Tap") end
function Pencil:onSwipe(arg, ges)         return _palmRejectMaybe(self, ges, "Swipe") end
function Pencil:onHold(arg, ges)          return _palmRejectMaybe(self, ges, "Hold") end
function Pencil:onHoldRelease(arg, ges)   return _palmRejectMaybe(self, ges, "HoldRelease") end
function Pencil:onHoldPan(arg, ges)       return _palmRejectMaybe(self, ges, "HoldPan") end
function Pencil:onMultiSwipe(arg, ges)    return _palmRejectMaybe(self, ges, "MultiSwipe") end
function Pencil:onPan(arg, ges)           return _palmRejectMaybe(self, ges, "Pan") end
function Pencil:onPanRelease(arg, ges)    return _palmRejectMaybe(self, ges, "PanRelease") end
function Pencil:onPinch(arg, ges)         return _palmRejectMaybe(self, ges, "Pinch") end
function Pencil:onSpread(arg, ges)        return _palmRejectMaybe(self, ges, "Spread") end

-- Dispatcher event handlers (for custom gesture mapping)
function Pencil:onPencilToggleTool()
    if self.current_tool == TOOL_ERASER then
        self.current_tool = TOOL_PEN
    else
        self.current_tool = TOOL_ERASER
    end
    self:applySupernotePen()
    self:showToolBadge()
    return true
end

function Pencil:onPencilToggleEnabled()
    local enabled = self:isEnabled()
    self:setEnabled(not enabled)
    if self:isEnabled() then
        self:setupPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil enabled"),
            timeout = 1,
        })
    else
        self:teardownPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil disabled"),
            timeout = 1,
        })
    end
    return true
end

function Pencil:onPencilSelectPen()
    self.current_tool = TOOL_PEN
    self:applySupernotePen()
    self:showToolBadge()
    return true
end

function Pencil:onPencilSelectEraser()
    self.current_tool = TOOL_ERASER
    self:applySupernotePen()
    self:showToolBadge()
    return true
end

function Pencil:onPencilUndo()
    self:undoLastStroke()
    return true
end

-- Setup stylus callback for lowest latency pen capture
-- Uses the new Input:registerStylusCallback() API that intercepts stylus events
-- before they reach the gesture detector
function Pencil:setupStylusCallback()
    if self.stylus_callback_registered then return end

    local Input = Device.input
    if not Input then
        logger.warn("Pencil: Device.input not available")
        return
    end
    -- Stock KOReader doesn't ship registerStylusCallback (it's a fork-only
    -- addition in frontend/device/input.lua). Patch it in at runtime so
    -- the plugin works on the official APK too. Idempotent — on the
    -- fork APK the native method is preferred.
    if not Input.registerStylusCallback then
        local ok_hook, hook = pcall(require, "lib/input_stylus_hook")
        if ok_hook and hook and hook.install then
            hook.install(Input)
        end
    end
    if not Input.registerStylusCallback then
        logger.warn("Pencil: stylus callback API not available (hook install failed)")
        return
    end

    local plugin = self

    -- Register the stylus callback
    -- Callback receives: input (Input object), slot (table with slot, id, x, y, tool, timev)
    -- Return true to "dominate" (remove from gesture detection)
    Input:registerStylusCallback(function(input, slot)
        return plugin:handleStylusSlot(input, slot)
    end)

    self.stylus_callback_registered = true
    self.stylus_coords_logical = self:detectLogicalStylusCoords()
    if self.stylus_coords_logical then
        logger.info("Pencil: stylus coords are logical (Android MotionEvent); skipping rotation transform")
    end
    self:setupSonyDhw()
    self:setupSupernoteInk()
    self:setupOnyxScribble()
    self:setupHuaweiAhw()
    logger.info("Pencil: stylus callback registered")
end

-- Sony DPT: instead of routing the stroke through Lua + KOReader's render
-- path, hand it off to the Java StylusView overlay (ported from sony_draw).
-- That view owns: the SurfaceView, DHW, and the RenderingThread that locks
-- the canvas in Sony's DU/GC16 EPD modes — i.e. the exact path sony_draw
-- uses to get sub-50ms ink-under-pen latency. Lua just drains completed
-- strokes from the overlay and persists them.
-- Sony DPT setup: enable Direct Handwriting (kernel-fast pen preview) and
-- mark the plugin so addRawPoint switches its mid-stroke refresh from
-- refreshUI (GC16, ~450ms) to refreshFast (DU, ~120ms). Pencil's own Lua
-- paintRectRGB32 → ANativeWindow blit is what makes the ink stick; DHW is
-- the optional sub-50ms "ink under the pen" preview on top.
function Pencil:setupSonyDhw()
    if not Device:isAndroid() then return end
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    if not android.stylusDhwAvailable or not android.stylusDhwAvailable() then
        logger.info("Pencil: Sony DHW unavailable")
        return
    end
    local tool_settings = self.tool_settings[TOOL_PEN] or {}
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
    self.sony_dhw_active = true
    logger.info("Pencil: Sony DHW enabled, pen=", pen_width, "rot=", rotation_deg)
end

function Pencil:teardownSonyDhw()
    if not self.sony_dhw_active then return end
    local ok, android = pcall(require, "android")
    if ok and android then
        if android.stylusDhwDisable then android.stylusDhwDisable() end
        if android.stylusDhwClearArea then android.stylusDhwClearArea() end
    end
    self.sony_dhw_active = false
    logger.info("Pencil: Sony stylus overlay disabled")
end

-- Supernote (Ratta A5X2 family — Nomad / Manta / etc.): the firmware paints
-- stroke ink to the EPDC overlay via the `service_myservice` binder, so
-- KOReader does not need a second SurfaceView, lockCanvas, or kernel DHW
-- toggle the way Sony does. The plugin's job is just to configure the
-- firmware pen, gate the framebuffer so mid-stroke Lua refreshes don't
-- fight the EPDC ink, and clear the firmware overlay once the finished
-- stroke has been baked into Screen.bb (in scheduleDelayedRefresh).
--
-- All firmware comms run through lib/supernote_ink.lua, a pure-Lua/JNI
-- binder client. No KOReader launcher patches are required — drop this
-- plugin onto an official KOReader install and the Supernote path lights
-- up at runtime if the binder is present.
local SupernoteInk = require("lib/supernote_ink")

function Pencil:setupSupernoteInk()
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

    self.supernote_ink_active = true
    self.supernote_last_tool = nil  -- forces applySupernotePen() to push state next call
    self:applySupernotePen()
    logger.info("Pencil: Supernote ink enabled")
end

function Pencil:teardownSupernoteInk()
    if not self.supernote_ink_active then return end
    -- Disable ink everywhere while pencil is off so the firmware doesn't
    -- keep painting under finger taps in the document view, then release
    -- our enableFullUiAuto claim.
    local Screen = Device.screen
    if Screen then
        SupernoteInk.setFullScreenDisable(Screen:getWidth(), Screen:getHeight())
    end
    SupernoteInk.clearAll()
    SupernoteInk.enableFullUiAuto(false)
    self.supernote_ink_active = false
    self.supernote_last_tool = nil
    logger.info("Pencil: Supernote ink disabled")
end

-- Onyx Boox (onyxsdk-pen TouchHelper): like Sony, this is an "app-owns-ink"
-- device — the SDK paints fountain/pencil ink onto the EPD raw layer at
-- sub-frame latency while normal refreshes are frozen. Unlike Sony, the pen
-- is consumed entirely at the raw layer, so the events never reach KOReader's
-- registerStylusCallback path. The only way we learn about a finished stroke
-- is to poll the launcher's drain queue (onyxScribblePollStroke), bake the
-- points into Screen.bb, then toggle the raw layer (onyxScribbleClear) so
-- KOReader's repaint becomes the source of truth.
local ONYX_POLL_INTERVAL_S = 0.08  -- 12.5 Hz drain while pencil is active

function Pencil:setupOnyxScribble()
    if not Device:isAndroid() then return end
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    if not android.onyxScribbleAvailable or not android.onyxScribbleAvailable() then
        logger.info("Pencil: Onyx scribble unavailable")
        return
    end
    self.onyx_scribble_active = true
    self.onyx_last_style = nil
    self:applyOnyxStyle()
    android.onyxScribbleEnable()
    self:scheduleOnyxPoll()
    logger.info("Pencil: Onyx scribble enabled")
end

function Pencil:teardownOnyxScribble()
    if not self.onyx_scribble_active then return end
    self.onyx_scribble_active = false
    self:cancelOnyxPoll()
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
function Pencil:applyOnyxStyle()
    if not self.onyx_scribble_active then return end
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    local pen = self.tool_settings[TOOL_PEN] or {}
    if android.onyxScribbleSetPenWidth then
        android.onyxScribbleSetPenWidth(math.max(1, tonumber(pen.width) or 3))
    end
    local style = (self.current_tool == TOOL_HIGHLIGHTER) and 0 or 1
    if style ~= self.onyx_last_style and android.onyxScribbleSetStrokeStyle then
        android.onyxScribbleSetStrokeStyle(style)
        self.onyx_last_style = style
    end
end

function Pencil:scheduleOnyxPoll()
    if not self.onyx_scribble_active then return end
    self:cancelOnyxPoll()
    local plugin = self
    local action = function()
        plugin.onyx_poll_pending = nil
        if not plugin.onyx_scribble_active then return end
        plugin:drainOnyxStrokes()
        plugin:scheduleOnyxPoll()
    end
    self.onyx_poll_pending = action
    UIManager:scheduleIn(ONYX_POLL_INTERVAL_S, action)
end

function Pencil:cancelOnyxPoll()
    if self.onyx_poll_pending then
        UIManager:unschedule(self.onyx_poll_pending)
        self.onyx_poll_pending = nil
    end
end

-- Huawei MatePad Paper (Kirin e-ink): the firmware paints stylus ink to an
-- HWSurfaceView overlay via Auto-HandWrite (android.eink.*), reporting the
-- captured pen points back through IAhwTouchListener. Like Onyx, the firmware
-- owns the live ink and KOReader drains finished strokes (drainHuaweiStrokes
-- -> onOnyxOverlayStroke, reused as-is) to bake them into Screen.bb for
-- persistence, then clears the overlay so the firmware ink doesn't double-
-- print on top of the persistent stroke. The eraser is NOT auto-captured, so
-- it falls through to KOReader's normal erase handling.
function Pencil:setupHuaweiAhw()
    if not Device:isAndroid() then return end
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    if not android.huaweiAhwAvailable or not android.huaweiAhwAvailable() then
        logger.info("Pencil: Huawei AHW unavailable")
        return
    end
    local pen = self.tool_settings[TOOL_PEN] or {}
    local pen_width = math.max(1, tonumber(pen.width) or 4)
    if android.huaweiAhwSetPen then
        -- color 0 => firmware black (the panel is grayscale; the persistent
        -- stroke baked into Screen.bb keeps KOReader's real color).
        android.huaweiAhwSetPen(pen_width, 0)
    end
    self.huawei_ahw_active = true
    -- enable() can fail if the overlay's FB surface isn't created yet; the poll
    -- loop retries until it sticks (huawei_ahw_enabled).
    self.huawei_ahw_enabled = (android.huaweiAhwEnable and android.huaweiAhwEnable()) or false
    self:scheduleHuaweiPoll()
    logger.info("Pencil: Huawei AHW setup, pen=", pen_width,
                "enabled=", tostring(self.huawei_ahw_enabled))
end

function Pencil:teardownHuaweiAhw()
    if not self.huawei_ahw_active then return end
    self:cancelHuaweiPoll()
    local ok, android = pcall(require, "android")
    if ok and android then
        if android.huaweiAhwDisable then android.huaweiAhwDisable() end
        if android.huaweiAhwClear then android.huaweiAhwClear() end
    end
    self.huawei_ahw_active = false
    self.huawei_ahw_enabled = false
    self.huawei_pen_down = false
    self.huawei_picker_dropped = false
    self.huawei_last_pen_width = nil
    logger.info("Pencil: Huawei AHW disabled")
end

function Pencil:scheduleHuaweiPoll()
    if not self.huawei_ahw_active then return end
    self:cancelHuaweiPoll()
    local plugin = self
    local action = function()
        plugin.huawei_poll_pending = nil
        if not plugin.huawei_ahw_active then return end
        local ok, android = pcall(require, "android")
        if ok and android then
            plugin:pollHuaweiHoldGesture(android)  -- hold-still -> open picker
            plugin:reconcileHuaweiAhw(android)     -- AHW on/off by tool + picker
        end
        plugin:drainHuaweiStrokes()
        plugin:scheduleHuaweiPoll()
    end
    self.huawei_poll_pending = action
    UIManager:scheduleIn(ONYX_POLL_INTERVAL_S, action)
end

function Pencil:cancelHuaweiPoll()
    if self.huawei_poll_pending then
        UIManager:unschedule(self.huawei_poll_pending)
        self.huawei_poll_pending = nil
    end
end

-- Drain every finished pen stroke the firmware captured and bake it.
function Pencil:drainHuaweiStrokes()
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    local got = false
    if android.huaweiAhwPollStroke then
        while true do
            local s = android.huaweiAhwPollStroke()
            if not s or s == "" then break end
            self:onHuaweiOverlayStroke(s)
            got = true
        end
    end
    if got then
        self:_markPenActivity()
        -- The firmware shows the live ink; defer a single clean reconciliation
        -- (page refresh + overlay clear, in scheduleDelayedRefresh) instead of a
        -- partial refresh per stroke, which would ghost rectangular blocks.
        self:scheduleDelayedRefresh()
    end
end

-- Bake one firmware-captured pen stroke into Screen.bb + the model WITHOUT a
-- per-stroke refresh. On the MatePad the firmware already displays the ink
-- live, so KOReader only persists the stroke; the screen is reconciled once on
-- the delayed timer (see scheduleDelayedRefresh's huawei branch). This avoids
-- the per-stroke partial-refresh ghosting blocks.
function Pencil:onHuaweiOverlayStroke(s)
    -- AHW is off in eraser mode, so polled strokes are always pen strokes;
    -- guard against the brief race right after a tool switch.
    if self.current_tool == TOOL_ERASER then return end
    local page = self:getCurrentPage()
    local tool = self.current_tool
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]
    local points = {}
    for sx, sy in s:gmatch("(-?%d+),(-?%d+)") do
        table.insert(points, { x = tonumber(sx), y = tonumber(sy) })
    end
    if #points == 0 then return end
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
    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, page)
    table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
    self:assignStrokeToGroup(#self.strokes)
    self:scheduleDeferredWork()

    local width = tool_settings.width
    local color = tool_settings.color
    local half_w = math.floor(width / 2)
    if #points == 1 then
        Screen.bb:paintRectRGB32(points[1].x - half_w, points[1].y - half_w,
                                 width, width, color)
    else
        for i = 1, #points - 1 do
            self:drawLineSegment(Screen.bb,
                points[i].x, points[i].y,
                points[i + 1].x, points[i + 1].y,
                width, color)
        end
    end
    -- No refresh here on purpose (see function comment).
end

-- Re-create the hold-to-picker gesture from the firmware pen stream. The
-- firmware consumes the stylus, so KOReader's normal detection in
-- handleStylusSlot never fires; instead we poll the AHW pen state each tick and
-- drive the SAME color_picker tracking + checkColorPickerTrigger. Once the pen
-- has been held still (within tolerance) past COLOR_PICKER_DELAY_MS the picker
-- opens; we then pause AHW so the selection taps reach KOReader's gesture
-- system (handleStylusSlot early-returns while an overlay is up), and drop the
-- hold's ink dot. AHW resumes when the picker closes.
function Pencil:pollHuaweiHoldGesture(android)
    -- Only meaningful when a hold-triggered picker is actually configured.
    if not (self.experimental_color_picker or self.experimental_pen_width
            or self.experimental_tool_toggle) then return end
    if not android.huaweiAhwPollPenState then return end
    local st = android.huaweiAhwPollPenState()
    if st and st:sub(1, 4) == "down" then
        local sx, sy, sdisp = st:match("down,(-?%d+),(-?%d+),(%d+)")
        if sx then
            local x, y, disp = tonumber(sx), tonumber(sy), tonumber(sdisp)
            self.pen_x = x
            self.pen_y = y
            if not self.huawei_pen_down then
                self.huawei_pen_down = true
                self.color_picker_start_x = x
                self.color_picker_start_y = y
                self.color_picker_start_time = time.now()
            elseif disp > COLOR_PICKER_TOLERANCE_PIXELS then
                -- Travelled too far: this is a real stroke, not a hold.
                self:resetColorPickerTracking()
            end
            self:checkColorPickerTrigger()
        end
    elseif self.huawei_pen_down then
        self.huawei_pen_down = false
        self:resetColorPickerTracking()
    end
    -- When the picker opens, discard the hold's ink dot once (the firmware
    -- painted it during the hold). reconcileHuaweiAhw pauses capture so the
    -- selection taps reach KOReader, and resumes it when the picker closes.
    if self.color_picker_showing then
        if not self.huawei_picker_dropped then
            self.huawei_picker_dropped = true
            if android.huaweiAhwDropCurrentStroke then android.huaweiAhwDropCurrentStroke() end
        end
    else
        self.huawei_picker_dropped = false
    end
end

-- Keep firmware Auto-HandWrite enabled only when it should be inking: OFF in
-- eraser mode (so the pen tip reaches KOReader's erase path instead of being
-- painted as ink), and OFF while the picker is up (so selection taps reach
-- KOReader's gesture system). Also pushes the current pen width to the firmware
-- preview. Runs every poll tick, so tool/picker changes reconcile within ~80ms.
function Pencil:reconcileHuaweiAhw(android)
    if not self.huawei_ahw_active then return end
    local is_eraser = self.eraser_button_active or self.eraser_tool_active
                      or self.current_tool == TOOL_ERASER
    local want_ink = not self.color_picker_showing and not is_eraser
    if want_ink then
        if not self.huawei_ahw_enabled and android.huaweiAhwEnable then
            self.huawei_ahw_enabled = android.huaweiAhwEnable()
        end
        if self.huawei_ahw_enabled and android.huaweiAhwSetPen then
            local pen = self.tool_settings[TOOL_PEN] or {}
            local w = math.max(1, tonumber(pen.width) or 4)
            if w ~= self.huawei_last_pen_width then
                android.huaweiAhwSetPen(w, 0)
                self.huawei_last_pen_width = w
            end
        end
    elseif self.huawei_ahw_enabled then
        if android.huaweiAhwDisable then android.huaweiAhwDisable() end
        self.huawei_ahw_enabled = false
    end
end

-- Drain every queued pen + eraser stroke from the launcher and apply it.
function Pencil:drainOnyxStrokes()
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    local got = false
    if android.onyxScribblePollStroke then
        while true do
            local s = android.onyxScribblePollStroke()
            if not s or s == "" then break end
            self:onOnyxOverlayStroke(s)
            got = true
        end
    end
    if android.onyxScribblePollErase then
        while true do
            local s = android.onyxScribblePollErase()
            if not s or s == "" then break end
            self:onOnyxEraseStroke(s)
            got = true
        end
    end
    if got then
        self:_markPenActivity()
        -- Each baked stroke already partial-refreshed its bbox (native render).
        -- Now drop the SDK raw render briefly so that native render is what
        -- remains on the EPD, then raw rendering resumes for the next stroke.
        if android.onyxScribbleResetFreeze then
            android.onyxScribbleResetFreeze()
        end
    end
end

-- Bake one finished Onyx pen stroke into Screen.bb (the persistent buffer),
-- mirroring onSonyOverlayStroke. The point string is "x,y;x,y;..." but the
-- same "(x,y)" gmatch used for Sony parses it regardless of the separator.
--
-- NOTE (on-device calibration): coordinates are taken as already-in-screen
-- space (same assumption as the working Sony path). If strokes land rotated
-- or mirrored on a rotated Onyx, wrap each (x,y) in self:transformCoordinates.
function Pencil:onOnyxOverlayStroke(s)
    local page = self:getCurrentPage()
    local tool = self.current_tool
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]
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
    if #points == 0 then return end
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
    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, page)
    table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
    self:assignStrokeToGroup(#self.strokes)
    self:scheduleDeferredWork()

    local width = tool_settings.width
    local color = tool_settings.color
    local half_w = math.floor(width / 2)
    if #points == 1 then
        Screen.bb:paintRectRGB32(points[1].x - half_w, points[1].y - half_w,
                                 width, width, color)
    else
        for i = 1, #points - 1 do
            self:drawLineSegment(Screen.bb,
                points[i].x, points[i].y,
                points[i + 1].x, points[i + 1].y,
                width, color)
        end
    end
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
function Pencil:onOnyxEraseStroke(s)
    local page = self:getCurrentPage()
    local deleted_any = false
    for sx, sy in s:gmatch("(-?%d+),(-?%d+)") do
        local x, y = tonumber(sx), tonumber(sy)
        local deleted = self:eraseAtPoint(x, y, page)
        if deleted and #deleted > 0 then
            for _, stroke in ipairs(deleted) do
                table.insert(self.undo_stack, { type = "delete", strokes = { stroke } })
            end
            deleted_any = true
        end
    end
    if deleted_any then
        self.strokes_dirty = true
        self.view:paintTo(Screen.bb, 0, 0)
        self:paintTo(Screen.bb, 0, 0)
    end
end

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

-- Push the current pencil tool (pen tip vs eraser) down to the firmware.
-- Called whenever the effective tool may have changed: on plugin start,
-- on slot.tool flipping in handleStylusSlot, and on the menu callbacks
-- that switch between TOOL_PEN and TOOL_ERASER.
function Pencil:applySupernotePen()
    if not self.supernote_ink_active then return end
    -- Effective tool: if the physical eraser end / button is engaged, the
    -- firmware should show the eraser shape; otherwise use the menu tool.
    local effective
    if self.eraser_button_active or self.eraser_tool_active
            or self.current_tool == TOOL_ERASER then
        effective = TOOL_ERASER
    else
        effective = self.current_tool
    end
    if effective == self.supernote_last_tool then return end
    self.supernote_last_tool = effective
    if effective == TOOL_ERASER then
        local er_width = (self.tool_settings[TOOL_ERASER] or {}).width or 20
        SupernoteInk.setEraser(false, math.max(400, er_width * 50))
        logger.dbg("Pencil: Supernote pen -> eraser, width=", er_width)
    else
        local pen = self.tool_settings[TOOL_PEN] or {}
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

-- Convert "x1,y1,x2,y2,..." -> a stroke record matching the plugin's schema,
-- append it, draw it into Screen.bb (so KOReader's framebuffer keeps the
-- ink even after SurfaceFlinger swaps the overlay's transient buffers),
-- and trigger a partial EPD refresh of just the stroke bounding box.
function Pencil:onSonyOverlayStroke(s)
    local page = self:getCurrentPage()
    local tool = self.current_tool
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]
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
    if #points == 0 then return end
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
    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, page)
    table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
    self:assignStrokeToGroup(#self.strokes)
    self:scheduleDeferredWork()

    -- Paint into Screen.bb so the ink is in KOReader's persistent buffer.
    -- (The Java overlay shows real-time ink but its SurfaceView buffers are
    -- transient — SurfaceFlinger can swap them out and leave the screen
    -- blank in that area. Baking into Screen.bb makes the ink survive.)
    local width = tool_settings.width
    local color = tool_settings.color
    local half_w = math.floor(width / 2)
    if #points == 1 then
        Screen.bb:paintRectRGB32(points[1].x - half_w, points[1].y - half_w,
                                 width, width, color)
    else
        for i = 1, #points - 1 do
            self:drawLineSegment(Screen.bb,
                points[i].x, points[i].y,
                points[i + 1].x, points[i + 1].y,
                width, color)
        end
    end
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

-- True on devices whose stylus arrives via the Android MotionEvent pipeline,
-- where coordinates are already in logical (display-rotated) screen space.
-- HyRead M08P (RK3576) is such a device, and its panel's natural orientation
-- is ROTATION_180, so re-rotating the pen here (identity at rotation 0) flips
-- it 180°. Detected once; see transformCoordinates.
function Pencil:detectLogicalStylusCoords()
    -- KOReader's Android port delivers stylus events through Android
    -- MotionEvent, whose coordinates are already in logical (display-rotated)
    -- screen space — the same space the renderer and finger-touch path use.
    -- Raw-evdev platforms (Kobo/Linux) report native panel coords and DO need
    -- the rotation transform; Onyx's SDK pen path reports native coords too but
    -- is baked in onOnyxOverlayStroke, which never calls transformCoordinates.
    return Device:isAndroid()
end

-- Transform stylus coordinates based on screen rotation.
-- Raw evdev stylus coordinates (Kobo/Linux, and Onyx's SDK pen path) are in
-- the panel's native hardware space and must be rotated into logical/display
-- space. But on devices that deliver the pen through Android MotionEvent the
-- coordinates are ALREADY logical — the same space the finger-touch path and
-- the renderer use — so rotating again double-rotates the pen. Skip the
-- transform for those (see detectLogicalStylusCoords).
function Pencil:transformCoordinates(x, y)
    if self.stylus_coords_logical then
        return x, y
    end
    local rotation = Screen:getRotationMode()
    return PencilGeometry.transformForRotation(x, y, rotation, Screen:getWidth(), Screen:getHeight())
end


-- Handle a stylus slot from the callback
-- slot = {slot=N, id=N, x=N, y=N, tool=N, timev=timestamp}
-- id >= 0 means contact active, id == -1 means contact lifted
function Pencil:handleStylusSlot(input, slot)
    -- Tool types from Linux input subsystem
    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    -- Debug logging at the very start to see slot.tool
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS SLOT: id=%d x=%d y=%d tool=%d eraser_active=%s",
            slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.eraser_button_active)))
    end

    -- Don't capture pen input when a menu or overlay is on top of the reader
    if self:isOverlayActive() then return false end

    -- Onyx: the onyxsdk-pen TouchHelper owns the stylus at the EPD raw layer
    -- (fast live ink) and the finished stroke is persisted by the poll path
    -- (drainOnyxStrokes -> onOnyxOverlayStroke). If a pen event still leaks
    -- into KOReader's input here, consume it WITHOUT the slow per-point Lua
    -- draw + mid-stroke refreshUI — that refresh is what flips the EPD
    -- waveform mode and makes the page blink while writing. Pen + eraser both
    -- go through the SDK on Onyx, so swallow the whole slot.
    if self.onyx_scribble_active then
        self:_markPenActivity()
        return true
    end

    -- Detect eraser end via slot.tool BEFORE key events arrive
    -- This handles the timing issue where stylus callback fires before key events
    if ((self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_HIGHLIGHTER) or (not self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_ERASER)) and not self.eraser_button_active then
        logger.info("Pencil: Eraser end detected via slot.tool, activating eraser mode")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        self:applySupernotePen()
    elseif ((self.swap_eraser_and_highlighter and not (slot.tool == TOOL_TYPE_HIGHLIGHTER)) or (not self.swap_eraser_and_highlighter and not (slot.tool == TOOL_TYPE_ERASER))) and self.eraser_button_active then
        -- Switched from eraser end to pen tip
        logger.info("Pencil: Pen tip detected via slot.tool, deactivating eraser mode")
        if self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_button_deleted })
            self.strokes_dirty = true  -- persisted on next page change / close
        end
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self:applySupernotePen()
        UIManager:setDirty(self.view, "ui")
    end

    -- Huawei MatePad Paper: when the firmware Auto-HandWrite is actively inking
    -- (huawei_ahw_enabled), pen strokes are captured by the firmware and baked
    -- from the poll path (drainHuaweiStrokes); swallow any leaked pen event here
    -- so the stroke isn't recorded twice. In eraser mode AHW is turned OFF
    -- (reconcileHuaweiAhw), so huawei_ahw_enabled is false and we fall through
    -- to the normal erase handling below — the pen tip then erases.
    if self.huawei_ahw_active and self.huawei_ahw_enabled
            and not (self.eraser_button_active or self.eraser_tool_active
                     or self.current_tool == TOOL_ERASER) then
        self:_markPenActivity()
        return true
    end

    -- Eraser mode (from eraser end or hardware button) - works even if pencil disabled
    if self.eraser_button_active then
        if slot.id and slot.id >= 0 then
            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            local page = self:getCurrentPage()
            local deleted = self:eraseAtPoint(x, y, page)
            if deleted then
                for _, stroke in ipairs(deleted) do
                    table.insert(self.eraser_button_deleted, stroke)
                end
                self.view:paintTo(Screen.bb, 0, 0)
                self:paintTo(Screen.bb, 0, 0)
                Screen:refreshFast(0, 0, Screen:getWidth(), Screen:getHeight())
            end
            -- Also remove any native KOReader text highlight at this position.
            -- removeItemByIndex emits AnnotationsModified and triggers its own
            -- repaint, so we don't need to mirror the refreshFast call above.
            self:eraseHighlightAtScreenPos(x, y)
            self.pen_x = x
            self.pen_y = y
        end
        return true
    end

    -- Native text-highlight path: runs before any draw/stroke logic.
    -- When input.lua has promoted slot.tool to HIGHLIGHTER (side button held),
    -- route pen events through KOReader's ReaderHighlight instead of creating
    -- a freehand stroke. Sticky: once we enter, we stay until pen lift even
    -- if the side button is released mid-drag.
    if self.experimental_text_highlight
            and (slot.tool == TOOL_TYPE_HIGHLIGHTER or self.highlighting) then
        local current_slot_id = slot.id or -1
        if current_slot_id >= 0 and not self.highlighting then
            self:startTextHighlight(slot.x or 0, slot.y or 0)
        elseif current_slot_id >= 0 and self.highlighting then
            self:extendTextHighlight(slot.x or 0, slot.y or 0)
        elseif current_slot_id < 0 and self.highlighting then
            self:finishTextHighlight()
        end
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Log in debug mode
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS: slot=%d id=%d x=%d y=%d tool=%d pen_down=%s tool=%s",
            slot.slot or -1, slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.pen_down), self.current_tool))
    end

    -- Determine effective tool:
    -- 1. Physical eraser end via slot.tool (TOOL_TYPE_ERASER = 2) takes priority
    -- 2. Physical eraser end via BTN_TOOL_RUBBER key event (eraser_tool_active) as backup
    -- 3. Otherwise use selected tool (user can toggle via gesture)
    local TOOL_TYPE_ERASER = 2
    local effective_tool
    if (self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_HIGHLIGHTER) or (not self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_ERASER) or self.eraser_tool_active then
        effective_tool = TOOL_ERASER
        if self.input_debug_mode and slot.tool == TOOL_TYPE_ERASER then
            self:writeDebugLog(string.format("ERASER END detected via slot.tool=%d", slot.tool))
        end
    else
        effective_tool = self.current_tool
    end

    -- Handle eraser mode
    if effective_tool == TOOL_ERASER then
        if self.input_debug_mode and not self.erasing then
            self:writeDebugLog(string.format("ERASER MODE: pen_down=%s slot.id=%d",
                tostring(self.pen_down), slot.id or -1))
        end
        -- The pen/eraser toggle can be summoned in eraser mode by holding the
        -- eraser still. Only the menu-selected (software) eraser qualifies: the
        -- physical eraser end flips effective_tool via slot.tool while
        -- current_tool stays PEN, and there it should keep erasing, not toggle.
        local picker_toggle_enabled = self.experimental_tool_toggle
            and self.current_tool == TOOL_ERASER
        if slot.id and slot.id >= 0 then
            -- While the long-press picker is up, route fresh taps to it and
            -- never erase underneath it.
            if self.color_picker_showing and self.color_picker_widget then
                if not self.pen_down then
                    local tx, ty = self:transformCoordinates(slot.x or 0, slot.y or 0)
                    self.color_picker_widget:handlePenTap(tx, ty)
                end
                return true
            end

            -- Eraser is touching - erase at this position
            local first_touch = false
            if not self.pen_down then
                self.pen_down = true
                self.erasing = true
                self.eraser_deleted = {}
                first_touch = true
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER DOWN ===")
                end
            end

            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)

            -- Hold-still tracking for the toggle picker: arm it on first touch,
            -- then drop it once the eraser travels beyond tolerance (the user
            -- is actively erasing a region, not holding still to toggle).
            if picker_toggle_enabled then
                if first_touch then
                    self.color_picker_start_x = x
                    self.color_picker_start_y = y
                    self.color_picker_start_time = time.now()
                    self:scheduleColorPickerCheck()
                elseif self.color_picker_start_x and self.color_picker_start_y then
                    local dx = math.abs(x - self.color_picker_start_x)
                    local dy = math.abs(y - self.color_picker_start_y)
                    if dx > COLOR_PICKER_TOLERANCE_PIXELS or dy > COLOR_PICKER_TOLERANCE_PIXELS then
                        self:resetColorPickerTracking()
                    end
                end
            end

            -- Erase on first touch OR when position changes
            if first_touch or x ~= self.pen_x or y ~= self.pen_y then
                local page = self:getCurrentPage()
                if self.input_debug_mode then
                    self:writeDebugLog(string.format("ERASE ATTEMPT at (%d, %d) page=%s erasing=%s",
                        x, y, tostring(page), tostring(self.erasing)))
                end
                local deleted = self:eraseAtPoint(x, y, page)
                if deleted then
                    for _, stroke in ipairs(deleted) do
                        table.insert(self.eraser_deleted, stroke)
                    end
                    -- Immediately repaint view and our strokes overlay, then refresh
                    self.view:paintTo(Screen.bb, 0, 0)
                    self:paintTo(Screen.bb, 0, 0)
                    Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASED %d strokes at (%d, %d)", #deleted, x, y))
                    end
                end
                self.pen_x = x
                self.pen_y = y
            end
        else
            -- Eraser lifted
            if self.pen_down and self.erasing then
                self.pen_down = false
                self.erasing = false
                self:cancelColorPickerTimer()
                if self.eraser_deleted and #self.eraser_deleted > 0 then
                    table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_deleted })
                    self.strokes_dirty = true  -- persisted on next page change / close
                end
                self.eraser_deleted = nil
                UIManager:setDirty(self.view, "ui")
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER UP ===")
                end
            end
        end
        return true  -- Dominate: remove from gesture detection
    end

    -- Handle pen/highlighter mode
    if slot.id and slot.id >= 0 then
        -- Pen down or moving
        if not self.pen_down then
            -- Check if color picker is showing - route pen tap to it
            if self.color_picker_showing and self.color_picker_widget then
                local raw_x = slot.x or 0
                local raw_y = slot.y or 0
                local x, y = self:transformCoordinates(raw_x, raw_y)
                if self.color_picker_widget:handlePenTap(x, y) then
                    -- Color picker handled the tap, don't start a stroke
                    return true
                end
            end

            -- Start new stroke
            self.pen_down = true
            self.erasing = false
            self:cancelPendingRefresh()
            self:cancelColorPickerTimer()
            self:startRawStroke()
            -- Record initial position and timestamp for color picker trigger
            local raw_x = slot.x or 0
            local raw_y = slot.y or 0
            local x, y = self:transformCoordinates(raw_x, raw_y)
            self.pen_x = x
            self.pen_y = y
            -- Only track picker state and schedule the 10Hz poll when the
            -- hold-pen-still gesture would actually produce something to
            -- show. Skipping these when all experimental pickers are off
            -- avoids an UIManager:scheduleIn closure allocation on every
            -- pen-down — real GC pressure on the A53 during multi-second
            -- strokes.
            if self.experimental_color_picker or self.experimental_pen_width
                    or self.experimental_tool_toggle then
                self.color_picker_start_x = x
                self.color_picker_start_y = y
                self.color_picker_start_time = time.now()
                -- Schedule periodic check for color picker trigger
                self:scheduleColorPickerCheck()
            end
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN DOWN ===")
            end
        else
            -- Pen is moving
            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            if x ~= self.pen_x or y ~= self.pen_y then
                -- Check if pen moved more than tolerance from start position
                if self.color_picker_start_x and self.color_picker_start_y then
                    local dx = math.abs(x - self.color_picker_start_x)
                    local dy = math.abs(y - self.color_picker_start_y)
                    if dx > COLOR_PICKER_TOLERANCE_PIXELS or dy > COLOR_PICKER_TOLERANCE_PIXELS then
                        -- Pen moved too far - reset tracking (no color picker)
                        self:resetColorPickerTracking()
                    end
                end
                self:addRawPoint(x, y)
                self.pen_x = x
                self.pen_y = y
            end
        end
    else
        -- Pen lifted (id == -1)
        if self.pen_down and not self.erasing then
            self.pen_down = false
            self:cancelColorPickerTimer()
            self:endRawStroke()
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN UP ===")
            end
        end
    end

    -- Refresh the palm-reject grace timer on every stylus event so the
    -- window starts counting from pen lift, not from pen down.
    self:_markPenActivity()

    return true  -- Dominate: remove from gesture detection
end

-- Teardown stylus callback
function Pencil:teardownStylusCallback()
    if not self.stylus_callback_registered then return end

    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end

    self:teardownSonyDhw()
    self:teardownSupernoteInk()
    self:teardownOnyxScribble()
    self:teardownHuaweiAhw()
    self.stylus_callback_registered = false
    self.pen_down = false
    logger.info("Pencil: stylus callback unregistered")
end

-- Start a new stroke from raw input
function Pencil:startRawStroke()
    local page = self:getCurrentPage()
    local tool = self.side_button_down and TOOL_HIGHLIGHTER or self.current_tool
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    self.current_stroke = {
        page = page,
        tool = tool,
        points = {},
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }
    self.last_refresh_time = time.now()
    self.dirty_region = nil  -- Clear any pending dirty region
    logger.dbg("Pencil: raw stroke started")
end

-- Add a point from raw input and draw it
function Pencil:addRawPoint(x, y)
    if not self.current_stroke then return end

    local point = { x = x, y = y }
    table.insert(self.current_stroke.points, point)

    local n = #self.current_stroke.points

    local width = self.current_stroke.width
    local color = self.current_stroke.color
    local half_w = math.floor(width / 2) + 2  -- padding for antialiasing

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and self.current_stroke.color_name ~= "Black" and self.current_stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    -- Draw to framebuffer and track dirty region
    local dirty_x, dirty_y, dirty_w, dirty_h
    if n == 1 then
        -- Draw first point same size as line segments for consistency
        local half_w_draw = math.floor(width / 2)
        Screen.bb:paintRectRGB32(x - half_w_draw, y - half_w_draw, width, width, color)
        -- Use slightly larger dirty region for refresh padding
        dirty_x = x - half_w
        dirty_y = y - half_w
        dirty_w = width + 4
        dirty_h = width + 4
    elseif n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]
        if self.current_stroke.tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        else
            self:drawLineSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
        -- Calculate bounding box of the segment
        dirty_x = math.min(p1.x, p2.x) - half_w
        dirty_y = math.min(p1.y, p2.y) - half_w
        dirty_w = math.abs(p2.x - p1.x) + width + 4
        dirty_h = math.abs(p2.y - p1.y) + width + 4
    end

    -- Accumulate dirty region for batch refresh
    if dirty_x then
        if self.dirty_region then
            -- Expand existing dirty region
            local r = self.dirty_region
            local new_x = math.min(r.x, dirty_x)
            local new_y = math.min(r.y, dirty_y)
            local new_x2 = math.max(r.x + r.w, dirty_x + dirty_w)
            local new_y2 = math.max(r.y + r.h, dirty_y + dirty_h)
            self.dirty_region = { x = new_x, y = new_y, w = new_x2 - new_x, h = new_y2 - new_y }
        else
            self.dirty_region = { x = dirty_x, y = dirty_y, w = dirty_w, h = dirty_h }
        end
    end

    -- Periodic refresh of dirty region only.
    -- When Sony Direct Handwriting is active, the kernel paints stylus strokes
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) >= self.refresh_interval_ms then
        self.last_refresh_time = now
        if self.dirty_region then
            local r = self.dirty_region
            -- Clamp to screen bounds
            local rx = math.max(0, math.floor(r.x))
            local ry = math.max(0, math.floor(r.y))
            local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
            local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
            -- On Sony, refreshFast routes through SonyEPDController which
            -- selects DU mode (mode 1 = ~120ms partial, 1-bit). On Kobo the
            -- original GC16 refreshUI is needed for proper color rendering.
            -- On Supernote, the firmware is already painting ink into the
            -- EPDC overlay at sub-frame latency; emitting a Lua-side refresh
            -- here would just race the firmware and visibly flicker the
            -- stroke. Skip the mid-stroke refresh and let the delayed-commit
            -- path bake the stroke into Screen.bb at stroke end.
            if self.supernote_ink_active then
                -- intentional no-op
            elseif self.sony_dhw_active then
                Screen:refreshFast(rx, ry, rw, rh)
            else
                Screen:refreshUI(rx, ry, rw, rh)
            end
            self.dirty_region = nil
        end
    end
end

-- End stroke from raw input
function Pencil:endRawStroke()
    if self.input_debug_mode then
        self:writeDebugLog(string.format("endRawStroke: current_stroke=%s points=%d",
            tostring(self.current_stroke ~= nil),
            self.current_stroke and #self.current_stroke.points or 0))
    end
    if self.current_stroke and #self.current_stroke.points >= 1 then
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)
        self:scheduleDeferredWork()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("endRawStroke: SAVED stroke #%d with %d points, total strokes=%d",
                #self.strokes, #self.current_stroke.points, #self.strokes))
        end
        logger.dbg("Pencil: raw stroke ended with", #self.current_stroke.points, "points")
    else
        if self.input_debug_mode then
            self:writeDebugLog("endRawStroke: NOT SAVED (no current_stroke or no points)")
        end
    end
    self.current_stroke = nil
    -- Schedule delayed refresh for clean display after writing stops
    self:scheduleDelayedRefresh()
end

-- Paint the in-progress text selection as "invert" rectangles while a
-- highlight drag is active. Mirrors what KOReader does during a normal
-- finger long-press+drag: the reader's paintTo iterates
-- self.view.highlight.temp[page] and inversion-paints each sbox. All we
-- have to do is populate that table with our current sboxes, then
-- setDirty so a repaint runs.
function Pencil:_paintTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight and self.ui.highlight) then
        return
    end
    local rh = self.ui.highlight
    local temp = self.ui.view.highlight.temp
    -- Reset any previous frame's temp entries so stale sboxes from earlier
    -- in the drag don't linger after the selection shrinks.
    for k in pairs(temp) do temp[k] = nil end
    if rh.selected_text and rh.selected_text.sboxes and #rh.selected_text.sboxes > 0 then
        local page_key = rh.hold_pos and rh.hold_pos.page or 1
        temp[page_key] = rh.selected_text.sboxes
    end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Clear the in-progress selection preview. Called on pen lift before we
-- persist the selection as a saved highlight (which then paints itself
-- via drawSavedHighlight instead of via temp).
function Pencil:_clearTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight) then return end
    local temp = self.ui.view.highlight.temp
    for k in pairs(temp) do temp[k] = nil end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Start a native KOReader text-highlight selection at a raw stylus position.
-- Called from handleStylusSlot when slot.tool has been promoted to HIGHLIGHTER
-- by input.lua (i.e., the side button is held during a pen contact).
--
-- Manipulates self.ui.highlight (ReaderHighlight) directly because there is
-- no public "start programmatic selection" API — the standard entry points
-- (onHold / onHoldPan) do extra work (panel-zoom probing, gesture wiring)
-- that we don't need and that would interact badly with our stylus-sourced
-- events. The methods we do call (getWordFromPosition / getTextFromPositions
-- / saveHighlight) are the same ones KOReader itself invokes internally.
function Pencil:startTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end  -- Tap outside any page area

    local rh = self.ui.highlight
    rh.hold_pos = page_pos

    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, page_pos)
    if ok and word and word.pos0 and word.pos1 then
        rh.selected_text = {
            text = word.word or "",
            pos0 = word.pos0,
            pos1 = word.pos1,
            sboxes = word.sbox and { word.sbox } or {},
            pboxes = word.pbox and { word.pbox } or {},
        }
    else
        rh.selected_text = nil
    end

    self.highlighting = true
    -- Prevent the drawing-path pen-down branch from also firing on subsequent
    -- events for this contact.
    self.pen_down = true

    -- Show the first-word preview immediately.
    self:_paintTempSelection()
end

-- Extend the active text-highlight selection to a new raw stylus position.
-- Called on each stylus slot update while self.highlighting is true.
function Pencil:extendTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local rh = self.ui.highlight
    if not rh.hold_pos then return end

    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end
    rh.holdpan_pos = page_pos

    -- getTextFromPositions handles EPUB (xpointer) and PDF (x/y/page) shapes
    -- and returns a selection dict with pos0/pos1/text/sboxes/pboxes.
    local ok, selected = pcall(self.ui.document.getTextFromPositions,
                               self.ui.document, rh.hold_pos, rh.holdpan_pos)
    if ok and selected and selected.pos0 and selected.pos1 then
        rh.selected_text = selected
        -- Repaint preview with the new sboxes.
        self:_paintTempSelection()
    end
end

-- Persist the current selection as a KOReader highlight annotation and reset.
-- Called on slot.id transitioning to -1 (pen lift) while self.highlighting.
function Pencil:finishTextHighlight()
    local rh = self.ui and self.ui.highlight
    local has_selection = rh and rh.selected_text
        and rh.selected_text.pos0 and rh.selected_text.pos1

    -- Clear the in-progress preview first; the saved highlight's own paint
    -- path (drawSavedHighlight) will take over on the next frame.
    self:_clearTempSelection()

    if has_selection then
        -- saveHighlight(false) builds the annotation item from self.selected_text
        -- and calls self.ui.annotation:addItem(item) internally, handling the
        -- PDF/EPUB item-shape difference. It emits AnnotationsModified itself,
        -- so we do NOT emit a second one here — a userpatch may further wrap
        -- this call to prompt for color, but that's not the plugin's concern.
        local ok, err = pcall(rh.saveHighlight, rh, false)
        if not ok then
            logger.warn("Pencil: saveHighlight failed:", tostring(err))
        end
    end

    if rh and rh.clear then
        pcall(rh.clear, rh)
    end

    self.highlighting = false
    self.pen_down = false
end

-- Find the index in self.ui.annotation.annotations of a saved text highlight
-- whose rendered boxes cover screen position (screen_x, screen_y).
-- Returns nil if no highlight is at that position.
-- Used by the eraser path so flipping to the eraser end and swiping across a
-- highlight removes it, the same way it removes freehand strokes.
function Pencil:findHighlightAtScreenPos(screen_x, screen_y)
    if not (self.ui and self.ui.annotation and self.ui.annotation.annotations
            and self.ui.view and self.ui.document) then
        return nil
    end

    local is_paging = self.ui.paging ~= nil
    local page_pos
    if is_paging then
        page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
        if not page_pos then return nil end
    end

    for index, item in ipairs(self.ui.annotation.annotations) do
        -- drawer is nil for page-bookmarks; only text highlights have it set.
        if item.drawer and item.pos0 and item.pos1 then
            local boxes
            if is_paging then
                if item.page == page_pos.page then
                    local ok, got = pcall(self.ui.document.getPageBoxesFromPositions,
                                          self.ui.document, page_pos.page, item.pos0, item.pos1)
                    if ok then boxes = got end
                end
            else
                -- Rolling mode (EPUB): work in screen coordinates directly.
                local ok, got = pcall(self.ui.document.getScreenBoxesFromPositions,
                                      self.ui.document, item.pos0, item.pos1, true)
                if ok then boxes = got end
            end
            if boxes then
                local px = is_paging and page_pos.x or screen_x
                local py = is_paging and page_pos.y or screen_y
                for _, box in ipairs(boxes) do
                    if px >= box.x and px < box.x + box.w
                            and py >= box.y and py < box.y + box.h then
                        return index
                    end
                end
            end
        end
    end
    return nil
end

-- Delete any KOReader text highlight at the given screen position.
-- Used by the eraser pass inside handleStylusSlot. removeItemByIndex emits
-- AnnotationsModified and does the logical cleanup, but on e-ink its
-- setDirty is not strong enough to clear the highlight's painted pixels
-- from the framebuffer — users saw the removed highlight linger until the
-- next page turn forced a full refresh. Force a UI-mode setDirty here so
-- the overlay actually disappears.
function Pencil:eraseHighlightAtScreenPos(screen_x, screen_y)
    local index = self:findHighlightAtScreenPos(screen_x, screen_y)
    if not index then return false end
    if not (self.ui and self.ui.bookmark and self.ui.bookmark.removeItemByIndex) then
        return false
    end
    local ok = pcall(self.ui.bookmark.removeItemByIndex, self.ui.bookmark, index)
    if ok then
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
    end
    return ok
end

-- Get the path to the plugin's log file
function Pencil:getDebugLogPath()
    -- Write to KOReader's data directory (always writable)
    local log_dir = DataStorage:getDataDir()
    return log_dir .. "/pencil_input_debug.log"
end

-- Write a line to the debug log file
function Pencil:writeDebugLog(msg)
    if not self.input_debug_mode then return end

    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "a")
    if f then
        local timestamp = os.date("%H:%M:%S")
        f:write(string.format("[%s] %s\n", timestamp, msg))
        f:close()
    end
end

-- Clear the debug log file
function Pencil:clearDebugLog()
    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "w")
    if f then
        f:write("=== Pencil Annotation Input Debug Log ===\n")
        f:write("Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        local device_name = "unknown"
        if Device.model then
            device_name = Device.model
        elseif Device.getDeviceName then
            device_name = Device:getDeviceName() or "unknown"
        end
        f:write("Device: " .. device_name .. "\n")
        f:write("==========================================\n\n")
        f:close()
        logger.info("Pencil: cleared debug log at", log_path)
    end
end

-- Initialize debug logging (clear log and write header)
function Pencil:initDebugLog()
    if not self.input_debug_mode then return end
    self:clearDebugLog()
    self:writeDebugLog("Debug logging enabled")
    local Input = Device.input
    if Input then
        self:writeDebugLog("Input.pen_slot = " .. tostring(Input.pen_slot or "nil"))
    end
end

-- Load plugin settings
function Pencil:loadSettings()
    local settings = G_reader_settings:readSetting("pencil_annotation_settings") or {}
    -- Always start with pencil tool when opening a book
    self.current_tool = TOOL_PEN
    -- Input debug mode: log all input details
    self.input_debug_mode = settings.input_debug_mode or false
    -- Experimental features
    self.experimental_bookmark_sync = settings.experimental_bookmark_sync or false
    -- Swap eraser and highlighter
    self.swap_eraser_and_highlighter = settings.swap_eraser_and_highlighter or false
    -- Double-tap-left-side toggles pen/eraser. Default ON.
    if settings.double_tap_toggle_tool == nil then
        self.double_tap_toggle_tool = true
    else
        self.double_tap_toggle_tool = settings.double_tap_toggle_tool
    end
    self.experimental_pen_width = settings.experimental_pen_width or false
    self.experimental_color_picker = settings.experimental_color_picker or false
    self.experimental_text_highlight = settings.experimental_text_highlight or false
    -- Hold-pen-still opens a pen/eraser toggle in the long-press picker.
    -- Available in both pen and eraser mode. Default ON.
    if settings.experimental_tool_toggle == nil then
        self.experimental_tool_toggle = true
    else
        self.experimental_tool_toggle = settings.experimental_tool_toggle
    end
    -- How long the pen must be held still to open the long-press picker (ms).
    self.color_picker_delay_ms = tonumber(settings.color_picker_delay_ms) or COLOR_PICKER_DELAY_MS
    if self.color_picker_delay_ms < COLOR_PICKER_DELAY_MIN_MS then
        self.color_picker_delay_ms = COLOR_PICKER_DELAY_MIN_MS
    elseif self.color_picker_delay_ms > COLOR_PICKER_DELAY_MAX_MS then
        self.color_picker_delay_ms = COLOR_PICKER_DELAY_MAX_MS
    end
    -- Load pen color by name and look up the actual color value
    local color_name = settings.pen_color_name
    if color_name then
        self.tool_settings[TOOL_PEN].color_name = color_name
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == color_name then
                self.tool_settings[TOOL_PEN].color = color_info.color
                break
            end
        end
    end
    -- Load pen width if previously chosen via the experimental width picker.
    -- Validated against available_widths so a malformed settings file can't
    -- inject arbitrary widths.
    local saved_width = settings.pen_width
    if saved_width then
        for _, w in ipairs(self.available_widths) do
            if w.width == saved_width then
                self.tool_settings[TOOL_PEN].width = saved_width
                break
            end
        end
    end
end

-- Save plugin settings
function Pencil:saveSettings()
    G_reader_settings:saveSetting("pencil_annotation_settings", {
        input_debug_mode = self.input_debug_mode,
        experimental_bookmark_sync = self.experimental_bookmark_sync,
        experimental_pen_width = self.experimental_pen_width,
        experimental_color_picker = self.experimental_color_picker,
        experimental_text_highlight = self.experimental_text_highlight,
        experimental_tool_toggle = self.experimental_tool_toggle,
        color_picker_delay_ms = self.color_picker_delay_ms,
        pen_color_name = self.tool_settings[TOOL_PEN].color_name,
        swap_eraser_and_highlighter = self.swap_eraser_and_highlighter,
        double_tap_toggle_tool = self.double_tap_toggle_tool,
        pen_width = self.tool_settings[TOOL_PEN].width,
    })
end

-- Set current tool. Pass silent=true to skip the corner badge (e.g. when the
-- caller shows its own confirmation, like the long-press picker's toast).
function Pencil:setTool(tool, silent)
    self.current_tool = tool
    self:saveSettings()
    self:applySupernotePen()
    self:applyOnyxStyle()
    if not silent then
        self:showToolBadge()
    end
end

function Pencil:isEnabled()
    -- Default ON: when the setting has never been written (fresh install),
    -- treat the plugin as enabled so the supernote_ink build lights up
    -- pencil out of the box.
    local v = G_reader_settings:readSetting("pencil_annotation_enabled")
    if v == nil then return true end
    return v == true
end

-- Check if a menu or overlay is shown on top of the reader view.
-- When true, pen input should pass through so the overlay can handle it.
function Pencil:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    -- ReaderUI is the document view itself — anything else is an overlay.
    -- getTopmostVisibleWidget skips widgets marked invisible — transient
    -- decorations that paint but don't capture input, e.g. TrapWidget.
    return (top.name or top.id) ~= "ReaderUI"
end

-- Set enabled state (global setting)
function Pencil:setEnabled(enabled)
    G_reader_settings:saveSetting("pencil_annotation_enabled", enabled)
end

function Pencil:addToMainMenu(menu_items)
    menu_items.pencil_annotation = {
        text = _("Pencil"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enabled"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    self:onPencilToggleEnabled()
                end,
                separator = true,
            },
            {
                text = _("Swap Eraser and Highlighter"),
                checked_func = function()
                    return self.swap_eraser_and_highlighter
                end,
                callback = function()
                    self.swap_eraser_and_highlighter = not self.swap_eraser_and_highlighter
                    self:saveSettings()
                end,
            },
            {
                text = _("Double tap left to toggle pencil/eraser"),
                help_text = _("Double-tap the left side of the screen with your finger to switch between pencil and eraser. When off, finger double-tap-left falls back to KOReader's default action."),
                checked_func = function()
                    return self.double_tap_toggle_tool
                end,
                callback = function()
                    self.double_tap_toggle_tool = not self.double_tap_toggle_tool
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text = _("Tool"),
                help_text = _("Select pencil or eraser."),
                sub_item_table = {
                    {
                        text = _("Pencil"),
                        checked_func = function()
                            return self.current_tool == TOOL_PEN
                        end,
                        callback = function()
                            self:setTool(TOOL_PEN)
                        end,
                    },
                    {
                        text = _("Eraser"),
                        checked_func = function()
                            return self.current_tool == TOOL_ERASER
                        end,
                        callback = function()
                            self:setTool(TOOL_ERASER)
                        end,
                    },
                },
            },
            {
                text = _("Undo last stroke"),
                callback = function()
                    self:undoLastStroke()
                end,
                enabled_func = function()
                    return #self.undo_stack > 0
                end,
                separator = true,
            },
            {
                text = _("Clear page strokes"),
                callback = function()
                    self:clearPageStrokes()
                end,
                enabled_func = function()
                    return self:hasStrokesOnCurrentPage()
                end,
            },
            {
                text = _("Clear all strokes"),
                callback = function()
                    self:clearAllStrokes()
                end,
                enabled_func = function()
                    return #self.strokes > 0
                end,
            },
            {
                text_func = function()
                    local bytes = self:getImagesSizeBytes()
                    if bytes <= 0 then
                        return _("Annotation images: none")
                    elseif bytes < 1024 * 1024 then
                        return T(_("Annotation images: %1 KB"), math.floor(bytes / 1024))
                    else
                        return T(_("Annotation images: %1 MB"),
                            string.format("%.1f", bytes / (1024 * 1024)))
                    end
                end,
                help_text = _("Saved preview images of your annotations are used to show what you wrote even after the device is rotated, and to preview annotations from the bookmark list. Tap to clear them for this book."),
                keep_menu_open = true,
                enabled_func = function()
                    return self:getImagesSizeBytes() > 0
                end,
                callback = function(touchmenu_instance)
                    self:purgeAllImages()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    UIManager:show(InfoMessage:new{
                        text = _("Cleared all annotation preview images for this book."),
                        timeout = 2,
                    })
                end,
                separator = true,
            },
            {
                text = _("Experimental"),
                sub_item_table = {
                    {
                        text = _("Bookmark sync"),
                        help_text = _("Automatically create KOReader bookmarks for pencil annotations so you can navigate to annotated pages from the Bookmarks menu."),
                        checked_func = function()
                            return self.experimental_bookmark_sync
                        end,
                        callback = function()
                            self.experimental_bookmark_sync = not self.experimental_bookmark_sync
                            self:saveSettings()
                            if self.experimental_bookmark_sync then
                                self:syncAllBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync enabled. Pencil annotations will appear in the Bookmarks menu."),
                                    timeout = 3,
                                })
                            else
                                self:removeAllPencilBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync disabled. Pencil bookmarks removed."),
                                    timeout = 3,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Color picker"),
                        help_text = _("Allow the hold-pen-still gesture to open a picker for changing pen color (and, if the pen width picker is also enabled, stroke width). When disabled, the pen stays on its last-saved color."),
                        checked_func = function()
                            return self.experimental_color_picker
                        end,
                        callback = function()
                            self.experimental_color_picker = not self.experimental_color_picker
                            self:saveSettings()
                            if self.experimental_color_picker then
                                UIManager:show(InfoMessage:new{
                                    text = _("Color picker enabled. Hold the pen still to open it."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Color picker disabled. Pen will keep its current color."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Pen width picker"),
                        help_text = _("Add pen width options (3, 5, 7, 9) to the color picker. The width buttons appear as black bars whose height previews the stroke thickness. Requires the color picker to also be enabled."),
                        checked_func = function()
                            return self.experimental_pen_width
                        end,
                        callback = function()
                            self.experimental_pen_width = not self.experimental_pen_width
                            self:saveSettings()
                            if self.experimental_pen_width then
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen width picker enabled. Hold the pen still to open the picker and choose a stroke width."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen width picker disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Pen/eraser toggle"),
                        help_text = _("Add a pen/eraser toggle to the hold-pen-still picker. The toggle row shows a filled square (pen) and a hollow square (eraser); tap to switch tools. Available in both pen and eraser mode \xe2\x80\x94 hold the stylus still on a blank spot to summon it."),
                        checked_func = function()
                            return self.experimental_tool_toggle
                        end,
                        callback = function()
                            self.experimental_tool_toggle = not self.experimental_tool_toggle
                            self:saveSettings()
                            if self.experimental_tool_toggle then
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen/eraser toggle enabled. Hold the stylus still to open the picker and switch tools."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen/eraser toggle disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Long-press hold time: %1 ms"),
                                     self.color_picker_delay_ms or COLOR_PICKER_DELAY_MS)
                        end,
                        help_text = _("How long to hold the stylus still on a blank spot before the long-press picker (pen/eraser toggle, width, color) opens. Shorter is quicker to trigger but more likely to fire on an accidental pause. A real stroke never triggers it (moving cancels the hold)."),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            UIManager:show(SpinWidget:new{
                                title_text = _("Long-press hold time"),
                                info_text = _("Milliseconds to hold the stylus still before the picker opens."),
                                value = self.color_picker_delay_ms or COLOR_PICKER_DELAY_MS,
                                value_min = COLOR_PICKER_DELAY_MIN_MS,
                                value_max = COLOR_PICKER_DELAY_MAX_MS,
                                value_step = 50,
                                value_hold_step = 100,
                                unit = _("ms"),
                                ok_text = _("Set"),
                                callback = function(spin)
                                    self.color_picker_delay_ms = spin.value
                                    self:saveSettings()
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    },
                    {
                        text = _("Text highlight (side button)"),
                        help_text = _("When enabled, holding the stylus side button during a pen drag creates a native KOReader text highlight on the underlying words, like a long-press \xe2\x86\x92 Highlight. Off by default because this is a new integration and has edge cases. Requires a stylus that sends BTN_STYLUS2."),
                        checked_func = function()
                            return self.experimental_text_highlight
                        end,
                        callback = function()
                            self.experimental_text_highlight = not self.experimental_text_highlight
                            self:saveSettings()
                            if self.experimental_text_highlight then
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight enabled. Hold the side button while dragging the pen across words."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Input debug mode"),
                help_text = _("Enable detailed logging of input events to help diagnose stylus detection issues."),
                checked_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self.input_debug_mode = not self.input_debug_mode
                    self:saveSettings()
                    if self.input_debug_mode then
                        -- Initialize debug logging
                        self:initDebugLog()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Input debug mode enabled.\n\nLog file: %1\n\nUse both pen tip and eraser end, then check the log."), self:getDebugLogPath()),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Input debug mode disabled."),
                        })
                    end
                end,
            },
            {
                text = _("Clear debug log"),
                enabled_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self:clearDebugLog()
                    UIManager:show(InfoMessage:new{
                        text = _("Debug log cleared. Ready to capture new input events."),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Show annotation status"),
                callback = function()
                    self:showAnnotationStatus()
                end,
            },
        },
    }
end

-- Show current annotation status for debugging
function Pencil:showAnnotationStatus()
    local page = self:getCurrentPage()
    local page_strokes = self.page_strokes[page] and #self.page_strokes[page] or 0
    local filepath = self:getStrokesFilePath() or "not available"

    -- Show all pages with strokes for debugging
    local pages_info = ""
    for p, indices in pairs(self.page_strokes) do
        pages_info = pages_info .. string.format("\n  %s (%s): %d", tostring(p), type(p), #indices)
    end
    if pages_info == "" then
        pages_info = "\n  (none)"
    end

    -- Stylus callback status
    local Input = Device.input
    local pen_slot = Input and Input.pen_slot or "N/A"
    local stylus_callback_status = self.stylus_callback_registered and "registered" or "not registered"
    local pen_down_status = self.pen_down and "YES" or "no"

    local status_text = T(_([[Pencil Annotation Status

Selected tool: %1
Total strokes: %2
Strokes on this page: %3
Current page: %4 (%5)
Storage file: %6
Enabled: %7

Stylus callback: %9
Pen slot: %10
Pen down: %11

Side button: tap to toggle pen/eraser, hold+drag to highlight.

Enable "Input debug mode" to log raw events for diagnosis.

Pages with strokes:%8]]),
        self.current_tool,
        #self.strokes,
        page_strokes,
        tostring(page),
        type(page),
        filepath,
        self:isEnabled() and _("Yes") or _("No"),
        pages_info,
        stylus_callback_status,
        tostring(pen_slot),
        pen_down_status
    )

    UIManager:show(InfoMessage:new{
        text = status_text,
    })
end

-- Handle stylus button press (down event)
-- Side button behavior:
--   - Hold + drag = temporarily highlight, then return to original tool
--   - Quick press (no drawing while held) = toggle between pen and eraser
function Pencil:onStylusButtonPress()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    self.side_button_down = true
    self.side_button_used_for_highlight = false

    logger.dbg("Pencil: side button pressed")
    return true
end

-- Handle stylus button release (up event)
function Pencil:onStylusButtonRelease()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    local was_down = self.side_button_down
    self.side_button_down = false

    -- If the button was NOT used for highlighting (no drawing while held),
    -- treat it as a quick press to toggle between pen and eraser
    if was_down and not self.side_button_used_for_highlight then
        logger.dbg("Pencil: side button quick press - toggling pen/eraser")
        self:togglePenEraser()
    else
        -- Was used for highlighting - show brief feedback that we're back to normal
        logger.dbg("Pencil: highlight complete, back to", self.current_tool)
    end

    self.side_button_used_for_highlight = false
    return true
end

-- Toggle between pen and eraser
function Pencil:togglePenEraser()
    local old_tool = self.current_tool
    local new_tool
    if self.current_tool == TOOL_ERASER then
        new_tool = TOOL_PEN
    else
        new_tool = TOOL_ERASER
    end

    self.current_tool = new_tool
    self:saveSettings()
    logger.dbg("Pencil: toggled from", old_tool, "to", new_tool)
    self:showToolBadge()
end

-- Handle stylus button and tool events
function Pencil:onKeyPress(key)
    if not key then return false end
    if key.key == "SidebarDoubleFinger" then return true end
    local ok, key_str = pcall(tostring, key)
    if not ok then key_str = "unknown" end

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY PRESS: %s key.key=%s", key_str, tostring(key.key)))
    end

    -- Hardware Eraser button - works regardless of pencil enabled state
    if (not self.swap_eraser_and_highlighter and key.key == "Eraser") then
        logger.info("Pencil: Eraser button PRESSED")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        return true
    end

    -- BTN_TOOL_RUBBER - physical eraser end - works regardless of pencil enabled state
    if (self.swap_eraser_and_highlighter and (key_str:match("Highlighter") or key_str:match("Stylus"))) or (not self.swap_eraser_and_highlighter and (key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber"))) then
        logger.info("Pencil: BTN_TOOL_RUBBER press - activating eraser mode")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        self.eraser_tool_active = true
        return true
    end

    -- BTN_TOOL_PEN - pen tip - deactivate eraser mode
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.info("Pencil: BTN_TOOL_PEN press - deactivating eraser mode")
        if self.eraser_button_active and self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            -- Save any pending eraser deletions before switching to pen
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.eraser_tool_active = false
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- BTN_STYLUS (331) - side button on stylus (mapped to "Eraser" on Kobo)
    -- BTN_STYLUS2 (332) - second side button (mapped to "Highlighter" on Kobo)
    if (self.swap_eraser_and_highlighter and key.key == "Eraser") or (not self.swap_eraser_and_highlighter and (key_str:match("Highlighter") or key_str:match("Stylus"))) then
        logger.dbg("Pencil: Stylus button press detected:", key_str)
        return self:onStylusButtonPress()
    end
    return false
end

function Pencil:onKeyRelease(key)
    if not key then return false end

    -- Supernote left sidebar double-finger: toggle pencil/eraser
    if key.key == "SidebarDoubleFinger" and self:isEnabled() then
        self:onPencilToggleTool()
        return true
    end

    local ok, key_str = pcall(tostring, key)
    if not ok then key_str = "unknown" end

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY RELEASE: %s key.key=%s", key_str, tostring(key.key)))
    end

    -- Hardware Eraser button released
    if key.key == "Eraser" and self.eraser_button_active then
        logger.info("Pencil: Eraser button RELEASED")
        self.eraser_button_active = false
        if self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_deleted = nil
        UIManager:setDirty(self.view, "ui")
        return true
    end

    -- BTN_TOOL_RUBBER released (eraser end moved away) - works regardless of pencil enabled state
    if key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber") then
        logger.info("Pencil: BTN_TOOL_RUBBER release - deactivating eraser mode")
        if self.eraser_button_active and self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.eraser_tool_active = false
        UIManager:setDirty(self.view, "ui")
        return true
    end

    -- BTN_TOOL_PEN released
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.dbg("Pencil: BTN_TOOL_PEN release detected")
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Side button released
    if key_str:match("Highlighter") or key_str:match("Stylus") then
        logger.dbg("Pencil: Stylus button release detected:", key_str)
        return self:onStylusButtonRelease()
    end
    return false
end

-- Undo last stroke
function Pencil:undoLastStroke()
    if #self.undo_stack == 0 then return end

    local last_action = table.remove(self.undo_stack)
    if last_action.type == "add" then
        -- Remove the stroke that was added
        local stroke_idx = last_action.stroke_idx
        if stroke_idx and self.strokes[stroke_idx] then
            table.remove(self.strokes, stroke_idx)
            self:rebuildPageIndex()
            self:rebuildAnnotationGroups()
            self:saveStrokes()
            UIManager:setDirty(self.view, "ui")
        end
    elseif last_action.type == "delete" then
        -- Restore deleted strokes
        for _, stroke in ipairs(last_action.strokes) do
            table.insert(self.strokes, stroke)
        end
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        self:saveStrokes()
        UIManager:setDirty(self.view, "ui")
    end
end

function Pencil:setupPenInput()
    if self.touch_zones_registered then return end

    logger.dbg("Pencil: setting up touch zones")

    -- Setup stylus callback for lowest latency pen capture
    self:setupStylusCallback()
    -- Register touch zones through the UI so they're in the active gesture hierarchy
    -- We need to override ALL gestures that might interfere with drawing
    self.ui:registerTouchZones({
        {
            -- Touch gesture fires IMMEDIATELY on first contact - critical for capturing stroke start
            id = "pencil_draw_touch",
            ges = "touch",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {},
            handler = function(ges)
                return self:onDrawTouch(ges)
            end,
        },
        {
            id = "pencil_draw_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
                "readerfooter_tap",
                "readerconfigmenu_tap",
                "readerhighlight_tap",
                "readermenu_tap",
                "paging_tap",
                "rolling_tap",
            },
            handler = function(ges)
                return self:onDrawTap(ges)
            end,
        },
        {
            id = "pencil_draw_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerhighlight_hold",
                "readerfooter_hold",
            },
            handler = function(ges)
                return self:onDrawHold(ges)
            end,
        },
        {
            id = "pencil_draw_pan",
            ges = "pan",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan",
                "rolling_pan",
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_pan",
            },
            handler = function(ges)
                return self:onDrawPan(ges)
            end,
        },
        {
            id = "pencil_draw_pan_release",
            ges = "pan_release",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan_release",
                "rolling_pan_release",
                "readerhighlight_pan_release",
            },
            handler = function(ges)
                return self:onDrawPanRelease(ges)
            end,
        },
        {
            id = "pencil_draw_swipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_swipe",
            },
            handler = function(ges)
                return self:onDrawSwipe(ges)
            end,
        },
        {
            -- Default convenience gesture: double-tap left quarter of the
            -- screen toggles pencil/eraser. Matches gestures.koplugin's
            -- zone_left (ratio 1/4 x 1) so we override the same area.
            id = "pencil_double_tap_left_toggle_tool",
            ges = "double_tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1/4, ratio_h = 1,
            },
            overrides = {
                "double_tap_left_side",
            },
            handler = function(ges)
                return self:onDoubleTapLeftToggleTool(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function Pencil:teardownPenInput()
    if not self.touch_zones_registered then return end

    -- Teardown stylus callback
    self:teardownStylusCallback()

    self.ui:unRegisterTouchZones({
        { id = "pencil_draw_touch" },  -- Must unregister touch zone too
        { id = "pencil_draw_tap" },
        { id = "pencil_draw_hold" },
        { id = "pencil_draw_pan" },
        { id = "pencil_draw_pan_release" },
        { id = "pencil_draw_swipe" },
        { id = "pencil_double_tap_left_toggle_tool" },
    })
    self.touch_zones_registered = false
end

-- Default convenience gesture: a *finger* double-tap on the left quarter of
-- the screen switches between pencil and eraser. Pen-sourced double-taps
-- (rare in practice — the stylus callback dominates pen events before they
-- reach gesture_detector) fall through so the stylus keeps drawing.
function Pencil:onDoubleTapLeftToggleTool(ges)
    if not self:isEnabled() then return false end
    if not self.double_tap_toggle_tool then return false end
    if self:isOverlayActive() then return false end
    -- Finger-only: if the active MT slot is a stylus, don't intercept.
    local is_pen = self:isPenInput(ges)
    if is_pen then return false end
    if self:_isPalmRejecting() then return true end
    self:onPencilToggleTool()
    return true
end

-- Handle swipe gestures (block them when drawing mode is active)
function Pencil:onDrawSwipe(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen, block swipe to prevent page turns
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block the swipe - we don't want page turns while drawing
    return true
end

-- Handle tip long press (hold gesture)
function Pencil:onDrawHold(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen, block hold to prevent reader highlight mode
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block pen hold gestures while drawing mode is active
    return true
end

-- Schedule a delayed refresh after writing stops
function Pencil:scheduleDelayedRefresh()
    -- Cancel any existing pending refresh
    self:cancelPendingRefresh()

    -- UIManager:scheduleIn returns NOTHING — we must keep our own
    -- reference to the function we scheduled so cancelPendingRefresh can
    -- unschedule it by identity. Previously this was bugged: scheduling
    -- assigned nil to pending_refresh, so cancel never fired, and every
    -- stroke piled another 600ms timer onto the queue. Fast consecutive
    -- strokes blew past the timer and KOReader committed mid-write.
    local action = function()
        self.pending_refresh = nil
        local region
        if self.sony_dhw_active and self.dirty_region then
            local r = self.dirty_region
            self.dirty_region = nil
            local rx = math.max(0, math.floor(r.x))
            local ry = math.max(0, math.floor(r.y))
            local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
            local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
            region = Geom:new{x = rx, y = ry, w = rw, h = rh}
            UIManager:setDirty(self.view, "fast", region)
            logger.dbg("Pencil: delayed refresh triggered (partial",
                       rx, ry, rw, rh, ")")
        else
            UIManager:setDirty(self.view, "fast")
            logger.dbg("Pencil: delayed refresh triggered (full)")
        end
        -- The setDirty above queues a repaint for the next UI tick.
        -- Wipe the StylusView overlay AFTER that tick has had a chance
        -- to commit KOReader's page-with-strokes — scheduleIn(0.3)
        -- (roughly two DU waveform periods) gives the EPD time to flush.
        -- Doing it inline would clear the overlay before the page repaints,
        -- flashing the strokes off the screen briefly.
        if self.sony_dhw_active then
            UIManager:scheduleIn(0.3, function()
                local ok, android = pcall(require, "android")
                if ok and android and android.stylusOverlayClear then
                    android.stylusOverlayClear()
                end
            end)
        end
        -- Supernote: after KOReader has had time to bake the stroke into
        -- Screen.bb and present it, wipe the firmware's EPDC ink overlay
        -- so it stops double-painting on top of the persistent stroke.
        if self.supernote_ink_active then
            UIManager:scheduleIn(0.3, function()
                SupernoteInk.clearAll()
            end)
        end
        -- Huawei: same idea as Supernote. The firmware showed the live ink on
        -- its overlay during drawing; now that KOReader has baked the strokes
        -- into Screen.bb and the setDirty above repaints the page with them,
        -- wipe the firmware overlay so it stops double-printing.
        if self.huawei_ahw_active then
            UIManager:scheduleIn(0.3, function()
                local ok, android = pcall(require, "android")
                if ok and android and android.huaweiAhwClear then
                    android.huaweiAhwClear()
                end
            end)
        end
        -- Onyx commits each stroke inline (per-stroke partial refresh +
        -- onyxScribbleResetFreeze in drainOnyxStrokes), so there's nothing to
        -- do on the delayed-refresh timer here.
    end
    self.pending_refresh = action
    UIManager:scheduleIn(self.refresh_delay_ms / 1000, action)
end

-- Cancel pending refresh (called when new stroke starts)
function Pencil:cancelPendingRefresh()
    if self.pending_refresh then
        UIManager:unschedule(self.pending_refresh)
        self.pending_refresh = nil
    end
end

-- Mark strokes as dirty. Actual disk write is deferred until the user
-- changes page or closes the document — saving on every stroke caused
-- visible inter-stroke pauses on slow flash. flushDeferredWork is the
-- single drain point; see onPageUpdate / onUpdatePos / onCloseDocument.
function Pencil:scheduleDeferredWork()
    self.strokes_dirty = true
end

function Pencil:cancelPendingSave()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
end

-- Run any pending deferred work immediately. Called before close, page change,
-- or any path that must persist state synchronously.
function Pencil:flushDeferredWork()
    local has_dirty_groups = self.dirty_groups and next(self.dirty_groups)
    if not self.strokes_dirty and not has_dirty_groups then
        return
    end
    self:cancelPendingSave()
    self:flushDirtyGroups()
    self:saveStrokes()
end

-- Sync bookmarks for any groups marked dirty since the last flush. No-op when
-- the experimental bookmark sync feature is off or nothing is pending.
function Pencil:flushDirtyGroups()
    if not self.dirty_groups then return end
    if not self.experimental_bookmark_sync then
        self.dirty_groups = nil
        return
    end
    for _, group in pairs(self.dirty_groups) do
        self:syncGroupBookmark(group)
    end
    self.dirty_groups = nil
end

-- Reset color picker tracking (called when pen moves too far)
function Pencil:resetColorPickerTracking()
    self.color_picker_start_x = nil
    self.color_picker_start_y = nil
    self.color_picker_start_time = nil
end

-- Check if color picker should be shown (called periodically while pen is down)
function Pencil:checkColorPickerTrigger()
    -- Gated behind the experimental flags. At least one must be on for the
    -- hold-pen-still gesture to produce anything; otherwise the pen stays on
    -- its last-saved color/width and no picker opens.
    if not (self.experimental_color_picker or self.experimental_pen_width
            or self.experimental_tool_toggle) then return end
    if not self.color_picker_start_time then return end
    if self.color_picker_showing then return end

    local elapsed_ms = time.to_ms(time.now() - self.color_picker_start_time)
    if elapsed_ms >= (self.color_picker_delay_ms or COLOR_PICKER_DELAY_MS) then
        -- Time elapsed without moving too far - show color picker
        self:showColorPicker(self.pen_x, self.pen_y)
        self:resetColorPickerTracking()
    end
end

-- Schedule periodic check for color picker trigger
function Pencil:scheduleColorPickerCheck()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
    end

    local plugin = self
    -- UIManager:scheduleIn returns nothing — store the action itself so
    -- cancelColorPickerTimer can unschedule by identity. Without this the
    -- 100 ms poll never cancels and stacks more polls each pen-down.
    local action = function()
        plugin.color_picker_check_pending = nil
        if plugin.pen_down and plugin.color_picker_start_time and not plugin.color_picker_showing then
            plugin:checkColorPickerTrigger()
            -- Schedule next check if still waiting
            if plugin.color_picker_start_time then
                plugin:scheduleColorPickerCheck()
            end
        end
    end
    self.color_picker_check_pending = action
    UIManager:scheduleIn(0.1, action)
end

-- Cancel color picker check
function Pencil:cancelColorPickerTimer()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
        self.color_picker_check_pending = nil
    end
    self:resetColorPickerTracking()
end

-- Color picker widget for selecting pen color (and optionally pen width).
-- When `widths` is provided, the widget shows two rows: colors on top,
-- widths below. The width row contains black bars whose vertical thickness
-- matches the actual stroke thickness in device pixels (what-you-see is
-- what-you-draw).
local ColorPickerWidget = InputContainer:extend {
    width = nil,
    height = nil,
    colors = nil, -- Array of {color, name} objects
    widths = nil, -- Optional array of {name, width} objects (experimental width picker)
    tools = nil, -- Optional array of {kind="tool", tool_value=...} (pen/eraser toggle)
    current_color_name = nil, -- Currently selected color name (for comparison)
    current_width = nil, -- Currently selected pen width (for width selection indicator)
    current_tool = nil, -- Currently selected tool (for toggle selection indicator)
    callback = nil,
    close_callback = nil,
    -- Layout constants cached after init so handlePenTap / paintTo don't
    -- recompute them. Kept on self so tests can read them too.
    _button_size = nil,
    _spacing = nil,
    _row_gap = nil,
    _padding = nil,
}

-- Build one button (color or width). Returns the InputContainer button, which
-- also stores its own color / width metadata so the callback can route without
-- string-matching on name.
function ColorPickerWidget:_makeButton(item, button_size, selection_border)
    -- Selection: colors compare by name, widths by width value, tools by tool.
    local is_selected
    if item.kind == "width" then
        is_selected = (item.width_value == self.current_width)
    elseif item.kind == "tool" then
        is_selected = (item.tool_value == self.current_tool)
    else
        is_selected = (item.name == self.current_color_name)
    end
    local border_size = is_selected and selection_border or Size.border.thick

    local swatch
    if item.kind == "tool" then
        -- Pen/eraser glyph, matching showToolBadge: a filled black square
        -- means pen, a hollow square means eraser. Rendered as a centered
        -- icon on a white button so it reads as a tool, not a color swatch.
        local inner = button_size - border_size * 2
        local icon_size = math.floor(inner * 0.55)
        -- FrameContainer:getSize() = content + bordersize*2, so subtract the
        -- border from the hollow square's content to keep both glyphs the same
        -- icon_size outer square (pen filled, eraser hollow).
        local icon
        if item.tool_value == TOOL_ERASER then
            local hollow_inner = math.max(1, icon_size - Size.border.thick * 2)
            icon = FrameContainer:new{
                padding = 0,
                margin = 0,
                bordersize = Size.border.thick,
                color = Blitbuffer.COLOR_BLACK,
                background = Blitbuffer.COLOR_WHITE,
                WidgetContainer:new{
                    dimen = Geom:new{ w = hollow_inner, h = hollow_inner },
                },
            }
        else
            icon = FrameContainer:new{
                padding = 0,
                margin = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_BLACK,
                WidgetContainer:new{
                    dimen = Geom:new{ w = icon_size, h = icon_size },
                },
            }
        end
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = inner, h = inner },
                icon,
            },
        }
    elseif item.kind == "width" then
        -- Truthful preview: a horizontal black bar whose height equals the
        -- stroke's actual device-pixel thickness. We deliberately do NOT
        -- scale by Screen:scaleBySize — the stroke itself is drawn in raw
        -- pixels (see paintRectRGB32 in drawLineSegment), so scaling here
        -- would lie about the line weight.
        local inner = button_size - border_size * 2
        local bar_h = item.width_value
        local bar_w = math.floor(inner * 0.7)
        local bar = FrameContainer:new{
            width = bar_w,
            height = bar_h,
            padding = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_BLACK,
            WidgetContainer:new{
                dimen = Geom:new{ w = bar_w, h = bar_h },
            },
        }
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = inner, h = inner },
                bar,
            },
        }
    else
        -- Regular color swatch
        local border_color = Blitbuffer.COLOR_BLACK
        if item.name == "Black" then
            border_color = Blitbuffer.Color8(0x44)
        end
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = border_color,
            background = item.color_value,
            WidgetContainer:new{
                dimen = Geom:new{ w = button_size - border_size * 2, h = button_size - border_size * 2 },
            },
        }
        if Screen.night_mode and item.name ~= "Black" and item.name ~= "Gray" then
            swatch.background = swatch.background:invert()
        end
    end

    local button = InputContainer:new{
        dimen = Geom:new{ w = button_size, h = button_size },
        swatch,
        kind = item.kind,
        color_value = item.color_value,  -- nil for width/tool items
        color_name = item.name,
        width_value = item.width_value,  -- nil for color/tool items
        tool_value = item.tool_value,    -- nil for color/width items
    }

    button.ges_events = {
        TapSelectColor = {
            GestureRange:new{
                ges = "tap",
                range = function() return button.dimen end,
            },
        },
    }

    local widget = self
    button.onTapSelectColor = function(btn)
        if widget.callback then
            widget.callback(btn.color_value, btn.color_name, btn.width_value, btn.tool_value)
        end
        if widget.close_callback then
            widget.close_callback()
        end
        return true
    end

    return button
end

-- Build a HorizontalGroup row of buttons from an item list. Populates the
-- supplied `info_list` in-tap-index order.
function ColorPickerWidget:_buildRow(items, button_size, spacing, selection_border, info_list)
    local group = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(group, HorizontalSpan:new{ width = spacing })
        end
        local button = self:_makeButton(item, button_size, selection_border)
        table.insert(group, button)
        table.insert(info_list, button)
    end
    return group
end

function ColorPickerWidget:init()
    local button_size = Screen:scaleBySize(36)
    local spacing = Screen:scaleBySize(8)
    local row_gap = Screen:scaleBySize(8)  -- vertical gap between color row and width row
    local padding = Screen:scaleBySize(10)
    local selection_border = Size.border.thick * 3

    self._button_size = button_size
    self._spacing = spacing
    self._row_gap = row_gap
    self._padding = padding

    -- Build optional color row. `colors` is nil when the color-picker
    -- experimental flag is off; in that case we render a widths-only picker.
    local has_colors = self.colors and #self.colors > 0
    self.color_buttons_info = {}
    local color_row_group
    local colors_row_width = 0
    if has_colors then
        local color_items = {}
        for _, color_info in ipairs(self.colors) do
            table.insert(color_items, {
                kind = "color",
                name = color_info.name,
                color_value = color_info.color,
            })
        end
        color_row_group = self:_buildRow(color_items, button_size, spacing, selection_border, self.color_buttons_info)
        colors_row_width = #color_items * button_size + (#color_items - 1) * spacing
    end

    -- Build optional width row
    local has_widths = self.widths and #self.widths > 0
    self.width_buttons_info = {}
    local width_row_group
    local widths_row_width = 0
    if has_widths then
        local width_items = {}
        for _, width_info in ipairs(self.widths) do
            table.insert(width_items, {
                kind = "width",
                name = width_info.name,
                width_value = width_info.width,
            })
        end
        width_row_group = self:_buildRow(width_items, button_size, spacing, selection_border, self.width_buttons_info)
        widths_row_width = #width_items * button_size + (#width_items - 1) * spacing
    end

    -- Build optional pen/eraser toggle row. `tools` is already a list of
    -- {kind="tool", tool_value=...} items.
    local has_tools = self.tools and #self.tools > 0
    self.tool_buttons_info = {}
    local tool_row_group
    local tools_row_width = 0
    if has_tools then
        tool_row_group = self:_buildRow(self.tools, button_size, spacing, selection_border, self.tool_buttons_info)
        tools_row_width = #self.tools * button_size + (#self.tools - 1) * spacing
    end

    -- Assemble the visible rows in display order (colors, widths, tools).
    -- Inner width accommodates the widest visible row; height accumulates one
    -- button_size per row plus a gap between each adjacent pair.
    local row_groups = {}
    if has_colors then table.insert(row_groups, color_row_group) end
    if has_widths then table.insert(row_groups, width_row_group) end
    if has_tools then table.insert(row_groups, tool_row_group) end

    local visible_rows = #row_groups
    local inner_w = math.max(colors_row_width, widths_row_width, tools_row_width)
    self.width = inner_w
    self.height = visible_rows * button_size
        + (visible_rows > 1 and (visible_rows - 1) * row_gap or 0)

    local content
    if visible_rows == 1 then
        content = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = button_size },
            row_groups[1],
        }
    else
        content = VerticalGroup:new{ align = "center" }
        for i, group in ipairs(row_groups) do
            if i > 1 then
                table.insert(content, VerticalSpan:new{ width = row_gap })
            end
            table.insert(content, CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = button_size },
                group,
            })
        end
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = padding,
        content,
    }

    self[1] = self.frame
    self.dimen = self.frame:getSize()

    -- Register gesture to close when tapping outside
    self.ges_events = {
        TapCloseOutside = {
            GestureRange:new{
                ges = "tap",
                range = function() return Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(),
                    h = Screen:getHeight(),
                } end,
            },
        },
    }
end

-- Hit-test one row of buttons. `row_y` is the top y of the row in absolute
-- coordinates. Returns the matching button info or nil.
function ColorPickerWidget:_hitRow(x, y, row_y, info_list)
    local button_size = self._button_size
    local spacing = self._spacing
    if #info_list == 0 then return nil end
    if y < row_y or y >= row_y + button_size then return nil end

    local row_buttons_width = #info_list * button_size + (#info_list - 1) * spacing
    local row_start_x = self.dimen.x + (self.dimen.w - row_buttons_width) / 2
    local relative_x = x - row_start_x
    if relative_x < 0 or relative_x >= row_buttons_width then return nil end

    local stride = button_size + spacing
    local idx = math.floor(relative_x / stride) + 1
    local pos_in_slot = relative_x - (idx - 1) * stride
    if pos_in_slot >= button_size then return nil end
    if idx < 1 or idx > #info_list then return nil end
    return info_list[idx]
end

-- The button info-lists for the visible rows, in top-to-bottom display order
-- (colors, widths, tools). Empty rows are omitted so they don't consume a
-- vertical slot — both hit-testing and painting walk this same list, keeping
-- them in lockstep regardless of which experimental flags are on.
function ColorPickerWidget:_orderedRows()
    local rows = {}
    if #self.color_buttons_info > 0 then table.insert(rows, self.color_buttons_info) end
    if #self.width_buttons_info > 0 then table.insert(rows, self.width_buttons_info) end
    if self.tool_buttons_info and #self.tool_buttons_info > 0 then
        table.insert(rows, self.tool_buttons_info)
    end
    return rows
end

-- Handle pen/stylus tap on color picker
-- Returns true if the tap was handled (hit a button or was inside picker)
function ColorPickerWidget:handlePenTap(x, y)
    if not self.dimen then
        return false
    end

    -- Check if tap is inside the widget
    local inside = x >= self.dimen.x and x < self.dimen.x + self.dimen.w
            and y >= self.dimen.y and y < self.dimen.y + self.dimen.h

    if not inside then
        -- Tap outside - close the picker
        if self.close_callback then
            self.close_callback()
        end
        return true  -- Consume the event to prevent drawing
    end

    local border = Size.border.window
    local button_size = self._button_size
    local row_gap = self._row_gap
    local padding = self._padding

    -- Hidden rows are omitted, so each present row slides up to fill the gap.
    -- Walk the ordered rows and stack them top-to-bottom.
    local top_row_y = self.dimen.y + border + padding
    local btn
    for i, info_list in ipairs(self:_orderedRows()) do
        local row_y = top_row_y + (i - 1) * (button_size + row_gap)
        btn = self:_hitRow(x, y, row_y, info_list)
        if btn then break end
    end

    if btn then
        if self.callback then
            self.callback(btn.color_value, btn.color_name, btn.width_value, btn.tool_value)
        end
        if self.close_callback then
            self.close_callback()
        end
        return true
    end

    -- Inside picker but didn't hit a button - still consume the event
    return true
end

-- Handle tap - close if outside the widget
function ColorPickerWidget:onTapCloseOutside(_, ges)
    if ges and ges.pos and self.dimen then
        -- Check if tap is inside the widget using coordinate comparison
        local x, y = ges.pos.x, ges.pos.y
        local inside = x >= self.dimen.x and x < self.dimen.x + self.dimen.w
                and y >= self.dimen.y and y < self.dimen.y + self.dimen.h
        if inside then
            -- Tap is inside, let the color buttons handle it
            return false
        end
    end
    -- Tap is outside, close the widget without changing color
    if self.close_callback then
        self.close_callback()
    end
    return true
end

-- Update button dimens for one row so individual TapSelectColor gesture ranges
-- match the painted positions. Mirrors the centered layout built in init().
function ColorPickerWidget:_placeRow(info_list, paint_x, frame_inner_width, padding, border, row_y)
    if #info_list == 0 then return end
    local button_size = self._button_size
    local spacing = self._spacing
    local total_buttons_width = #info_list * button_size + (#info_list - 1) * spacing
    local row_start_x = paint_x + border + padding + (frame_inner_width - total_buttons_width) / 2
    for i, btn in ipairs(info_list) do
        btn.dimen.x = row_start_x + (i - 1) * (button_size + spacing)
        btn.dimen.y = row_y
    end
end

function ColorPickerWidget:paintTo(bb, x, y)
    -- Use absolute position from dimen if set, otherwise use passed coordinates
    local paint_x = self.dimen and self.dimen.x or x
    local paint_y = self.dimen and self.dimen.y or y

    -- Paint the frame at the absolute position
    self.frame:paintTo(bb, paint_x, paint_y)

    if not self.color_buttons_info then return end

    local button_size = self._button_size
    local row_gap = self._row_gap
    local padding = self._padding
    local border = Size.border.window
    local frame_inner_width = self.dimen.w - 2 * padding - 2 * border

    -- Symmetric with handlePenTap: stack the present rows top-to-bottom,
    -- placing each row's button dimens so their tap ranges match the paint.
    local top_row_y = paint_y + border + padding
    for i, info_list in ipairs(self:_orderedRows()) do
        local row_y = top_row_y + (i - 1) * (button_size + row_gap)
        self:_placeRow(info_list, paint_x, frame_inner_width, padding, border, row_y)
    end
end

function ColorPickerWidget:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.dimen)
end

-- Show color picker popup near the pen position
function Pencil:showColorPicker(x, y)
    if self.color_picker_showing then return end

    -- Discard any current stroke that was made while holding still
    -- The user was holding still to trigger color picker, not intentionally drawing
    if self.current_stroke then
        self.current_stroke = nil
        -- Repaint to remove the stroke from screen immediately
        self.view:paintTo(Screen.bb, 0, 0)
        self:paintTo(Screen.bb, 0, 0)
        Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
    end

    -- The pen that summoned the picker is still physically down, but its lift
    -- event is swallowed while the picker overlay is up (handleStylusSlot
    -- early-returns on isOverlayActive). Clear the logical contact now so a
    -- stuck pen_down/erasing doesn't eat the next stroke once the picker
    -- closes. If a hold-still in eraser mode already deleted something, commit
    -- it to the undo stack first, mirroring the normal eraser-lift path.
    if self.erasing and self.eraser_deleted and #self.eraser_deleted > 0 then
        table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_deleted })
        self.strokes_dirty = true
    end
    self.eraser_deleted = nil
    self.pen_down = false
    self.erasing = false

    self.color_picker_showing = true

    local plugin = self

    -- Which rows to render is driven by the experimental toggles, each
    -- independent. Color and width are pen properties, so they are hidden
    -- in eraser mode; the pen/eraser toggle shows in both modes. The
    -- hold-pen-still gesture only gets here when at least one applicable
    -- flag is on (see checkColorPickerTrigger / the eraser path), so at
    -- least one row is guaranteed non-empty.
    local in_eraser_mode = (self.current_tool == TOOL_ERASER)
    local show_colors = self.experimental_color_picker and not in_eraser_mode
    local show_widths = self.experimental_pen_width and not in_eraser_mode
    local show_tools = self.experimental_tool_toggle
    local colors_for_picker = show_colors and self.available_colors or nil
    local widths_for_picker = show_widths and self.available_widths or nil
    local tools_for_picker = show_tools and {
        { kind = "tool", tool_value = TOOL_PEN },
        { kind = "tool", tool_value = TOOL_ERASER },
    } or nil

    -- Picker stacks up to three rows (colors, widths, tools). Row width is
    -- the widest visible row; height accumulates one button_size per visible
    -- row plus a gap between each adjacent pair.
    local button_size = Screen:scaleBySize(36)
    local spacing = Screen:scaleBySize(8)
    local row_gap = Screen:scaleBySize(8)
    local padding = Screen:scaleBySize(10)
    local border = Size.border.window
    local colors_row_width = show_colors and
        (#self.available_colors * button_size + (#self.available_colors - 1) * spacing) or 0
    local widths_row_width = show_widths and
        (#self.available_widths * button_size + (#self.available_widths - 1) * spacing) or 0
    local n_tools = tools_for_picker and #tools_for_picker or 0
    local tools_row_width = (n_tools > 0) and
        (n_tools * button_size + (n_tools - 1) * spacing) or 0
    local buttons_width = math.max(colors_row_width, widths_row_width, tools_row_width)
    local picker_width = buttons_width + padding * 2 + border * 2
    local rows = (show_colors and 1 or 0) + (show_widths and 1 or 0) + (show_tools and 1 or 0)
    local picker_height = rows * button_size + padding * 2 + border * 2
    if rows > 1 then
        picker_height = picker_height + (rows - 1) * row_gap
    end
    local margin_above = Screen:scaleBySize(30)  -- Gap between picker and pen
    local screen_margin = 10  -- Minimum margin from screen edges

    -- Try to position above the pen first, centered horizontally
    local picker_x = x - picker_width / 2
    local picker_y = y - picker_height - margin_above

    -- Adjust horizontal position to keep picker fully on screen
    if picker_x < screen_margin then
        picker_x = screen_margin
    end
    if picker_x + picker_width > Screen:getWidth() - screen_margin then
        picker_x = Screen:getWidth() - picker_width - screen_margin
    end

    -- If no room above, position below the pen
    if picker_y < screen_margin then
        picker_y = y + margin_above
    end

    -- Final check: ensure it fits on screen vertically
    if picker_y + picker_height > Screen:getHeight() - screen_margin then
        picker_y = Screen:getHeight() - picker_height - screen_margin
    end

    local color_picker = ColorPickerWidget:new{
        colors = colors_for_picker,
        widths = widths_for_picker,
        tools = tools_for_picker,
        current_color_name = self.tool_settings[TOOL_PEN].color_name,
        current_width = self.tool_settings[TOOL_PEN].width,
        current_tool = self.current_tool,
        callback = function(color_value, color_name, width_value, tool_value)
            -- Taps are routed by which value is non-nil: tool toggle, then
            -- width, then color. This avoids the string-match ambiguity the
            -- earlier prototype had.
            if tool_value then
                -- Switch silently first: a badge painted now would be wiped by
                -- the picker's close repaint. Re-paint the top-right corner
                -- indicator just after that repaint settles, so the tool switch
                -- shows the same badge as the double-tap/gesture toggle (no toast).
                plugin:setTool(tool_value, true)
                UIManager:scheduleIn(0.2, function() plugin:showToolBadge() end)
                return
            end

            if width_value then
                plugin:setPenWidth(width_value)
                UIManager:show(InfoMessage:new{
                    text = T(_("Pen width: %1"), width_value),
                    timeout = 1,
                })
                return
            end

            plugin:setPenColor(color_value, color_name)

            -- Display white as the color name if black is picked in night mode
            if Screen.night_mode and color_name == "Black" then
                color_name = "White"
            end

            UIManager:show(InfoMessage:new{
                text = T(_("Pen color: %1"), color_name),
                timeout = 1,
            })
        end,
        close_callback = function()
            plugin.color_picker_showing = false
            UIManager:close(plugin.color_picker_widget)
            plugin.color_picker_widget = nil
            -- Refresh to clean up
            UIManager:setDirty(plugin.view, "ui")
        end,
    }

    -- Position the widget at the calculated coordinates
    -- Set dimen with absolute position before showing
    color_picker.dimen = color_picker.dimen or Geom:new{}
    color_picker.dimen.x = picker_x
    color_picker.dimen.y = picker_y

    self.color_picker_widget = color_picker

    UIManager:show(self.color_picker_widget)
    UIManager:setDirty(self.color_picker_widget, "ui")

    logger.dbg("Pencil: color picker shown at", picker_x, picker_y)
end

-- Set pen color
function Pencil:setPenColor(color, color_name)
    self.tool_settings[TOOL_PEN].color = color
    self.tool_settings[TOOL_PEN].color_name = color_name
    logger.info("Pencil: setPenColor - color_name =", color_name)
    self:saveSettings()
end

-- Set pen width. Only callable while experimental_pen_width is on
-- (the picker is the only UI path that invokes this).
function Pencil:setPenWidth(width)
    self.tool_settings[TOOL_PEN].width = width
    logger.info("Pencil: setPenWidth - width =", width)
    self:saveSettings()
    -- Keep StylusView's per-segment NOCONVERT_DU render in sync.
    if Device:isAndroid() then
        local ok, android = pcall(require, "android")
        if ok and android and android.stylusOverlaySetPenWidth then
            android.stylusOverlaySetPenWidth(width)
        end
    end
    -- Force the Supernote firmware pen size to follow the new width on
    -- the next pen-down. supernote_last_tool=nil bypasses applySupernotePen's
    -- "tool unchanged" short-circuit.
    self.supernote_last_tool = nil
    self:applySupernotePen()
    -- Keep the Onyx SDK stroke width in sync too.
    self:applyOnyxStyle()
end

-- Handle initial touch - fires IMMEDIATELY on first contact
-- This is critical for capturing the start of strokes without delay
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and is a backup if raw input not working
function Pencil:onDrawTouch(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Check if this is a finger touch (not pen) - let gesture system handle it
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    -- Check if raw input hook detected pen - if so, block gesture but don't duplicate
    -- This is the primary pen detection method (lowest latency)
    if self.pen_down then
        -- Raw input is handling drawing - just block the gesture
        self:cancelPendingRefresh()
        return true
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    -- Cancel any pending refresh - user is still writing
    self:cancelPendingRefresh()

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- For eraser, we handle in pan (need movement to erase)
    if effective_tool == TOOL_ERASER then
        return true  -- Block but don't start stroke
    end

    -- Fallback: handle via gesture system if raw input not working
    local page = self:getCurrentPage()

    -- If side button is held for highlighting
    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    -- Start new stroke immediately with first point
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    self.current_stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    -- Draw first point to framebuffer - NO REFRESH during drawing
    -- E-ink displays show "ghost" pixels when framebuffer changes, providing visual feedback
    -- Refresh only happens after user stops writing (delayed refresh)
    local width = tool_settings.width
    local color = tool_settings.color
    local half_w = math.floor(width / 2)
    Screen.bb:paintRectRGB32(ges.pos.x - half_w, ges.pos.y - half_w, width, width, color)

    return true
end

-- Check if this is a stylus/pen event (not finger)
-- Returns: is_pen (boolean), is_eraser_end (boolean), is_highlighter (boolean)
function Pencil:isPenInput(ges)
    if Device:isEmulator() then
        return true, false, false
    end

    local Input = Device.input
    if not Input or not Input.pen_slot then
        return false, false, false
    end

    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    local pen_slot_data = Input:getMtSlot(Input.pen_slot)
    if pen_slot_data and pen_slot_data.id and pen_slot_data.id ~= -1 then
        if pen_slot_data.tool == TOOL_TYPE_PEN then
            return true, false, false
        elseif pen_slot_data.tool == TOOL_TYPE_ERASER then
            return true, true, false
        elseif pen_slot_data.tool == TOOL_TYPE_HIGHLIGHTER then
            return true, false, true
        end
    end

    return false, false, false
end

-- Get the effective tool (considers physical eraser end and side button)
function Pencil:getEffectiveTool(is_eraser_end, is_highlighter)
    -- Check both the tool type detection AND the BTN_TOOL_RUBBER state
    if self.eraser_tool_active or ((self.swap_eraser_and_highlighter and is_highlighter) or (not self.swap_eraser_and_highlighter and is_eraser_end)) then
        return TOOL_ERASER
    end

    -- Side button held = highlighter mode (for hold+drag highlighting)
    if self.side_button_down or ((self.swap_eraser_and_highlighter and is_eraser_end) or (not self.swap_eraser_and_highlighter and is_highlighter)) then
        return TOOL_HIGHLIGHTER
    end

    return self.current_tool
end

-- Called on tap - create a dot or erase at point
function Pencil:onDrawTap(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Block all taps while stylus is actively drawing
    if self.pen_down or self.current_stroke then
        return true
    end

    -- Rotation badge hit-test: consume taps (pen or finger) over the camera
    -- badge of a stale-rotation annotation and open its saved image.
    if ges and ges.pos then
        local hit = self:findGroupBadgeAtPoint(ges.pos.x, ges.pos.y)
        if hit then
            logger.info("Pencil: badge tap hit group", hit.id,
                "at (", ges.pos.x, ",", ges.pos.y, ")")
            self:showGroupImagePreview(hit)
            return true
        end
    end

    -- Check if finger tap - let gesture system handle it
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)
    logger.dbg("Pencil: onDrawTap - effective_tool =", effective_tool)

    -- Log to debug file for analysis
    self:writeDebugLog(string.format("=== TAP at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    if effective_tool == TOOL_ERASER then
        -- Eraser: delete strokes near tap point
        logger.info("Pencil: eraser tap at", ges.pos.x, ges.pos.y, "page =", page)
        local erased = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if erased then
            logger.info("Pencil: erased", #erased, "strokes")
            table.insert(self.undo_stack, { type = "delete", strokes = erased })
            self:saveStrokes()
            UIManager:setDirty(self.view, "ui")
        else
            logger.info("Pencil: eraser tap found no strokes to erase")
        end
        return true
    end

    -- Pen or Highlighter: create a dot
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    local stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, page)
    self:saveStrokes()

    -- Add to undo stack
    table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })

    -- Draw directly to screen buffer
    self:renderStroke(Screen.bb, stroke)

    -- Direct framebuffer refresh for instant feedback
    local w = stroke.width
    Screen:refreshFast(ges.pos.x - w, ges.pos.y - w, w * 2, w * 2)

    return true
end

-- Called during pan - continues stroke started by onDrawTouch
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and handles eraser mode
function Pencil:onDrawPan(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Check if raw input hook detected pen - if so, block gesture
    -- Raw input handles all drawing; this just needs to block swipe/pan gestures
    if self.pen_down then
        return true  -- Block pan gesture, raw input is drawing
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- If side button is held and we're drawing, mark it as used for highlighting
    if self.side_button_down and effective_tool == TOOL_HIGHLIGHTER then
        self.side_button_used_for_highlight = true
    end

    -- Eraser mode: erase along path (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if not self.eraser_deleted then
            self.eraser_deleted = {}
        end

        local deleted = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if deleted then
            for _, stroke in ipairs(deleted) do
                table.insert(self.eraser_deleted, stroke)
            end
            self.view:paintTo(Screen.bb, 0, 0)
            Screen:refreshUI()
        end
        return true
    end

    -- Fallback: handle via gesture system if raw input not working
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]

    -- Stroke should already exist from onDrawTouch, but handle fallback cases
    if not self.current_stroke or self.current_stroke.page ~= page or self.current_stroke.tool ~= effective_tool then
        -- Fallback: create stroke if touch event was missed or context changed
        logger.dbg("Pencil: onDrawPan creating fallback stroke")
        self.current_stroke = {
            page = page,
            tool = effective_tool,
            points = {},
            width = tool_settings.width,
            color = tool_settings.color,
            color_name = tool_settings.color_name,
            alpha = tool_settings.alpha,
            datetime = os.time(),
        }
        -- Use start_pos if available for the first point
        if ges.start_pos then
            table.insert(self.current_stroke.points, { x = ges.start_pos.x, y = ges.start_pos.y })
        end
    end

    -- Add current point to stroke
    local point = { x = ges.pos.x, y = ges.pos.y }
    table.insert(self.current_stroke.points, point)

    -- Draw the new segment to framebuffer - NO REFRESH during drawing
    -- E-ink shows ghost pixels, refresh happens on pan_release
    local n = #self.current_stroke.points
    local width = self.current_stroke.width
    local color = self.current_stroke.color

    if n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]

        if effective_tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        else
            self:drawLineSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
    elseif n == 1 then
        local p = self.current_stroke.points[1]
        local half_w = math.floor(width / 2)
        Screen.bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
    end

    return true
end

-- Called when pan ends - finalize stroke
-- NOTE: For pen/highlighter, raw input hook may have already finalized the stroke
function Pencil:onDrawPanRelease(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Let finger releases be handled by gesture system
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- Log pan end to debug file
    self:writeDebugLog(string.format("=== PAN END at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    -- Handle eraser pan release (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if self.eraser_deleted and #self.eraser_deleted > 0 then
            -- Add deleted strokes to undo stack
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_deleted })
            self:saveStrokes()
        end
        -- Always refresh screen after erasing to clear any visual artifacts
        UIManager:setDirty(self.view, "partial")
        self.eraser_deleted = nil
        return true
    end

    -- For pen/highlighter: raw input hook already finalized the stroke
    -- Just consume the event and ensure delayed refresh is scheduled
    if not self.current_stroke then
        -- Raw input already handled it, just schedule refresh if not already pending
        self:scheduleDelayedRefresh()
        return true
    end

    -- Fallback: finalize stroke via gesture system
    if #self.current_stroke.points >= 1 then
        -- Finalize the stroke
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self:saveStrokes()

        -- Add to undo stack
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)

        logger.dbg("Pencil: stroke completed with", #self.current_stroke.points, "points")
    end

    self.current_stroke = nil

    -- Schedule delayed refresh - will fire after user stops writing
    -- If user starts another stroke, the refresh will be canceled and rescheduled
    self:scheduleDelayedRefresh()

    return true
end

-- Get current page number (stable reference for both paged and rolling modes)
function Pencil:getCurrentPage()
    if self.ui.paging then
        return self.view.state.page
    else
        -- For rolling/EPUB documents, convert XPointer to stable page number
        local xp = self.ui.document:getXPointer()
        if xp and self.ui.document.getPageFromXPointer then
            return self.ui.document:getPageFromXPointer(xp)
        end
        -- Fallback to XPointer if conversion not available
        return xp
    end
end

-- Index a stroke by page for quick lookup
function Pencil:indexStroke(stroke_idx, page)
    if not self.page_strokes[page] then
        self.page_strokes[page] = {}
    end
    table.insert(self.page_strokes[page], stroke_idx)
end

-- Get an XPointer for a screen-space position on the current rolling-mode
-- page. Used to remember WHERE an annotation lives (so it can be re-resolved
-- to a post-rotation page) rather than just the top of the page it was
-- drawn on. Returns nil for paging docs or when the API is unavailable.
function Pencil:getXPointerAtBboxCenter(bbox)
    if not bbox then return nil end
    if not self.ui.rolling then return nil end
    if not self.ui.document or not self.ui.document.getTextFromPositions then
        return nil
    end
    local cx = math.floor((bbox.x0 + bbox.x1) / 2)
    local cy = math.floor((bbox.y0 + bbox.y1) / 2)
    local ok, range = pcall(self.ui.document.getTextFromPositions,
        self.ui.document, { x = cx, y = cy }, { x = cx, y = cy }, true)
    if ok and range and range.pos0 then
        return range.pos0
    end
    -- Fallback: nearest-line xpointer via the current scroll top.
    if self.ui.document.getXPointer then
        local ok2, xp = pcall(self.ui.document.getXPointer, self.ui.document)
        if ok2 and xp then return xp end
    end
    return nil
end

-- Resolve a group's page number in the current layout. For paging docs (PDF)
-- the saved group.page is stable. For rolling docs (EPUB) page numbers shift
-- with rotation / font / spacing changes, so re-derive from the saved
-- XPointer if we have one. Falls back to the original page number when no
-- XPointer was stored (older groups created before this code shipped).
function Pencil:getGroupCurrentPage(group)
    if not group then return nil end
    if self.ui.rolling and group.xpointer
            and self.ui.document and self.ui.document.getPageFromXPointer then
        local ok, pn = pcall(self.ui.document.getPageFromXPointer,
            self.ui.document, group.xpointer)
        if ok and pn then return pn end
    end
    return group.page
end

-- Lazily store / upgrade an XPointer for rolling-doc groups on the current
-- page. Two paths:
--   1. Legacy group with no xpointer: drop in the page-top xpointer so at
--      least same-rotation matching keeps working.
--   2. Group whose xpointer was stored at page-top (old buggy code) or for
--      any reason isn't marked precise: when we're on the same page AND in
--      the rotation the annotation was captured at, the bbox coords are
--      valid on the current screen, so we can resolve a precise per-bbox
--      xpointer. Mark xpointer_v2 to avoid repeated work.
function Pencil:backfillGroupXPointers()
    if not self.ui.rolling then return end
    if not self.ui.document or not self.ui.document.getXPointer
            or not self.ui.document.getPageFromXPointer then
        return
    end
    local cur_page = self:getCurrentPage()
    local cur_rot = Screen:getRotationMode()
    local cur_xp_top = nil
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.page == cur_page then
            local upgraded = false
            if not group.xpointer_v2 and group.bbox
                    and (group.image_rotation == nil
                            or group.image_rotation == cur_rot) then
                local precise = self:getXPointerAtBboxCenter(group.bbox)
                if precise then
                    group.xpointer = precise
                    group.xpointer_v2 = true
                    self.image_data_dirty = true
                    upgraded = true
                end
            end
            if not upgraded and not group.xpointer then
                cur_xp_top = cur_xp_top or self.ui.document:getXPointer()
                if cur_xp_top then
                    group.xpointer = cur_xp_top
                    self.image_data_dirty = true
                end
            end
        end
    end
end

-- Assign a newly-added stroke to an annotation group (or create a new one).
-- Called after a stroke is finalized and inserted into self.strokes.
-- @param stroke_idx number  index of the stroke in self.strokes
-- @param skip_bookmark boolean  if true, skip bookmark sync (used during bootstrap)
function Pencil:assignStrokeToGroup(stroke_idx, skip_bookmark)
    local stroke = self.strokes[stroke_idx]
    if not stroke then return end

    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end

    local stroke_time = stroke.datetime or 0
    local best_group = nil

    for _, group in ipairs(self.annotation_groups) do
        if group.page == stroke.page then
            local time_diff = math.abs(stroke_time - (group.datetime_last or group.datetime or 0))
            if time_diff <= GROUP_TIME_THRESHOLD_S then
                local dist = PencilGeometry.bboxDistance(bbox, group.bbox)
                if dist <= GROUP_SPATIAL_THRESHOLD then
                    best_group = group
                    break
                end
            end
        end
    end

    if best_group then
        -- Merge into existing group
        table.insert(best_group.stroke_indices, stroke_idx)
        best_group.bbox = PencilGeometry.bboxUnion(best_group.bbox, bbox)
        best_group.datetime_last = math.max(best_group.datetime_last or 0, stroke_time)
        -- Update tool to majority
        local pen_count, hl_count = 0, 0
        for _, si in ipairs(best_group.stroke_indices) do
            local s = self.strokes[si]
            if s then
                if s.tool == TOOL_HIGHLIGHTER then hl_count = hl_count + 1
                else pen_count = pen_count + 1 end
            end
        end
        best_group.tool = hl_count > pen_count and TOOL_HIGHLIGHTER or TOOL_PEN
        if not skip_bookmark then
            self:markGroupDirty(best_group)
            -- A merged stroke invalidates the previously captured image (bbox
            -- grew); re-schedule the deferred capture.
            self:removeGroupImage(best_group)
            self:scheduleGroupImageCapture(best_group)
        end
    else
        -- Create new group
        local group = {
            id = "pencil_" .. os.date("%Y%m%d%H%M%S") .. "_" .. stroke_idx,
            page = stroke.page,
            stroke_indices = { stroke_idx },
            bbox = bbox,
            datetime = stroke_time,
            datetime_last = stroke_time,
            tool = (stroke.tool == TOOL_HIGHLIGHTER) and TOOL_HIGHLIGHTER or TOOL_PEN,
        }
        -- For rolling/EPUB docs, capture an XPointer AT THE ANNOTATION'S
        -- POSITION (bbox center) so we can re-resolve which page the
        -- annotation falls on after rotation / font change. CRITICAL: only
        -- valid when we're actually viewing the page this stroke was drawn
        -- on, because getTextFromPositions reads from the currently
        -- rendered page. During a full rebuild (after erase / undo) we
        -- process strokes from every page; for off-current-page strokes
        -- we skip the xpointer and let getGroupCurrentPage fall back to
        -- the saved group.page number. Backfill upgrades them later.
        if stroke.page == self:getCurrentPage() then
            local annot_xp = self:getXPointerAtBboxCenter(bbox)
            if annot_xp then
                group.xpointer = annot_xp
                group.xpointer_v2 = true
            end
        end
        table.insert(self.annotation_groups, group)
        if not skip_bookmark then
            self:markGroupDirty(group)
            self:scheduleGroupImageCapture(group)
        end
    end
end

-- Mark a group as needing a bookmark sync on the next deferred-work flush.
-- Keeps the heavy getPageXPointer / annotation insertion off the writing path.
function Pencil:markGroupDirty(group)
    if not self.experimental_bookmark_sync then return end
    self.dirty_groups = self.dirty_groups or {}
    self.dirty_groups[group.id] = group
end

-- Rebuild all annotation groups from scratch by re-running the grouping algorithm
-- on all existing strokes sorted by datetime. Called after erase/undo operations.
function Pencil:rebuildAnnotationGroups()
    local ok, err = pcall(function()
        -- Remove all existing bookmarks for pencil groups, and cancel any
        -- pending image captures (group ids will change).
        for _, group in ipairs(self.annotation_groups) do
            self:removeGroupBookmark(group)
            self:cancelGroupImageCapture(group.id)
        end

        self.annotation_groups = {}

        -- Build list of {index, datetime} sorted by datetime
        local sorted = {}
        for i, stroke in ipairs(self.strokes) do
            table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
        end
        table.sort(sorted, function(a, b) return a.dt < b.dt end)

        -- Re-assign each stroke
        for _, entry in ipairs(sorted) do
            self:assignStrokeToGroup(entry.idx)
        end
    end)
    if not ok then
        logger.warn("Pencil: rebuildAnnotationGroups failed:", err)
        self.annotation_groups = self.annotation_groups or {}
    end
    -- Any JPEGs whose stem no longer matches a current group.id are now stale.
    self:purgeOrphanImages()
end

-- Get page number for bookmark display (always numeric).
function Pencil:getPageNumber(page_ref)
    if type(page_ref) == "number" then
        return page_ref
    end
    -- For XPointer (rolling docs), try to convert
    if self.ui.document and self.ui.document.getPageFromXPointer then
        local pn = self.ui.document:getPageFromXPointer(page_ref)
        if pn then return pn end
    end
    return 0
end

-- Get the bookmark page reference for a group.
-- For paging mode (PDF), this is the page number.
-- For rolling mode (EPUB), this must be an XPointer.
function Pencil:getBookmarkPageRef(group_page)
    if self.ui.rolling and self.ui.document and self.ui.document.getPageXPointer then
        -- group.page is a number (from getCurrentPage), convert back to XPointer
        return self.ui.document:getPageXPointer(group_page)
    end
    return group_page
end

-- Sync a group's bookmark into KOReader's annotation system.
function Pencil:syncGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then
        logger.dbg("Pencil: annotation module not available, skipping bookmark sync")
        return
    end
    if not self.ui.annotation.annotations then
        logger.dbg("Pencil: annotations not loaded yet, skipping bookmark sync")
        return
    end

    local ok, err = pcall(function()
        -- Remove existing bookmark for this group first
        self:removeGroupBookmark(group)

        local pageno = self:getPageNumber(group.page)
        local bookmark_page = self:getBookmarkPageRef(group.page)
        local chapter = ""
        if self.ui.toc and self.ui.toc.getTocTitleByPage then
            chapter = self.ui.toc:getTocTitleByPage(bookmark_page) or ""
        end

        local datetime = group.id  -- use group id as unique datetime key
        group.bookmark_datetime = datetime

        local item = {
            page = bookmark_page,
            datetime = datetime,
            text = string.format("Pencil annotation on page %d", pageno),
            chapter = chapter,
        }

        if self.ui.annotation.addItem then
            self.ui.annotation:addItem(item)
            logger.dbg("Pencil: synced bookmark for group", group.id, "on page", pageno)
        else
            logger.warn("Pencil: annotation.addItem not available")
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark sync failed:", err)
    end
end

-- Remove a group's bookmark from KOReader's annotation system.
function Pencil:removeGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then return end
    if not group.bookmark_datetime then return end

    local ok, err = pcall(function()
        local annotations = self.ui.annotation.annotations
        if not annotations then return end

        for i, ann in ipairs(annotations) do
            if ann.datetime == group.bookmark_datetime then
                table.remove(annotations, i)
                logger.dbg("Pencil: removed bookmark for group", group.id)
                return
            end
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark removal failed:", err)
    end
end

-- Remove ALL pencil bookmarks from KOReader's annotation system.
-- Used before re-syncing to avoid duplicates.
-- Note: always runs regardless of feature flag, so disabling cleans up.
function Pencil:removeAllPencilBookmarks()
    if not self.ui or not self.ui.annotation then return end
    local annotations = self.ui.annotation.annotations
    if not annotations then return end

    -- Remove in reverse order to maintain indices
    for i = #annotations, 1, -1 do
        if annotations[i].datetime and annotations[i].datetime:match("^pencil_") then
            table.remove(annotations, i)
        end
    end
end

-- Sync all annotation groups to bookmarks (used after load/rebuild).
function Pencil:syncAllBookmarks()
    if not self.experimental_bookmark_sync then return end

    -- Clean slate: remove all pencil bookmarks first to avoid duplicates
    self:removeAllPencilBookmarks()

    for _, group in ipairs(self.annotation_groups) do
        self:syncGroupBookmark(group)
    end
    logger.info("Pencil: synced", #self.annotation_groups, "annotation group bookmarks")
end

------------------------------------------------------------------------------
-- Annotation image capture & preview (issue #51)
------------------------------------------------------------------------------

-- Directory holding per-group preview JPEGs for this document.
function Pencil:getImagesDir()
    if not self.ui or not self.ui.doc_settings then return nil end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if not sidecar_dir then return nil end
    return sidecar_dir .. "/pencil_images"
end

function Pencil:ensureImagesDir()
    local dir = self:getImagesDir()
    if not dir then return nil end
    local ok, err = lfs.mkdir(dir)
    if not ok and err ~= "File exists" then
        logger.warn("Pencil: failed to create images dir:", err)
        return nil
    end
    return dir
end

function Pencil:getGroupImagePath(group)
    local dir = self:getImagesDir()
    if not dir or not group or not group.image_path then return nil end
    return dir .. "/" .. group.image_path
end

-- Render the captured-page-context image for a group into a Blitbuffer and
-- write it as a JPEG. Returns true on success.
function Pencil:captureGroupImage(group)
    if not group or not group.bbox then return false end
    if not self.view or not self.view.paintTo then return false end

    local dir = self:ensureImagesDir()
    if not dir then return false end

    -- Only capture if the group's page matches the current pagination;
    -- otherwise ReaderView would render the wrong content. For rolling docs
    -- this uses the group's XPointer (rotation-stable) when available.
    local gpage = self:getGroupCurrentPage(group)
    if gpage ~= self:getCurrentPage() then
        logger.dbg("Pencil: captureGroupImage: page mismatch (group=", tostring(gpage),
            " current=", tostring(self:getCurrentPage()), "), deferring")
        return false
    end

    -- Capture a full-screen-width strip vertically bounded by the bbox + a
    -- small margin. This gives the user enough context (full line of text)
    -- when they preview the annotation from the bookmark list or rotation
    -- badge, instead of a tight crop that just shows the strokes.
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local rect = PencilGeometry.captureStripRect(
        group.bbox, sw, sh, IMAGE_CAPTURE_V_MARGIN_PX, IMAGE_MIN_HEIGHT_PX)
    local w = math.floor(rect.x1 - rect.x0)
    local h = math.floor(rect.y1 - rect.y0)
    if w < 8 or h < 8 then return false end

    -- Allocate offscreen buffer of the same type as Screen.bb so paintTo writes
    -- pixels in the format ReaderView expects.
    local bb_type = Screen.bb:getType()
    local ok_bb, off_bb = pcall(Blitbuffer.new, w, h, bb_type)
    if not ok_bb or not off_bb then
        logger.warn("Pencil: failed to allocate offscreen buffer for capture")
        return false
    end

    -- Paint the page (and other plugins / highlights / dogear etc.) into the
    -- offscreen buffer. The (-x, -y) offset places the captured page region
    -- at (0, 0) inside off_bb; Blitbuffer paints clip to buffer bounds.
    local x0, y0 = math.floor(rect.x0), math.floor(rect.y0)
    self._capturing = true
    local ok_paint, paint_err = pcall(self.view.paintTo, self.view, off_bb, -x0, -y0)
    self._capturing = false
    if not ok_paint then
        logger.warn("Pencil: ReaderView paint to offscreen failed:", paint_err)
        if off_bb.free then off_bb:free() end
        return false
    end

    -- Render this group's strokes over the painted page background.
    for _, idx in ipairs(group.stroke_indices or {}) do
        local stroke = self.strokes[idx]
        if stroke then
            self:renderStrokeOffset(off_bb, stroke, -x0, -y0)
        end
    end

    -- Downscale if longer side exceeds IMAGE_MAX_DIM (storage / encode budget).
    local final_bb = off_bb
    local longer = math.max(w, h)
    if longer > IMAGE_MAX_DIM and off_bb.scale then
        local scale = IMAGE_MAX_DIM / longer
        local sw_new = math.max(1, math.floor(w * scale))
        local sh_new = math.max(1, math.floor(h * scale))
        local ok_scale, scaled = pcall(off_bb.scale, off_bb, sw_new, sh_new)
        if ok_scale and scaled then
            final_bb = scaled
        end
    end

    -- Encode + write.
    local filename = group.id .. ".jpg"
    local fullpath = dir .. "/" .. filename
    local ok_write, write_err = pcall(final_bb.writeJPG, final_bb, fullpath, IMAGE_JPEG_QUALITY)

    -- Free buffers we own (final_bb might be the same object as off_bb after
    -- skipping the downscale path).
    if final_bb ~= off_bb and final_bb.free then final_bb:free() end
    if off_bb.free then off_bb:free() end

    if not ok_write then
        logger.warn("Pencil: failed to write JPEG:", write_err)
        return false
    end

    group.image_path = filename
    group.image_rotation = Screen:getRotationMode()
    self.image_data_dirty = true
    logger.info("Pencil: captured image for group", group.id, "rotation", group.image_rotation, "->", fullpath)
    return true
end

-- Variant of renderStroke that translates points by (dx, dy) before drawing.
-- Used during capture to render a group's strokes onto an offscreen buffer
-- whose origin corresponds to the bbox top-left.
function Pencil:renderStrokeOffset(bb, stroke, dx, dy)
    if not stroke or not stroke.points or #stroke.points < 1 then return end

    local tool = stroke.tool or TOOL_PEN
    local width = stroke.width or self.tool_settings[tool].width or 3
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    if Screen.night_mode and stroke.color_name ~= "Black" and stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    local is_highlighter = (tool == TOOL_HIGHLIGHTER)
    if is_highlighter then
        color = stroke.color or Blitbuffer.Color8(0xDD)
    end

    if #stroke.points == 1 then
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(p.x + dx - half_w, p.y + dy - half_w, width, width, color)
    else
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            if is_highlighter then
                self:drawHighlighterSegment(bb, p1.x + dx, p1.y + dy, p2.x + dx, p2.y + dy, width, color)
            else
                self:drawLineSegment(bb, p1.x + dx, p1.y + dy, p2.x + dx, p2.y + dy, width, color)
            end
        end
    end
end

-- Schedule a deferred capture for the group. If a capture is already pending
-- for this group id, cancel and re-arm so we only capture once after the
-- grouping window has settled.
-- delay (optional): seconds before firing. Defaults to IMAGE_CAPTURE_DEBOUNCE_S
-- so we wait past the GROUP_TIME_THRESHOLD_S merge window before capturing a
-- fresh stroke. Backfill uses a shorter delay since no merges are pending.
function Pencil:scheduleGroupImageCapture(group, delay)
    if not group or not group.id then return end
    self.pending_image_captures = self.pending_image_captures or {}

    self:cancelGroupImageCapture(group.id)

    local cb = function()
        self.pending_image_captures[group.id] = nil
        -- The group might have been deleted by the eraser by now.
        local current = nil
        for _, g in ipairs(self.annotation_groups) do
            if g.id == group.id then current = g; break end
        end
        if not current then return end
        local ok, err = pcall(self.captureGroupImage, self, current)
        if not ok then
            logger.warn("Pencil: captureGroupImage error:", err)
        end
        if self.image_data_dirty then
            self.image_data_dirty = false
            self:saveStrokes()
        end
    end

    self.pending_image_captures[group.id] = cb
    local d = delay or IMAGE_CAPTURE_DEBOUNCE_S
    UIManager:scheduleIn(d, cb)
    logger.dbg("Pencil: scheduled image capture for group", group.id, "in", d, "seconds")
end

function Pencil:cancelGroupImageCapture(group_id)
    if not self.pending_image_captures then return end
    local cb = self.pending_image_captures[group_id]
    if cb then
        UIManager:unschedule(cb)
        self.pending_image_captures[group_id] = nil
    end
end

-- Run all pending captures synchronously and clear the queue. Called on
-- document close / suspend so we don't lose freshly drawn annotations.
function Pencil:flushPendingCaptures()
    if not self.pending_image_captures then return end
    local pending = self.pending_image_captures
    self.pending_image_captures = {}
    for _, cb in pairs(pending) do
        UIManager:unschedule(cb)
        local ok, err = pcall(cb)
        if not ok then
            logger.warn("Pencil: flushPendingCaptures error:", err)
        end
    end
end

function Pencil:removeGroupImage(group)
    local path = self:getGroupImagePath(group)
    if not path then return end
    os.remove(path)
    group.image_path = nil
    group.image_rotation = nil
end

-- Delete any JPEG in pencil_images/ whose stem isn't a current group.id.
-- Called after group rebuilds (which regenerate ids) and during saveStrokes.
function Pencil:purgeOrphanImages()
    local dir = self:getImagesDir()
    if not dir then return end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return end

    local valid = {}
    for _, g in ipairs(self.annotation_groups or {}) do
        if g.image_path then
            valid[g.image_path] = true
        end
    end

    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." and file:match("%.jpg$") and not valid[file] then
            os.remove(dir .. "/" .. file)
            logger.dbg("Pencil: purged orphan image", file)
        end
    end
end

-- Open the saved image for a group in an ImageViewer popup.
function Pencil:showGroupImagePreview(group)
    if not group then return end
    local path = self:getGroupImagePath(group)
    if not path then
        UIManager:show(InfoMessage:new{
            text = _("No saved image for this annotation yet."),
            timeout = 2,
        })
        return
    end
    local attr = lfs.attributes(path)
    if not attr then
        UIManager:show(InfoMessage:new{
            text = _("Annotation image is missing on disk."),
            timeout = 2,
        })
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    local pageno = self:getPageNumber(group.page) or 0
    UIManager:show(ImageViewer:new{
        file = path,
        with_title_bar = true,
        title_text = T(_("Annotation - page %1"), pageno),
        fullscreen = false,
    })
end

-- Compute the on-screen badge rect for a stale-rotation group. The badge is
-- pinned to the right edge of the screen (i.e. in the margin) at a vertical
-- position proportional to the original bbox center Y, so multiple stale
-- annotations stack along the right side in roughly their original reading
-- order.
function Pencil:getGroupBadgeRect(group)
    if not group or not group.bbox or not group.image_rotation then return nil end
    local current_rot = Screen:getRotationMode()
    if current_rot == group.image_rotation then return nil end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    -- Source-rotation screen height: rotations 0/2 vs 1/3 swap width/height.
    local src_sh = sh
    if (group.image_rotation == 1 or group.image_rotation == 3) ~=
            (current_rot == 1 or current_rot == 3) then
        src_sh = sw
    end

    -- Vertical: proportional remap of the bbox center onto current screen.
    local cy = (group.bbox.y0 + group.bbox.y1) / 2
    local y_fraction = src_sh > 0 and (cy / src_sh) or 0.5
    local target_y = math.floor(y_fraction * sh)

    -- Horizontal: fixed position in the right margin. Simple and reliable;
    -- avoids depending on the document's reported page margins which can
    -- behave unexpectedly across EPUB engines.
    local badge_x = sw - IMAGE_BADGE_SIZE - IMAGE_BADGE_MARGIN_GAP

    local half = math.floor(IMAGE_BADGE_SIZE / 2)
    local x = math.max(0, math.min(sw - IMAGE_BADGE_SIZE, badge_x))
    local y = math.max(0, math.min(sh - IMAGE_BADGE_SIZE, target_y - half))
    return { x = x, y = y, w = IMAGE_BADGE_SIZE, h = IMAGE_BADGE_SIZE }
end

-- Pick a representative color for an annotation group: the first stroke's
-- saved color. Returns nil if no usable color is found, so the caller can
-- fall back to a default.
function Pencil:getGroupColor(group)
    if not group or not group.stroke_indices then return nil end
    for _, idx in ipairs(group.stroke_indices) do
        local stroke = self.strokes[idx]
        if stroke and stroke.color then
            return stroke.color
        end
    end
    return nil
end

function Pencil:renderRotationBadge(bb, group)
    local rect = self:getGroupBadgeRect(group)
    if not rect then return end
    -- Fill matches the annotation color so users can tell badges apart when
    -- a page has annotations in different colors. Black border for
    -- definition, white inner mark to suggest interactivity (and to keep
    -- light colors like gray / highlighter yellow visible).
    -- Must use paintRectRGB32 (not paintRect) to preserve the color channels
    -- of ColorRGB32 fills; paintRect treats the value as a luminance and
    -- would render colored fills as gray.
    local fill = self:getGroupColor(group)
            or Blitbuffer.ColorRGB32(0xCC, 0x00, 0x00, 0xFF)
    bb:paintRectRGB32(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_BLACK)
    bb:paintRectRGB32(rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4, fill)
    local inset = math.floor(rect.w / 3)
    bb:paintRectRGB32(rect.x + inset, rect.y + inset,
        rect.w - 2 * inset, rect.h - 2 * inset, Blitbuffer.COLOR_WHITE)
end

-- Compute the list of stale-rotation groups whose badges should be drawn on
-- the current page in the current rotation. Returns nil if no badges should
-- show (no stale groups, or suppressed because a native annotation is also
-- on this page). Shared by paintTo and findGroupBadgeAtPoint to keep
-- drawing and hit-testing in lockstep.
function Pencil:getStaleGroupsForCurrentView()
    local current_rot = Screen:getRotationMode()
    local page = self:getCurrentPage()
    local stale = nil
    local has_native = false
    for _, group in ipairs(self.annotation_groups or {}) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            if group.image_rotation == nil
                    or group.image_rotation == current_rot then
                has_native = true
            elseif group.image_path then
                stale = stale or {}
                stale[#stale + 1] = group
            end
        end
    end
    if has_native then return nil end
    return stale
end

-- Hit-test the rotation badges on the current page. Mirrors the drawing
-- logic in paintTo: a badge is tappable iff its group would have its badge
-- drawn by the current render pass.
function Pencil:findGroupBadgeAtPoint(x, y)
    local stale = self:getStaleGroupsForCurrentView()
    if not stale then return nil end
    for _, group in ipairs(stale) do
        local rect = self:getGroupBadgeRect(group)
        if rect
                and x >= rect.x - IMAGE_BADGE_HIT_PAD
                and x <= rect.x + rect.w + IMAGE_BADGE_HIT_PAD
                and y >= rect.y - IMAGE_BADGE_HIT_PAD
                and y <= rect.y + rect.h + IMAGE_BADGE_HIT_PAD then
            return group
        end
    end
    return nil
end

-- Called by the bookmark-list hook on menu select. Returns true if we
-- handled the tap (and the original navigation should be skipped).
function Pencil:tryShowImageForBookmark(item)
    if not item or not item.datetime then return false end
    if not item.datetime:match("^pencil_") then return false end
    -- Find the matching group by id (group.id is stored as the bookmark datetime).
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.id == item.datetime then
            if group.image_path then
                self:showGroupImagePreview(group)
                return true
            end
            return false  -- pencil bookmark but no image yet; fall through to navigate
        end
    end
    return false
end

-- Total disk usage of pencil_images/ for the current document, in bytes.
function Pencil:getImagesSizeBytes()
    local dir = self:getImagesDir()
    if not dir then return 0 end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return 0 end
    local total = 0
    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." then
            local fattr = lfs.attributes(dir .. "/" .. file)
            if fattr and fattr.size then total = total + fattr.size end
        end
    end
    return total
end

-- Remove all preview images for the current book and clear group references.
function Pencil:purgeAllImages()
    local dir = self:getImagesDir()
    if dir then
        local attr = lfs.attributes(dir)
        if attr and attr.mode == "directory" then
            for file in lfs.dir(dir) do
                if file ~= "." and file ~= ".." then
                    os.remove(dir .. "/" .. file)
                end
            end
        end
    end
    for _, group in ipairs(self.annotation_groups or {}) do
        group.image_path = nil
        group.image_rotation = nil
    end
    self:saveStrokes()
    UIManager:setDirty(self.view, "ui")
end

-- Re-capture missing images for groups on the currently visible page.
-- Called from onReaderReady and onPageUpdate so the user sees rotation
-- badges work without needing to redraw the annotation. Uses a short delay
-- so the page has fully rendered before we ask ReaderView to repaint into
-- our offscreen, but no merge-window wait since the group is already final.
function Pencil:backfillMissingImages()
    local page = self:getCurrentPage()
    for _, group in ipairs(self.annotation_groups or {}) do
        if self:getGroupCurrentPage(group) == page and not group.image_path then
            self:scheduleGroupImageCapture(group, 1.0)
        end
    end
end

-- Install a one-time class-level patch on ReaderBookmark so that
-- long-pressing a pencil bookmark that has a saved image opens a
-- full-screen ImageViewer popup directly, instead of the standard
-- bookmark detail dialog. Closing the ImageViewer returns to the
-- bookmark list with nothing else stacked behind it.
--
-- Falls through to the standard dialog for non-pencil bookmarks and for
-- pencil bookmarks without a saved image. Short-tap still navigates to
-- the bookmark (default behavior, untouched).
function Pencil:installBookmarkHook()
    if _bookmark_hook_installed then return end

    local ok, ReaderBookmark = pcall(require, "apps/reader/modules/readerbookmark")
    if not ok or not ReaderBookmark or not ReaderBookmark.showBookmarkDetails then
        logger.warn("Pencil: ReaderBookmark module not available, skipping hook")
        return
    end

    local original_showBookmarkDetails = ReaderBookmark.showBookmarkDetails
    function ReaderBookmark:showBookmarkDetails(item_or_index)
        local item = type(item_or_index) == "table"
            and item_or_index
            or (self.ui.annotation and self.ui.annotation.annotations
                    and self.ui.annotation.annotations[item_or_index])
        if item and item.datetime and item.datetime:match("^pencil_")
                and _active_pencil and _active_pencil.annotation_groups then
            for _, group in ipairs(_active_pencil.annotation_groups) do
                if group.id == item.datetime and group.image_path then
                    local path = _active_pencil:getGroupImagePath(group)
                    if path and lfs.attributes(path) then
                        _active_pencil:showGroupImagePreview(group)
                        return true  -- suppress standard dialog
                    end
                    break
                end
            end
        end
        return original_showBookmarkDetails(self, item_or_index)
    end

    _bookmark_hook_installed = true
    logger.info("Pencil: installed bookmark list hook")
end

-- Rebuild page index from strokes
function Pencil:rebuildPageIndex()
    self.page_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        self:indexStroke(i, stroke.page)
    end
end

-- Get strokes for a specific page
function Pencil:getStrokesForPage(page)
    local result = {}
    local indices = self.page_strokes[page] or {}
    for _, idx in ipairs(indices) do
        if self.strokes[idx] then
            table.insert(result, self.strokes[idx])
        end
    end
    return result
end

-- Check if current page has strokes
function Pencil:hasStrokesOnCurrentPage()
    local page = self:getCurrentPage()
    return self.page_strokes[page] and #self.page_strokes[page] > 0
end

-- Clear strokes on current page
function Pencil:clearPageStrokes()
    local page = self:getCurrentPage()
    local indices_to_remove = self.page_strokes[page]

    if not indices_to_remove or #indices_to_remove == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations found on this page."),
            timeout = 1,
        })
        return
    end

    -- Copy and sort in reverse order to maintain indices during removal
    local sorted_indices = {}
    for _, idx in ipairs(indices_to_remove) do
        table.insert(sorted_indices, idx)
    end
    table.sort(sorted_indices, function(a, b) return a > b end)

    local deleted_strokes = {}
    for _, idx in ipairs(sorted_indices) do
        if self.strokes[idx] then
            table.insert(deleted_strokes, self.strokes[idx])
            table.remove(self.strokes, idx)
        end
    end

    if #deleted_strokes > 0 then
        table.insert(self.undo_stack, { type = "delete", strokes = deleted_strokes })
    end

    self:rebuildPageIndex()
    self:rebuildAnnotationGroups()
    self:saveStrokes()

    UIManager:show(InfoMessage:new{
        text = T(_("Cleared %1 annotation(s) from page."), #deleted_strokes),
        timeout = 1,
    })
    UIManager:setDirty(self.view, "ui")
end

-- Clear all strokes
function Pencil:clearAllStrokes()
    -- Remove all bookmarks for annotation groups + delete their images.
    for _, group in ipairs(self.annotation_groups) do
        self:removeGroupBookmark(group)
        self:cancelGroupImageCapture(group.id)
        self:removeGroupImage(group)
    end
    self.strokes = {}
    self.page_strokes = {}
    self.annotation_groups = {}
    self:saveStrokes()
    -- Belt-and-suspenders: any leftover files get reaped.
    self:purgeOrphanImages()

    UIManager:setDirty(self.view, "ui")
end

-- Render a line segment using rectangles (since BlitBuffer has no native line drawing)
function Pencil:drawLineSegment(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)

    if dist < 1 then
        -- Just draw a single point
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(x1 - half_w, y1 - half_w, width, width, color)
        return
    end

    -- Step along the line drawing small rectangles
    local steps = math.ceil(dist)
    local half_w = math.floor(width / 2)

    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, color)
    end
end

-- Render a highlighter segment (semi-transparent, wider)
function Pencil:drawHighlighterSegment(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)

    -- Highlighter is drawn as a lighter gray to simulate transparency on e-ink
    local highlight_color = color or Blitbuffer.Color8(0xDD)

    if dist < 1 then
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(x1 - half_w, y1 - half_w, width, width, highlight_color)
        return
    end

    local steps = math.ceil(dist)
    local half_w = math.floor(width / 2)

    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, highlight_color)
    end
end

-- Check if a point is near a stroke (for eraser)
function Pencil:isPointNearStroke(px, py, stroke, threshold)
    return PencilGeometry.isPointNearStroke(px, py, stroke, threshold)
end

-- Erase strokes at a given point
-- Returns array of deleted strokes (for undo), or nil if none
function Pencil:eraseAtPoint(x, y, page)
    -- Only erase strokes on the current page
    if self.input_debug_mode then
        self:writeDebugLog(string.format("ERASE: searching %d strokes at (%d, %d)",
            #self.strokes, x, y))
    end

    if #self.strokes == 0 then
        if self.input_debug_mode then
            self:writeDebugLog("ERASE: no strokes exist")
        end
        return nil
    end

    local eraser_width = self.tool_settings[TOOL_ERASER].width
    local deleted = {}
    local indices_to_remove = {}

    -- Iterate only strokes on the current page via the page index. Keeps the
    -- per-sample erase cost O(strokes-on-page) instead of O(total-strokes).
    local page_indices = self.page_strokes and self.page_strokes[page] or nil
    if page_indices then
        for _, i in ipairs(page_indices) do
            local stroke = self.strokes[i]
            if stroke then
                if self.input_debug_mode and stroke.points and #stroke.points > 0 then
                    local min_x, max_x, min_y, max_y = stroke.points[1].x, stroke.points[1].x, stroke.points[1].y, stroke.points[1].y
                    for _, pt in ipairs(stroke.points) do
                        if pt.x < min_x then min_x = pt.x end
                        if pt.x > max_x then max_x = pt.x end
                        if pt.y < min_y then min_y = pt.y end
                        if pt.y > max_y then max_y = pt.y end
                    end
                    self:writeDebugLog(string.format("ERASE: stroke %d bounds: (%d-%d, %d-%d), eraser at (%d,%d) threshold=%d",
                        i, min_x, max_x, min_y, max_y, x, y, eraser_width))
                end
                if self:isPointNearStroke(x, y, stroke, eraser_width) then
                    table.insert(deleted, stroke)
                    table.insert(indices_to_remove, i)
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASE: found stroke %d to delete", i))
                    end
                end
            end
        end
    end

    -- Remove strokes (in reverse order to maintain indices)
    if #indices_to_remove > 0 then
        table.sort(indices_to_remove, function(a, b) return a > b end)
        for _, idx in ipairs(indices_to_remove) do
            table.remove(self.strokes, idx)
        end
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("ERASE: deleted %d strokes", #deleted))
        end
        return deleted
    end

    return nil
end

-- Render a complete stroke
function Pencil:renderStroke(bb, stroke)
    if not stroke.points or #stroke.points < 1 then
        return
    end

    local tool = stroke.tool or TOOL_PEN
    local width = stroke.width or self.tool_settings[tool].width or 3

    -- Get color directly (it's already a Blitbuffer color)
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and stroke.color_name ~= "Black" and stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    -- Highlighter uses lighter color
    local is_highlighter = (tool == TOOL_HIGHLIGHTER)
    if is_highlighter then
        -- For highlighter, use stored color or default gray
        color = stroke.color or Blitbuffer.Color8(0xDD)
    end

    if #stroke.points == 1 then
        -- Single point (dot)
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
    else
        -- Multiple points - draw line segments
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            if is_highlighter then
                self:drawHighlighterSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
            else
                self:drawLineSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
            end
        end
    end
end

-- View module paintTo method - called by ReaderView during repaints.
-- When the captureGroupImage routine asks ReaderView to repaint into our
-- offscreen buffer, this method is invoked recursively as part of the view
-- module loop; the _capturing guard suppresses re-entry so we can paint the
-- group's strokes deliberately onto the captured page background.
function Pencil:paintTo(bb, x, y)
    if self._capturing then return end

    local page = self:getCurrentPage()
    local current_rot = Screen:getRotationMode()

    -- Backfill XPointers for legacy groups before we filter, so the
    -- rotation-aware page resolution below sees them.
    self:backfillGroupXPointers()

    -- Identify groups whose captured-image rotation no longer matches the
    -- current screen rotation. Their strokes will draw in the wrong place,
    -- so we skip them and draw a badge instead. For EPUB we match by the
    -- group's XPointer re-resolved to the current pagination, since the
    -- saved group.page would be stale across rotations.
    --
    -- Suppression: if any group on this page renders natively at the
    -- current rotation (i.e. matches current_rot, or pre-dates the feature
    -- entirely), we hide badges for OTHER stale groups on the same page so
    -- the view isn't cluttered with badges next to a visible annotation.
    -- Re-rotate to see the suppressed annotation.
    local stale_indices = nil
    local stale_groups = nil
    local groups_on_page = 0
    local groups_with_image = 0
    local has_native_annotation = false
    for _, group in ipairs(self.annotation_groups) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            groups_on_page = groups_on_page + 1
            if group.image_path then
                groups_with_image = groups_with_image + 1
            end
            if group.image_rotation == nil
                    or group.image_rotation == current_rot then
                -- Renders natively (same rotation as capture, or legacy group
                -- without rotation info — render strokes as-is).
                has_native_annotation = true
            elseif group.image_path then
                stale_groups = stale_groups or {}
                stale_groups[#stale_groups + 1] = group
                stale_indices = stale_indices or {}
                for _, idx in ipairs(group.stroke_indices or {}) do
                    stale_indices[idx] = true
                end
            end
        end
    end
    if has_native_annotation then
        -- Drop badges entirely; native-rotation strokes will render below.
        stale_groups = nil
        stale_indices = nil
    end
    local stale_count = stale_groups and #stale_groups or 0
    if not self._last_paint_log
            or self._last_paint_log.page ~= page
            or self._last_paint_log.rot ~= current_rot
            or self._last_paint_log.on_page ~= groups_on_page
            or self._last_paint_log.with_image ~= groups_with_image
            or self._last_paint_log.stale ~= stale_count
            or self._last_paint_log.native ~= has_native_annotation then
        logger.info("Pencil: paintTo page=", page, " rot=", current_rot,
            " groups_on_page=", groups_on_page,
            " with_image=", groups_with_image,
            " native=", tostring(has_native_annotation),
            " badges=", stale_count)
        self._last_paint_log = {
            page = page,
            rot = current_rot,
            on_page = groups_on_page,
            with_image = groups_with_image,
            stale = stale_count,
            native = has_native_annotation,
        }
    end

    -- Render saved strokes for current page (skipping stale ones).
    local indices = self.page_strokes[page] or {}
    for _, idx in ipairs(indices) do
        if not (stale_indices and stale_indices[idx]) then
            local stroke = self.strokes[idx]
            if stroke then
                self:renderStroke(bb, stroke)
            end
        end
    end

    -- Draw rotation-mismatch badges over the spots where the strokes would
    -- have appeared. Tapping a badge opens the saved image.
    if stale_groups then
        for _, group in ipairs(stale_groups) do
            self:renderRotationBadge(bb, group)
        end
    end

    -- Render current stroke being drawn (only if on current page)
    if self.current_stroke and self.current_stroke.page == page then
        self:renderStroke(bb, self.current_stroke)
    end
end

-- Get the pencil strokes file path for this document
function Pencil:getStrokesFilePath()
    if not self.ui or not self.ui.doc_settings then
        logger.warn("Pencil: doc_settings not available")
        return nil
    end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/pencil_strokes.lua"
    end
    logger.warn("Pencil: sidecar_dir not available")
    return nil
end

-- Load strokes from our own file
function Pencil:loadStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: loadStrokes - filepath =", filepath)

    if not filepath then
        logger.warn("Pencil: no filepath available for loading strokes")
        self.strokes = {}
        self.page_strokes = {}
        return
    end

    -- Check if file exists
    local file_exists = io.open(filepath, "r")
    if not file_exists then
        logger.info("Pencil: strokes file does not exist yet:", filepath)
        self.strokes = {}
        self.page_strokes = {}
        self.strokes_loaded = true
        return
    end
    file_exists:close()

    local ok, data = pcall(dofile, filepath)
    if ok and data and data.strokes then
        -- Convert saved strokes back to usable format
        self.strokes = {}
        for i, saved in ipairs(data.strokes) do
            self.strokes[i] = self:strokeFromSaved(saved)
        end
        self:rebuildPageIndex()

        -- Load annotation groups or bootstrap from v1 data
        if data.annotation_groups and #data.annotation_groups > 0 then
            self.annotation_groups = data.annotation_groups
            logger.info("Pencil: loaded", #self.annotation_groups, "annotation groups")
        else
            -- v1 data or no groups — bootstrap by running grouping on all strokes
            -- skip_bookmark=true because annotation module isn't ready yet during load
            logger.info("Pencil: bootstrapping annotation groups from strokes")
            self.annotation_groups = {}
            local sorted = {}
            for i, stroke in ipairs(self.strokes) do
                table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
            end
            table.sort(sorted, function(a, b) return a.dt < b.dt end)
            for _, entry in ipairs(sorted) do
                self:assignStrokeToGroup(entry.idx, true)
            end
        end

        self.strokes_loaded = true
        logger.info("Pencil: loaded", #self.strokes, "strokes from", filepath)
    else
        logger.warn("Pencil: failed to load strokes from", filepath, "error:", data)
        self.strokes = {}
        self.page_strokes = {}
        self.annotation_groups = {}
    end
end

-- Convert stroke for saving (remove non-serializable values)
function Pencil:strokeToSaveable(stroke)
    return {
        page = stroke.page,
        tool = stroke.tool,
        width = stroke.width,
        alpha = stroke.alpha,
        datetime = stroke.datetime,
        points = stroke.points,
        color_name = stroke.color_name,  -- Save color name for persistence
    }
end

-- Convert saved stroke back to usable format
function Pencil:strokeFromSaved(saved)
    local tool = saved.tool or TOOL_PEN
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    -- Look up color from color_name
    local color = tool_settings.color
    if saved.color_name then
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == saved.color_name then
                color = color_info.color
                break
            end
        end
    end

    return {
        page = saved.page,
        tool = saved.tool,
        width = saved.width or tool_settings.width,
        color = color,
        color_name = saved.color_name,
        alpha = saved.alpha or tool_settings.alpha,
        datetime = saved.datetime,
        points = saved.points,
    }
end

-- Save strokes to our own file
function Pencil:saveStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: saveStrokes - filepath =", filepath, "strokes count =", #self.strokes)

    if not filepath then
        logger.warn("Pencil: no filepath available for saving strokes")
        return
    end

    -- Safety: don't save empty data if strokes were never successfully loaded
    -- (prevents data loss if a crash causes save before load completes)
    if #self.strokes == 0 and not self.strokes_loaded then
        logger.warn("Pencil: refusing to save empty strokes (strokes never loaded)")
        return
    end

    -- Ensure the directory exists
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        local ok, err = lfs.mkdir(sidecar_dir)
        if not ok and err ~= "File exists" then
            logger.warn("Pencil: failed to create sidecar dir:", err)
        end
    end

    -- Convert strokes to saveable format (remove non-serializable values)
    local saveable_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        saveable_strokes[i] = self:strokeToSaveable(stroke)
    end

    -- Serialize and write. Version 3 marks files that may contain image_path /
    -- image_rotation fields on annotation groups; older readers can ignore
    -- those fields and continue to use the strokes directly.
    local data = {
        version = 3,
        strokes = saveable_strokes,
        annotation_groups = self.annotation_groups,
    }

    local f, err = io.open(filepath, "w")
    if f then
        f:write("return " .. require("dump")(data))
        f:close()
        self.strokes_dirty = false
        logger.info("Pencil: saved", #self.strokes, "strokes to", filepath)
    else
        logger.err("Pencil: failed to open file for writing:", filepath, "error:", err)
    end
end

-- Handle document close
function Pencil:onCloseDocument()
    logger.info("Pencil: onCloseDocument called, strokes count =", #self.strokes)

    -- Cancel any pending refresh
    self:cancelPendingRefresh()
    -- Drop any scheduled debounced save - we save unconditionally below.
    self:cancelPendingSave()
    self.dirty_groups = nil

    -- Save any in-progress stroke
    if self.current_stroke and #self.current_stroke.points >= 2 then
        logger.info("Pencil: saving in-progress stroke before close")
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self.current_stroke = nil
    end

    self:teardownPenInput()

    -- Run any pending deferred image captures synchronously before close so
    -- we don't lose a fresh annotation. Must happen before the final save so
    -- new image_path / image_rotation fields land in the strokes file.
    self:flushPendingCaptures()

    -- Final bookmark sync before close
    self:syncAllBookmarks()

    -- Always save strokes on close (even if empty, to clear any previous data)
    logger.info("Pencil: saving strokes on document close")
    self:saveStrokes()

    -- Clear state
    self.eraser_deleted = nil
    self.undo_stack = {}

    if _active_pencil == self then _active_pencil = nil end
end

function Pencil:onSuspend()
    -- Same idea as onCloseDocument: don't lose a freshly drawn annotation
    -- across a device sleep.
    self:flushPendingCaptures()
    -- Supernote: release firmware ink ownership so a foregrounded app
    -- (e.g. the launcher) doesn't keep painting under finger taps using
    -- our last-set pen config. We re-claim in onResume.
    if self.supernote_ink_active then
        SupernoteInk.clearAll()
        SupernoteInk.enableFullUiAuto(false)
    end
end

function Pencil:onResume()
    -- Supernote: re-claim firmware ink ownership and re-push the current
    -- pen config. Skip if pencil never set itself up (e.g. plugin disabled
    -- or non-Supernote device — SupernoteInk.isAvailable() returns false).
    if not self.supernote_ink_active then return end
    SupernoteInk.sendWriteAppInfo()
    SupernoteInk.enableFullUiAuto(true)
    SupernoteInk.clearDisableAreas()
    -- Force applySupernotePen() to re-push setPen even though current_tool
    -- looks unchanged — the firmware lost our state during pause.
    self.supernote_last_tool = nil
    self:applySupernotePen()
end

-- Handle reader ready (document fully loaded)
function Pencil:onReaderReady()
    logger.info("Pencil: onReaderReady called")
    logger.info("Pencil: doc_settings available:", self.ui.doc_settings ~= nil)
    if self.ui.doc_settings then
        logger.info("Pencil: sidecar_dir:", self.ui.doc_settings.doc_sidecar_dir)
    end

    -- Force reload strokes (in case they weren't loaded in init)
    if #self.strokes == 0 then
        self:loadStrokes()
    end
    logger.info("Pencil: after loadStrokes, strokes count =", #self.strokes,
        "groups =", #self.annotation_groups)

    -- Sync annotation group bookmarks now that UI modules are ready
    self:syncAllBookmarks()

    -- Re-setup touch zones if enabled
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end

    -- Lazy backfill: any group on the currently visible page that's missing
    -- an image (e.g. created in an older version, or capture was lost mid-
    -- session) gets re-captured now that ReaderView can paint the page.
    self:backfillMissingImages()
end

-- Handle read settings (document opened) - backup in case onReaderReady not called
function Pencil:onReadSettings(config)
    logger.dbg("Pencil: onReadSettings called")
    -- Only load if not already loaded
    if not self.strokes or #self.strokes == 0 then
        self:loadStrokes()
    end
    -- Re-setup touch zones if enabled (in case they were torn down)
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end
end

-- Handle page changes (paging mode)
function Pencil:onPageUpdate(pageno)
    -- Huawei: wipe the firmware ink overlay so this page's strokes don't bleed
    -- onto the next page (in case the user turns before the delayed clear fires).
    -- KOReader's own render of the new page already includes its saved strokes.
    if self.huawei_ahw_active then
        local ok, android = pcall(require, "android")
        if ok and android and android.huaweiAhwClear then
            android.huaweiAhwClear()
        end
    end
    -- Clear any in-progress stroke when page changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        -- Save the stroke before clearing. The inline saveStrokes below covers
        -- everything in self.strokes, so drop any queued debounced save first.
        self:cancelPendingSave()
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        -- No in-progress stroke, but a debounced save may still be queued from
        -- earlier strokes on this page. Persist it before navigating away.
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    -- Re-schedule capture for any group on the newly visible page that's
    -- still missing an image (e.g. user turned past the original page before
    -- the debounce fired).
    self:backfillMissingImages()
end

-- Handle position changes (rolling/scroll mode)
function Pencil:onUpdatePos()
    -- Clear any in-progress stroke when position changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        self:cancelPendingSave()
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    self:backfillMissingImages()
end

return Pencil
