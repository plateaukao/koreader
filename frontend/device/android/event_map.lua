return {
    [29] = "A", [30] = "B", [31] = "C", [32] = "D", [33] = "E", [34] = "F",
    [35] = "G", [36] = "H", [37] = "I", [38] = "J", [39] = "K", [40] = "L",
    [41] = "M", [42] = "N", [43] = "O", [44] = "P", [45] = "Q", [46] = "R",
    [47] = "S", [48] = "T", [49] = "U", [50] = "V", [51] = "W", [52] = "X",
    [53] = "Y", [54] = "Z", [ 7] = "0", [ 8] = "1", [ 9] = "2", [10] = "3",
    [11] = "4", [12] = "5", [13] = "6", [14] = "7", [15] = "8", [16] = "9",

    [4] = "Back",   -- BACK
    [19] = "Up",    -- DPAD_UP
    [20] = "Down",  -- DPAD_UP
    [21] = "Left",  -- DPAD_LEFT
    [22] = "Right", -- DPAD_RIGHT
    [23] = "Press", -- DPAD_CENTER
    [24] = "LPgBack", -- VOLUME_UP
    [25] = "LPgFwd",  -- VOLUME_DOWN
    [27] = "Camera",  -- CAMERA
    [56] = ".",     -- PERIOD
    [59] = "Shift", -- SHIFT_LEFT
    [60] = "Shift", -- SHIFT_RIGHT
    [62] = " ",     -- SPACE
    [63] = "Sym",   -- SYM
    [66] = "Press", -- ENTER
    [67] = "Del",   -- DEL
    [76] = "/",     -- SLASH
    [82] = "Menu",  -- MENU
    [84] = "Search",--SEARCH
    [92] = "LPgBack", -- PAGE_UP
    [93] = "LPgFwd",  -- PAGE_DOWN
    -- Supernote right sidebar page-turn (310/301) intentionally disabled:
    -- the filtering logic that turns long-press / slide into well-behaved
    -- page turns lives in launcher-side code that hasn't been pushed yet,
    -- so without it the sidebar fires runaway page turns on contact.
    -- Re-add [310] = "LPgFwd" and [301] = "LPgBack" once that lands.
    [300] = "SidebarDoubleFinger", -- Supernote left sidebar double-finger release
}
