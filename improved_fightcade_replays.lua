--[[
================================================================================
 improved_fightcade_replays.lua
 Replay controller with real rewind for Fightcade 2 (FightcadeFBNeo)
 Target game: Street Fighter III: 3rd Strike (sfiii3nr1 / sfiii3n / sfiii3)
 Lua 5.1 (the interpreter bundled with FightcadeFBNeo)
 Version 1.0.0

 Copyright (C) 2026 fightcade-replay-controller contributors

 This program is free software: you can redistribute it and/or modify it
 under the terms of the GNU General Public License as published by the Free
 Software Foundation, either version 3 of the License, or (at your option)
 any later version.

 This program is distributed in the hope that it will be useful, but WITHOUT
 ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 more details.

 You should have received a copy of the GNU General Public License along
 with this program. If not, see <https://www.gnu.org/licenses/>.

================================================================================

DISCLAIMER: This project was written with the help of an AI model, Claude Opus 5.5 by Anthropic.

================================================================================

 HOW TO RUN
   1. Put this file in   <Fightcade>\emulator\fbneo\   (next to fcadefbneo.exe).
      Any folder works; that one is simply the default of the file browser.
   2. Start a 3rd Strike replay from the Fightcade lobby.
   3. As soon as the replay picture appears: Game > Lua Scripting... >
      New Lua Script Window... (or Alt+L), Browse..., pick this file, Run.
      Rewind history starts at the moment the script is started.

 CONTROLS (keyboard, read with input.get)
   R (hold)        Rewind.  Shift+R = fast rewind.  Release = resume from there
   SPACE           Pause / resume
   LEFT / RIGHT    Step one frame back / forward (pauses first; hold to repeat)
   1 2 3 4 5 6 7   Speed 0.25x 0.5x 1x 1.25x 1.5x 2x 4x
   N               Back to normal speed (1x)
   H               Hide / show overlay
   Alt+1           Detach from the replay stream (see "STREAM END" below)

 HOW IT WORKS (verified against the fightcade-fbneo source, June 2025)
   * A Fightcade replay is a GGPO spectator session: every emulated frame pulls
     the next input from a forward-only stream (NetworkGetInput), then calls
     the Lua "before" hook, then applies joypad.set() overrides, then emulates.
   * The script records every stream input by STREAM INDEX (stream frame k is
     the input of game frame k), and keeps in-memory snapshots
     (savestate.save_mem / load_mem, a Fightcade-only API) every few frames.
   * To rewind it restores a snapshot and, from then on, overrides the inputs
     with the recorded ones for the frame actually being emulated. The stream
     keeps flowing and is recorded ahead, so you can rewind, resume and keep
     watching to the end of the match with inputs and state in sync.
   * Every emulated frame is fingerprinted from 3rd Strike RAM (game frame
     counter + both player structs). When a frame is emulated again after a
     rewind, the fingerprint is compared; the overlay shows SYNC OK or DESYNC.
   * Pause and slow motion re-emulate the same frame from a snapshot (the
     emulator's own pause also stops Lua, so it cannot be used).
   * Speeds above 1x use the only native speed control (emu.speedmode
     "turbo", ~11 frames per refresh) gated by a wall-clock budget, so the
     average speed is exact.

 STREAM END
   While you are behind live (after rewinding or pausing) the replay stream is
   consumed ahead of what you see and recorded. When Fightcade reaches the end
   of the replay data, emulation stops and Lua cannot run. Press Alt+1 then:
   the script takes over (emu.takeover) and you can keep watching, rewinding
   and stepping through everything that was recorded.

 KNOWN LIMITATIONS
   * You can only rewind to the moment the script started (start it early).
   * Snapshots skip the palette and the 8 MB CPS3 character RAM (that is what
     save_mem does; it is the rollback-style state). Gameplay is restored
     exactly, but a few frames after a long rewind may show stale colours or
     sprite tiles until the game redraws them. BACKEND = "file" avoids this at
     the cost of a visible hitch each time a snapshot is written.
   * Fightcade keeps at most 4096 in-memory snapshots (hard-coded). Older ones
     are recycled automatically; the overlay shows how far back you can go.
   * Audio repeats a short fragment while paused / in slow motion.
   * Keys are read globally (GetAsyncKeyState): typing in another window while
     the replay runs also triggers the controls.
================================================================================
]]

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------
local CONFIG = {
  BACKEND = "mem",              -- "mem" (fast, in memory) or "file" (full state, slower)
  CHECKPOINT_INTERVAL = 10,     -- frames between snapshots, BACKEND = "mem"
  FILE_CHECKPOINT_INTERVAL = 60,-- frames between snapshots, BACKEND = "file"
  FILE_MAX_CHECKPOINTS = 240,   -- ring size (files in %TEMP%), BACKEND = "file"
  REWIND_SPEED = 3,             -- rewind speed, multiple of real time
  REWIND_SPEED_FAST = 10,       -- with Shift held
  GAME_FPS = 59.59949,          -- CPS3 refresh rate
  TURBO_BURST = 10,             -- frames of deficit before a turbo burst (>1x)
  STEP_REPEAT_DELAY = 0.35,     -- seconds before LEFT/RIGHT auto-repeat
  STEP_REPEAT_RATE = 0.07,      -- seconds between repeats
  VERIFY_SYNC = true,           -- fingerprint frames and check after rewinds
  OVERLAY = true,
  OVERLAY_X = 4,
  OVERLAY_Y = 34,               -- below the life bars
}

local SPEEDS = { 0.25, 0.5, 1, 1.25, 1.5, 2, 4 }
local SPEED_NORMAL = 3
local SPEED_KEYS = { ["1"] = 1, ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6, ["7"] = 7 }

--------------------------------------------------------------------------------
-- ENVIRONMENT CHECK (every function used below exists in fightcade-fbneo)
--------------------------------------------------------------------------------
local function hasFn(lib, name) return type(lib) == "table" and type(lib[name]) == "function" end

do
  local required = {
    { emu, "emu", "frameadvance" }, { emu, "emu", "registerbefore" },
    { emu, "emu", "registerexit" }, { emu, "emu", "speedmode" },
    { joypad, "joypad", "get" }, { joypad, "joypad", "set" },
    { input, "input", "get" }, { gui, "gui", "register" }, { gui, "gui", "text" },
    { savestate, "savestate", "create" }, { savestate, "savestate", "save" },
    { savestate, "savestate", "load" },
  }
  local missing = {}
  for _, r in ipairs(required) do
    if not hasFn(r[1], r[3]) then missing[#missing + 1] = r[2] .. "." .. r[3] end
  end
  if #missing > 0 then
    error("fightcade_replay_controller: this emulator lacks " .. table.concat(missing, ", "))
  end
end

local HAS_MEM = hasFn(savestate, "save_mem") and hasFn(savestate, "load_mem")
local BACKEND = CONFIG.BACKEND
if BACKEND == "mem" and not HAS_MEM then
  BACKEND = "file"
  print("savestate.save_mem not available (not FightcadeFBNeo?) - using file snapshots.")
end
local INTERVAL = (BACKEND == "mem") and CONFIG.CHECKPOINT_INTERVAL or CONFIG.FILE_CHECKPOINT_INTERVAL

-- emu.isreplay() in fightcade-fbneo returns kNetSpectator as a result COUNT:
-- something non-nil during a replay, nothing otherwise (same use as the
-- official fbneo-training-mode script: REPLAY = emu.isreplay()).
local function detectReplay()
  if not hasFn(emu, "isreplay") then return false end
  local ok, r = pcall(emu.isreplay)
  return ok and r ~= nil and r ~= false and r ~= 0
end

local romname = hasFn(emu, "romname") and emu.romname() or ""
local IS_3S = string.find(romname, "^sfiii3") ~= nil

local clock = os.clock   -- wall-clock milliseconds on Windows (MSVC clock())
local floor = math.floor
local FPS = CONFIG.GAME_FPS

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local streaming = detectReplay()  -- inputs come from the Fightcade replay stream
local liveLocal = not streaming   -- not a replay: record the local inputs instead
local detached = false            -- replay stream released with emu.takeover()

local H = 0           -- number of inputs recorded (inputs exist for frames 0..H-1)
local curFrame = 0    -- frame index of the emulator state right now (state S_curFrame)
local nextE = 0       -- frame whose transition (E -> E+1) the next emulation performs
local lastE = nil     -- transition performed by the last emulated frame
local displayFrame = 0

local mode = "PLAY"   -- "PLAY" or "PAUSE"
local speedIdx = SPEED_NORMAL
local rewinding, rewindFast, rewindAtStart = false, false, false
local rwCursor, rwLast = 0, 0
local pauseDisplay = 0
local seek = nil      -- { target = frame, cont = function }
local pendingStep = 0 -- frame steps pressed while a seek was still running
local endOfData = false

local t0, A = 0, 0    -- pacing baseline: wall time and frames advanced since
local turboOn = false

local overlayOn = CONFIG.OVERLAY
local message, messageUntil = nil, 0

local function say(text, seconds)
  message = text
  messageUntil = clock() + (seconds or 2.5)
end

--------------------------------------------------------------------------------
-- INPUT RECORDING (digital inputs packed 24 per number, one number per frame)
--------------------------------------------------------------------------------
local digitalNames = {}
do
  for name, v in pairs(joypad.get()) do
    if type(v) == "boolean" then digitalNames[#digitalNames + 1] = name end
  end
  table.sort(digitalNames)
end
local NCHUNK = math.max(1, math.ceil(#digitalNames / 24))
local chunks = {}
for c = 1, NCHUNK do chunks[c] = {} end
local pow2 = {}
for j = 0, 23 do pow2[j] = 2 ^ j end

local function storeInput(k, t)
  for c = 1, NCHUNK do
    local v, base = 0, (c - 1) * 24
    for j = 0, 23 do
      local name = digitalNames[base + j + 1]
      if not name then break end
      if t[name] then v = v + pow2[j] end
    end
    chunks[c][k + 1] = v
  end
end

local setTbl = {}
local function applyInput(k)
  for c = 1, NCHUNK do
    local v, base = chunks[c][k + 1] or 0, (c - 1) * 24
    for j = 0, 23 do
      local name = digitalNames[base + j + 1]
      if not name then break end
      local b = v % 2
      v = (v - b) / 2
      setTbl[name] = (b == 1)
    end
  end
  joypad.set(setTbl)
end

local function applyNeutral()
  for _, name in ipairs(digitalNames) do setTbl[name] = false end
  joypad.set(setTbl)
end

--------------------------------------------------------------------------------
-- SNAPSHOTS
--------------------------------------------------------------------------------
-- savestate.save_mem(key) stores into a 4096-slot ring inside the emulator and
-- load_mem(key) restores the newest slot with that key. Slots cannot be freed
-- from Lua, so a handle is valid while fewer than 4096 saves happened since.
local MEM_SAFE = 4096 - 96
local memSeq = 0
local KEY_BASE = 100000000 + (os.time() % 1000) * 1000000  -- unique per run

local function memSave()
  memSeq = memSeq + 1
  local key = KEY_BASE + memSeq
  savestate.save_mem(key)
  return { kind = 1, key = key, seq = memSeq }
end

local fileObjs, fileGen, fileNext = {}, {}, 0
local function fileSave()
  fileNext = fileNext % CONFIG.FILE_MAX_CHECKPOINTS + 1
  local o = fileObjs[fileNext]
  if not o then
    o = savestate.create()          -- anonymous temp file, deleted on exit
    fileObjs[fileNext] = o
  end
  fileGen[fileNext] = (fileGen[fileNext] or 0) + 1
  savestate.save(o)
  return { kind = 2, slot = fileNext, gen = fileGen[fileNext], obj = o }
end

local function valid(h)
  if not h then return false end
  if h.kind == 1 then return memSeq - h.seq < MEM_SAFE end
  return fileGen[h.slot] == h.gen
end

local function loadSnap(h)
  if h.kind == 1 then savestate.load_mem(h.key) else savestate.load(h.obj) end
end

local checkpointSave = (BACKEND == "mem") and memSave or fileSave
local transientSave = HAS_MEM and memSave or fileSave   -- pause / slow-motion frames

-- checkpoints: frame -> handle, plus a sorted list of frames
local ckpt, ckFrames = {}, {}

local function ckInsert(f, h)
  if valid(ckpt[f]) then return end
  if not ckpt[f] then
    local lo, hi = 1, #ckFrames + 1
    while lo < hi do
      local mid = floor((lo + hi) / 2)
      if ckFrames[mid] < f then lo = mid + 1 else hi = mid end
    end
    table.insert(ckFrames, lo, f)
  end
  ckpt[f] = h
end

local function ckRemoveAt(i)
  ckpt[ckFrames[i]] = nil
  table.remove(ckFrames, i)
end

local function ckFind(T)   -- newest valid checkpoint frame <= T
  local lo, hi, idx = 1, #ckFrames, 0
  while lo <= hi do
    local mid = floor((lo + hi) / 2)
    if ckFrames[mid] <= T then idx = mid; lo = mid + 1 else hi = mid - 1 end
  end
  while idx >= 1 do
    local f = ckFrames[idx]
    if valid(ckpt[f]) then return f end
    ckRemoveAt(idx)
    idx = idx - 1
  end
  return nil
end

local function ckEarliest()
  while #ckFrames > 0 do
    local f = ckFrames[1]
    if valid(ckpt[f]) then return f end
    ckRemoveAt(1)
  end
  return nil
end

local saveCount = 0
local function maybeCheckpoint(f)
  if f % INTERVAL == 0 and not valid(ckpt[f]) then
    ckInsert(f, checkpointSave())
    saveCount = saveCount + 1
    if saveCount % 512 == 0 then   -- sweep recycled entries
      local i = 1
      while i <= #ckFrames do
        if valid(ckpt[ckFrames[i]]) then i = i + 1 else ckRemoveAt(i) end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- SYNC FINGERPRINT (3rd Strike RAM: frame counter + P1/P2 player structs,
-- addresses from Grouflon's 3rd_training_lua)
--------------------------------------------------------------------------------
local FP_ON = CONFIG.VERIFY_SYNC and IS_3S and hasFn(memory, "readdword")
local FP_BASES = { 0x02068C6C, 0x02069104 }
local fp = {}
local verified, desyncs, firstDesync = 0, 0, nil

local function fingerprint()
  local rd = memory.readdword
  local h = rd(0x02007F00) % 4294967296
  for _, base in ipairs(FP_BASES) do
    for off = 0, 0xFC, 4 do
      h = (h * 31 + rd(base + off)) % 4294967296
    end
  end
  return h
end

local function verify(f)
  if not FP_ON then return end
  local v = fingerprint()
  local old = fp[f]
  if old == nil then
    fp[f] = v
  elseif old == v then
    verified = verified + 1
  else
    desyncs = desyncs + 1
    if not firstDesync then
      firstDesync = f
      print(string.format("DESYNC: frame %d differs from its first emulation.", f))
    end
  end
end

--------------------------------------------------------------------------------
-- PLAYBACK PRIMITIVES
--------------------------------------------------------------------------------
local function setTurbo(on)
  if on ~= turboOn then
    turboOn = on
    emu.speedmode(on and "turbo" or "normal")
  end
end

local function rebase() t0 = clock(); A = 0 end

local function canAdvance() return streaming or liveLocal or curFrame < H end

local holdH, holdFrame = nil, nil
local function canHold(h) return holdFrame == h and valid(holdH) end

local function doHold()           -- re-emulate holdFrame -> holdFrame+1
  loadSnap(holdH)
  curFrame = holdFrame
  nextE = holdFrame
end

local function advance(saveHold)  -- emulate curFrame -> curFrame+1
  if saveHold then
    holdH = transientSave()
    holdFrame = curFrame
    ckInsert(curFrame, holdH)
  end
  nextE = curFrame
end

local function startSeek(T, cont)  -- reach state S_T, then call cont()
  local c = ckFind(T)
  if not c then
    c = ckEarliest()
    if not c then cont(); return end
    if c > T then T = c end
  end
  loadSnap(ckpt[c])
  curFrame = c
  if c >= T then cont(); return end
  seek = { target = T, cont = cont }
  nextE = c
  setTurbo(T - c > 2)
end

local function minDisplay()
  local e = ckEarliest()
  return (e or curFrame) + 1
end

local function maxDisplay()
  if streaming or liveLocal then return math.huge end
  return H
end

local function showFrame(D)          -- make the next emulated frame show frame D
  D = math.max(minDisplay(), math.min(D, maxDisplay()))
  pauseDisplay = D
  if canHold(D - 1) then doHold(); return end
  if valid(ckpt[D - 1]) then
    holdH, holdFrame = ckpt[D - 1], D - 1
    doHold()
    return
  end
  if curFrame == D - 1 then advance(true); return end
  startSeek(D - 1, function()
    advance(true)
    pauseDisplay = curFrame + 1
  end)
end

local function enterPause()
  mode = "PAUSE"
  if canHold(curFrame - 1) or not canAdvance() then
    pauseDisplay = curFrame
  else
    pauseDisplay = curFrame + 1
  end
end

local function resume()
  mode = "PLAY"
  endOfData = false
  rebase()
end

local function setSpeed(i)
  speedIdx = i
  rebase()
end

--------------------------------------------------------------------------------
-- MODES
--------------------------------------------------------------------------------
local function playStep()
  if not canAdvance() then
    if not endOfData then say("End of recorded replay data", 3) end
    endOfData = true
    enterPause()
    showFrame(pauseDisplay)
    return
  end
  local s = SPEEDS[speedIdx]
  local lastFrame = (not streaming and not liveLocal and curFrame == H - 1)
  if s == 1 then
    setTurbo(false)
    advance(lastFrame)
    return
  end
  local budget = (clock() - t0) * FPS * s
  if s > 1 then
    local deficit = budget - A
    if deficit > FPS * 2 then rebase(); deficit = 0 end   -- machine can't keep up
    setTurbo(deficit >= CONFIG.TURBO_BURST)
    A = A + 1
    advance(lastFrame)
    return
  end
  -- slow motion: advance when the wall-clock budget allows, otherwise hold
  setTurbo(false)
  if budget - A > 3 then rebase(); budget = 0 end
  if A < floor(budget + 0.5) or not canHold(curFrame - 1) then
    A = A + 1
    advance(true)
  else
    doHold()
  end
end

local function rewindStep()
  local now = clock()
  local dt = math.min(now - rwLast, 0.1)
  rwLast = now
  local rate = rewindFast and CONFIG.REWIND_SPEED_FAST or CONFIG.REWIND_SPEED
  rwCursor = rwCursor - rate * FPS * dt
  local c = ckFind(floor(rwCursor) - 1)
  rewindAtStart = false
  if not c then
    c = ckEarliest()
    if not c then return end
    rwCursor = c + 1
    rewindAtStart = true
  end
  holdH, holdFrame = ckpt[c], c
  doHold()
end

local function startRewind()
  rewinding = true
  seek = nil
  pendingStep = 0
  setTurbo(false)
  rwCursor = displayFrame
  rwLast = clock()
end

local function stopRewind()
  rewinding = false
  rewindAtStart = false
  endOfData = false
  if mode == "PAUSE" then pauseDisplay = curFrame end
  rebase()
end

local function step(d)
  if mode ~= "PAUSE" then enterPause() end
  local D = pauseDisplay + d
  if d < 0 and D < minDisplay() then say("Start of rewind history", 1.5) end
  if d > 0 and D > maxDisplay() then say("End of recorded replay data", 1.5) end
  pauseDisplay = math.max(minDisplay(), math.min(D, maxDisplay()))
end

--------------------------------------------------------------------------------
-- KEYBOARD
--------------------------------------------------------------------------------
local prev = {}
local repeatAt = {}

local function handleKeys()
  local k = input.get()
  local function pressed(name) return k[name] and not prev[name] end

  if pressed("H") then overlayOn = not overlayOn end

  if not k.alt then
    for key, idx in pairs(SPEED_KEYS) do
      if pressed(key) then setSpeed(idx) end
    end
    if pressed("N") then setSpeed(SPEED_NORMAL) end
  end

  if pressed("space") then
    if mode == "PAUSE" then resume() else enterPause() end
  end

  rewindFast = k.shift and true or false
  if k.R and not rewinding then
    startRewind()
  elseif not k.R and rewinding then
    stopRewind()
  end

  local now = clock()
  for _, dir in ipairs({ "left", "right" }) do
    if k[dir] then
      local fire = false
      if not prev[dir] then
        fire = true
        repeatAt[dir] = now + CONFIG.STEP_REPEAT_DELAY
      elseif now >= (repeatAt[dir] or 0) then
        fire = true
        repeatAt[dir] = now + CONFIG.STEP_REPEAT_RATE
      end
      if fire and not rewinding then
        local d = (dir == "right") and 1 or -1
        if seek then pendingStep = pendingStep + d else step(d) end
      end
    end
  end

  prev = k
end

--------------------------------------------------------------------------------
-- EMULATOR HOOKS
--------------------------------------------------------------------------------
-- Runs before every emulated frame, after Fightcade has written this frame's
-- replay input (NetworkGetInput); joypad.set() here overrides it.
local function beforeFrame()
  local e = nextE
  local live = false
  if streaming then
    storeInput(H, joypad.get())     -- stream frame H = input of game frame H
    H = H + 1
    live = (e == H - 1)
  elseif liveLocal and e == H then
    storeInput(H, joypad.get())     -- local game: record the player's input
    H = H + 1
    live = true
  end
  if not live then
    if e < H then applyInput(e) else applyNeutral() end
  end
  lastE = e
end

local function onBoundary()
  local e = lastE
  lastE = nil
  if e == nil then return end
  curFrame = e + 1
  displayFrame = curFrame
  nextE = curFrame

  verify(curFrame)
  maybeCheckpoint(curFrame)
  handleKeys()

  if seek then
    if curFrame >= seek.target then
      local cont = seek.cont
      seek = nil
      setTurbo(false)
      cont()
      rebase()
      if pendingStep ~= 0 then
        local d = pendingStep
        pendingStep = 0
        step(d)
      end
    end
    return
  end
  if rewinding then rewindStep(); return end
  if mode == "PAUSE" then showFrame(pauseDisplay); return end
  playStep()
end

--------------------------------------------------------------------------------
-- OVERLAY
--------------------------------------------------------------------------------
local function fmtSpeed(s)
  if s == floor(s) then return string.format("%dx", s) end
  return (string.format("%.2f", s):gsub("0+$", "")) .. "x"
end

local function fmtTime(f)
  local t = f / FPS
  return string.format("%d:%05.2f", floor(t / 60), t % 60)
end

-- colours as {r,g,b,a} tables: unambiguous on every FBNeo build
local COL_BG = { r = 0, g = 0, b = 0, a = 160 }
local COL_REWIND = { r = 96, g = 192, b = 255, a = 255 }
local COL_FFWD = { r = 128, g = 255, b = 128, a = 255 }
local COL_DIM = { r = 200, g = 200, b = 200, a = 255 }
local COL_ALERT = { r = 255, g = 80, b = 80, a = 255 }
local COL_PAUSE = { r = 255, g = 208, b = 64, a = 255 }
local COL_TEXT = { r = 255, g = 255, b = 255, a = 255 }

local function drawOverlay()
  if not overlayOn then return end
  local x, y = CONFIG.OVERLAY_X, CONFIG.OVERLAY_Y
  local s = SPEEDS[speedIdx]
  local state
  if seek then state = "SEEK"
  elseif rewinding then state = rewindFast and "REWIND >>" or "REWIND"
  elseif mode == "PAUSE" then state = "PAUSE"
  elseif s > 1 then state = "FAST-FORWARD"
  else state = "PLAY" end

  local line1 = string.format("%s  %s  frame %d  %s", state, fmtSpeed(s), displayFrame, fmtTime(displayFrame))

  local earliest = ckEarliest() or displayFrame
  local src
  if detached then src = string.format("DETACHED (%d frames recorded)", H)
  elseif streaming then
    local lead = H - displayFrame
    if lead <= 1 then src = "REPLAY live" else src = string.format("REPLAY  buffered +%.1fs", lead / FPS) end
  else src = "LOCAL" end
  local line2 = string.format("%s  |  rewind %.0fs  snaps %d", src,
    math.max(0, displayFrame - earliest) / FPS, #ckFrames)

  local line3
  if message and clock() < messageUntil then
    line3 = message
  elseif rewindAtStart then
    line3 = "Start of rewind history"
  elseif FP_ON then
    if desyncs > 0 then
      line3 = string.format("DESYNC at frame %d (%d frames)", firstDesync, desyncs)
    elseif verified > 0 then
      line3 = string.format("SYNC OK (%d re-emulated frames checked)", verified)
    end
  end

  local w = math.max(#line1, #line2, line3 and #line3 or 0) * 4 + 6
  local hgt = line3 and 27 or 19
  if hasFn(gui, "box") then gui.box(x - 2, y - 2, x + w, y + hgt, COL_BG, COL_BG) end
  local stateColor = (state == "PAUSE" and COL_PAUSE) or (state:find("REWIND") and COL_REWIND)
    or (state == "FAST-FORWARD" and COL_FFWD) or COL_TEXT
  gui.text(x, y, line1, stateColor)
  gui.text(x, y + 9, line2, COL_DIM)
  if line3 then
    local c = (desyncs > 0 and not (message and clock() < messageUntil)) and COL_ALERT or COL_TEXT
    gui.text(x, y + 18, line3, c)
  end
end

--------------------------------------------------------------------------------
-- DETACH (Alt+1): release the replay stream and continue from recorded data
--------------------------------------------------------------------------------
local function detach()
  if not streaming then return end
  if hasFn(emu, "takeover") then emu.takeover() end
  streaming = false
  liveLocal = false
  detached = true
  say("Detached: playing recorded data only", 3)
end

--------------------------------------------------------------------------------
-- START
--------------------------------------------------------------------------------
ckInsert(0, checkpointSave())    -- state at script start = frame 0
curFrame, nextE = 0, 0
rebase()

emu.registerbefore(beforeFrame)
gui.register(drawOverlay)
emu.registerexit(function() emu.speedmode("normal") end)
if hasFn(input, "registerhotkey") then input.registerhotkey(1, detach) end

print("Fightcade replay controller")
print(string.format("  game: %s  source: %s  snapshots: %s every %d frames  sync check: %s",
  romname ~= "" and romname or "?", streaming and "replay stream" or "local inputs",
  BACKEND, INTERVAL, FP_ON and "on" or "off (not 3rd Strike)"))
print("  R rewind (Shift = fast) | SPACE pause | LEFT/RIGHT step")
print("  1-7 speed 0.25/0.5/1/1.25/1.5/2/4x | N normal | H overlay | Alt+1 detach")

while true do
  emu.frameadvance()
  onBoundary()
end
