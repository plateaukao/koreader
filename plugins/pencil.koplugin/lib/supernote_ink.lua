--[[
SupernoteInk — Lua/JNI binder client for the Supernote firmware's stylus
ink daemon. Self-contained inside pencil.koplugin: no launcher patches
required, so this plugin can be dropped onto a stock KOReader Android
install (official APK) and the Supernote-specific path lights up at
runtime via the binder lookup.

Mechanism: the firmware registers a Binder service "service_myservice"
(legacy alias "service.myservice") with interface token
"android.demo.IMyService". App code claims pen ownership with tx=0,
configures disable areas with tx=1, sets pen/eraser with tx=2, and
clears the EPDC ink overlay with tx=6. The firmware paints stroke
pixels to the EPDC overlay at sub-frame latency — KOReader just
configures it and clears the buffer once the finished stroke is baked
into Screen.bb.

This module is a no-op on:
  - non-Android targets (the `android` require fails)
  - Android devices without the Supernote firmware binder (the
    ServiceManager.getService lookup returns null)

so it is safe to load unconditionally from main.lua.

Reference: see the Kotlin original at
  https://github.com/plateaukao/supernote_draw/blob/main/app/src/main/java/com/example/supernotedraw/SupernoteInk.kt
which decompiled the Supernote Document app's HandWriteClient. The pen
type codes (10 Needle / 16 Ink / 11 Mark / 15 Calligraphy) and the EMR
size ranges are from that reverse engineering.
--]]

local ok_android, android = pcall(require, "android")
if not ok_android or not android or not android.app then
    -- Non-Android target (emulator / Linux). Return a no-op stub.
    return setmetatable({}, { __index = function() return function() end end })
end

local ffi = require("ffi")
local logger = require("logger")
local C = ffi.C

local JNI = android.jni  -- the JNI helper exposed by luajit-launcher/assets/android.lua

local SupernoteInk = {}

local IFACE_TOKEN = "android.demo.IMyService"
local APP_NAME = "koreader-pencil"
local SERVICE_NAMES = { "service_myservice", "service.myservice" }

-- Firmware transaction codes (from the decompiled HandWriteClient).
local TX_WRITE_APP_INFO = 0
local TX_DISABLE_AREA   = 1
local TX_PEN            = 2
local TX_DRAW_BUFFER    = 6

-- Pen codes for the firmware's penTypeArray on Nomad (deviceType=3 / A5X2).
SupernoteInk.Pen = {
    NEEDLE      = 10,
    INK         = 16,
    MARK        = 11,  -- highlighter
    CALLIGRAPHY = 15,
}

SupernoteInk.Color = {
    BLACK      = 0,
    DARK_GRAY  = -101,
    GRAY       = -102,
    LIGHT_GRAY = 254,
}

-- The cached binder is a JNI global ref so it survives across JNI:context
-- entries. We grab it once, on first availability check.
local binder_gref = nil
-- Tri-state: nil = untested, false = absent, true = present.
local available = nil

-- Helpers that must run inside a JNI:context block (i.e., self.env valid).

local function newStringUTF(jni, s)
    return jni.env[0].NewStringUTF(jni.env, s)
end

local function deleteLocalRef(jni, obj)
    if obj ~= nil then
        jni.env[0].DeleteLocalRef(jni.env, obj)
    end
end

local function newGlobalRef(jni, obj)
    return jni.env[0].NewGlobalRef(jni.env, obj)
end

local function isBinderAlive(jni)
    if binder_gref == nil then return false end
    -- IBinder.isBinderAlive() — when the firmware service restarts, our
    -- cached proxy becomes dead and transact() throws DeadObjectException.
    return jni:callBooleanMethod(binder_gref, "isBinderAlive", "()Z")
end

local function lookupBinder(jni)
    for _, name in ipairs(SERVICE_NAMES) do
        local jname = newStringUTF(jni, name)
        local b = jni:callStaticObjectMethod(
            "android/os/ServiceManager", "getService",
            "(Ljava/lang/String;)Landroid/os/IBinder;",
            jname)
        deleteLocalRef(jni, jname)
        if b ~= nil then
            logger.info("SupernoteInk: found binder for \"" .. name .. "\"")
            local gref = newGlobalRef(jni, b)
            deleteLocalRef(jni, b)
            return gref
        end
    end
    return nil
end

function SupernoteInk.isAvailable()
    if available ~= nil then return available end
    JNI:context(android.app.activity.vm, function(jni)
        binder_gref = lookupBinder(jni)
        available = (binder_gref ~= nil)
    end)
    if not available then
        logger.info("SupernoteInk: service_myservice not present, will no-op")
    end
    return available
end

-- Run a transaction; `write_args` is a function(jni, data) that writes
-- the per-call payload after the interface token + app name preamble.
local function transact(code, write_args)
    if not SupernoteInk.isAvailable() then return end
    JNI:context(android.app.activity.vm, function(jni)
        if not isBinderAlive(jni) then
            -- Try to re-lookup; firmware may have restarted.
            binder_gref = lookupBinder(jni)
            if binder_gref == nil then
                available = false
                logger.warn("SupernoteInk: binder gone, marking unavailable")
                return
            end
        end
        local data = jni:callStaticObjectMethod(
            "android/os/Parcel", "obtain", "()Landroid/os/Parcel;")
        local reply = jni:callStaticObjectMethod(
            "android/os/Parcel", "obtain", "()Landroid/os/Parcel;")

        local jtoken = newStringUTF(jni, IFACE_TOKEN)
        jni:callVoidMethod(data, "writeInterfaceToken",
            "(Ljava/lang/String;)V", jtoken)
        deleteLocalRef(jni, jtoken)

        local japp = newStringUTF(jni, APP_NAME)
        jni:callVoidMethod(data, "writeString",
            "(Ljava/lang/String;)V", japp)
        deleteLocalRef(jni, japp)

        write_args(jni, data)

        -- BinderProxy.transact(code, data, reply, flags)
        jni:callBooleanMethod(binder_gref, "transact",
            "(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z",
            ffi.new("int32_t", code), data, reply, ffi.new("int32_t", 0))

        -- Clear any pending JNI exception (e.g. DeadObjectException) before
        -- returning, otherwise the next JNI call asserts.
        if jni.env[0].ExceptionCheck(jni.env) == C.JNI_TRUE then
            jni.env[0].ExceptionDescribe(jni.env)
            jni.env[0].ExceptionClear(jni.env)
        end

        jni:callVoidMethod(data, "recycle", "()V")
        jni:callVoidMethod(reply, "recycle", "()V")
        deleteLocalRef(jni, data)
        deleteLocalRef(jni, reply)
    end)
end

local function writeInt(jni, parcel, n)
    jni:callVoidMethod(parcel, "writeInt", "(I)V", ffi.new("int32_t", n))
end

function SupernoteInk.sendWriteAppInfo(mode, value)
    transact(TX_WRITE_APP_INFO, function(jni, data)
        writeInt(jni, data, mode or 0)
        writeInt(jni, data, value or 0)
    end)
end

function SupernoteInk.setPen(pen_type, size_emr, color)
    transact(TX_PEN, function(jni, data)
        writeInt(jni, data, pen_type)
        writeInt(jni, data, size_emr)
        writeInt(jni, data, color)
    end)
end

function SupernoteInk.setEraser(rectangular, size_emr)
    transact(TX_PEN, function(jni, data)
        writeInt(jni, data, rectangular and 3 or 1)
        writeInt(jni, data, size_emr)
        writeInt(jni, data, 255)
    end)
end

function SupernoteInk.clearAll()
    transact(TX_DRAW_BUFFER, function(jni, data)
        writeInt(jni, data, 255)
        writeInt(jni, data, 0)
    end)
end

function SupernoteInk.setFullScreenDisable(width, height)
    transact(TX_DISABLE_AREA, function(jni, data)
        writeInt(jni, data, 1)              -- rect count
        writeInt(jni, data, 0)              -- x
        writeInt(jni, data, 0)              -- y
        writeInt(jni, data, width)
        writeInt(jni, data, height)
        writeInt(jni, data, 0)              -- reserved / flags
    end)
end

function SupernoteInk.clearDisableAreas()
    transact(TX_DISABLE_AREA, function(jni, data)
        writeInt(jni, data, 0)              -- zero rects
    end)
end

-- Reflection on Activity.getSystemService("eink").enableFullUiAuto(boolean).
-- Required so the firmware will paint ink everywhere on screen, not just
-- inside its whitelisted apps.
function SupernoteInk.enableFullUiAuto(enable)
    if not SupernoteInk.isAvailable() then return end
    JNI:context(android.app.activity.vm, function(jni)
        local activity = android.app.activity.clazz
        local jsname = newStringUTF(jni, "eink")
        local eink = jni:callObjectMethod(activity, "getSystemService",
            "(Ljava/lang/String;)Ljava/lang/Object;", jsname)
        deleteLocalRef(jni, jsname)
        if eink == nil then
            logger.dbg("SupernoteInk: eink system service not present")
            return
        end
        jni:callVoidMethod(eink, "enableFullUiAuto", "(Z)V",
            ffi.new("int32_t", enable and 1 or 0))
        if jni.env[0].ExceptionCheck(jni.env) == C.JNI_TRUE then
            -- Some firmwares' eink service doesn't expose the method.
            jni.env[0].ExceptionClear(jni.env)
        end
        deleteLocalRef(jni, eink)
    end)
end

return SupernoteInk
