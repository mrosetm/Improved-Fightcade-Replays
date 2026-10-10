-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 fightcade-replay-controller contributors
-- Test harness for fightcade_replay_controller.lua
--
-- Usage (needs a Lua 5.1 interpreter, the version FightcadeFBNeo embeds):
--   lua5.1 tests/mock_fightcade.lua [path/to/fightcade_replay_controller.lua]
-- Exit code 0 = all checks passed. Env STREAM_LEN sets the replay length.
--
-- Mock of the FightcadeFBNeo run loop, faithful to src/burner/win32/run.cpp:
--  RunIdle: turbo -> 10 undrawn RunFrame + 1 drawn, else 1 drawn (+catch-up)
--  RunFrame(kNetGame): NetworkGetInput (fail => return), Lua before hook,
--    FBA_LuaReadJoypad override, emulate, draw (gui.register), FrameBoundary.
-- The "game" is a deterministic RAM model read through memory.readdword.
local SCRIPT = arg[1] or "fightcade_replay_controller.lua"
local SCEN = arg[2] or "all"
local MOD = 4294967296

------------------------------------------------------------------ game model
local NAMES = {}
for p = 1, 2 do
  for _, b in ipairs({ "Up", "Down", "Left", "Right", "Weak Punch", "Medium Punch", "Strong Punch",
    "Weak Kick", "Medium Kick", "Strong Kick", "Start", "Coin", "Turbo" }) do
    NAMES[#NAMES + 1] = "P" .. p .. " " .. b
  end
end
for _, n in ipairs({ "Reset", "Service", "Diagnostic", "Tilt" }) do NAMES[#NAMES + 1] = n end
-- 30 digital inputs -> exercises 2 packing chunks; plus a numeric constant
local function newState()
  local s = { fc = 1000, p = {} }
  for i = 1, 128 do s.p[i] = (i * 2654435761) % MOD end
  return s
end
local function copy(s)
  local c = { fc = s.fc, p = {} }
  for i = 1, 128 do c.p[i] = s.p[i] end
  return c
end
local function eq(a, b)
  if a.fc ~= b.fc then return false end
  for i = 1, 128 do if a.p[i] ~= b.p[i] then return false end end
  return true
end
local function emulate(s, inp)
  local bits = 0
  for i, n in ipairs(NAMES) do if inp[n] then bits = bits + i * 7919 end end
  s.fc = s.fc + 1
  for i = 1, 128 do
    local prevv = s.p[(i % 128) + 1]
    s.p[i] = (s.p[i] * 31 + bits * (i + 3) + prevv + s.fc) % MOD
  end
end

------------------------------------------------------------------ stream
local function lcg(seed) local x = seed; return function() x = (x * 1103515245 + 12345) % 2147483648; return x end end
local STREAM_LEN = tonumber(os.getenv("STREAM_LEN") or "") or 50000
local rnd = lcg(42)
local stream = {}
local held = {}
for f = 0, STREAM_LEN - 1 do
  local t = {}
  for _, n in ipairs(NAMES) do
    if rnd() % 10 == 0 then held[n] = not held[n] end
    t[n] = held[n] and (n ~= "Reset") or false
  end
  stream[f] = t
end
-- reference timeline: ref[fc] = state with frame counter fc
local ref = {}
do
  local s = newState(); ref[s.fc] = copy(s)
  for f = 0, STREAM_LEN - 1 do emulate(s, stream[f]); ref[s.fc] = copy(s) end
end

------------------------------------------------------------------ emulator
local E = {
  state = newState(), streamPos = 0, netGame = true, spectator = true,
  turbo = false, now = 0, inputs = {}, luaJoy = nil, ticks = 0,
  saveMemCalls = 0, ring = {}, ringNext = 0, errors = 0, frames = 0,
  keys = {}, hotkeys = {}, drawn = {}, overlay = {}, maxRingBytes = 0,
}
for _, n in ipairs(NAMES) do E.inputs[n] = false end
local function fail(msg) E.errors = E.errors + 1; if E.errors < 40 then print("  FAIL: " .. msg) end end

emu = {}
memory = {}
joypad = {}
input = {}
gui = {}
savestate = {}
local before, guifn, exitfn
function emu.frameadvance() coroutine.yield() end
function emu.registerbefore(f) before = f end
function emu.registerexit(f) exitfn = f end
function emu.speedmode(m)
  if m == "turbo" then E.turbo = true elseif m == "normal" then E.turbo = false else error("Invalid mode " .. m) end
end
function emu.isreplay() if E.spectator then return emu.isreplay end end -- quirk: returns func
function emu.takeover() E.spectator = false; E.netGame = false; return emu.takeover end
function emu.romname() return "sfiii3nr1" end
function emu.framecount() return E.frames end
function memory.readdword(a)
  local v
  if a == 0x02007F00 then v = E.state.fc
  elseif a >= 0x02068C6C and a < 0x02068C6C + 0x100 then v = E.state.p[(a - 0x02068C6C) / 4 + 1]
  elseif a >= 0x02069104 and a < 0x02069104 + 0x100 then v = E.state.p[(a - 0x02069104) / 4 + 65]
  else v = 0 end
  if v >= 2147483648 then v = v - MOD end -- 32-bit lua_Integer on win32
  return v
end
function joypad.get()
  local t = {}
  for k, v in pairs(E.inputs) do t[k] = v end
  t["Region"] = 3 -- constant input (numeric), must be ignored
  return t
end
function joypad.set(t)
  E.luaJoy = {}
  for _, n in ipairs(NAMES) do if t[n] ~= nil then E.luaJoy[n] = t[n] and true or false end end
end
function input.get()
  local t = { xmouse = 0, ymouse = 0 }
  for k, v in pairs(E.keys) do if v then t[k] = true end end
  return t
end
function input.registerhotkey(n, f) E.hotkeys[n] = f end
function gui.register(f) guifn = f end
function gui.text(x, y, s) E.overlay[#E.overlay + 1] = s end
function gui.box() end
-- save_mem ring identical to luaengine.cpp (MAX_SLOTS 4096, newest-first lookup)
function savestate.save_mem(key)
  E.ring[E.ringNext] = { key = key, s = copy(E.state) }
  E.ringNext = (E.ringNext + 1) % 4096
  E.saveMemCalls = E.saveMemCalls + 1
  local n = 0; for _ in pairs(E.ring) do n = n + 1 end
  if n > E.maxRingBytes then E.maxRingBytes = n end
end
function savestate.load_mem(key)
  for i = 0, 4095 do
    local idx = (E.ringNext - 1 - i + 4096) % 4096
    local slot = E.ring[idx]
    if slot and slot.key == key then E.state = copy(slot.s); return end
  end
  fail("load_mem miss for key " .. key) -- real emulator silently does nothing
end
function savestate.create() return { file = true } end
function savestate.save(o) o.s = copy(E.state); E.fileSaves = (E.fileSaves or 0) + 1 end
function savestate.load(o) if not o.s then fail("load of empty file state") else E.state = copy(o.s) end end
os.clock = function() return E.now end

------------------------------------------------------------------ run loop
local co
local function boundary()
  local ok, err = coroutine.resume(co)
  if not ok then error("script error: " .. tostring(err)) end
end
local function runFrame(draw)
  if E.netGame then
    if E.streamPos >= STREAM_LEN then return false end -- stream ended: frame not run
    for _, n in ipairs(NAMES) do E.inputs[n] = stream[E.streamPos][n] end
    E.streamPos = E.streamPos + 1
  else
    for _, n in ipairs(NAMES) do E.inputs[n] = (E.keys["phys:" .. n] or false) end
  end
  if before then before() end
  if E.luaJoy then
    for n, v in pairs(E.luaJoy) do E.inputs[n] = v end
    E.luaJoy = nil
  end
  emulate(E.state, E.inputs)
  E.frames = E.frames + 1
  -- invariant: emulator state always equals the reference state for its frame
  local r = ref[E.state.fc]
  if not r or not eq(r, E.state) then fail("state diverged at game frame " .. E.state.fc) end
  if draw then
    E.overlay = {}
    if guifn then guifn() end
    E.drawn[#E.drawn + 1] = { tick = E.ticks, fc = E.state.fc, text = table.concat(E.overlay, " | ") }
  end
  boundary()
  return true
end
local function tick()
  E.ticks = E.ticks + 1
  E.now = E.ticks / 59.59949
  if E.turbo then for _ = 1, 10 do runFrame(false) end end
  runFrame(true)
end

------------------------------------------------------------------ load script
local chunk = assert(loadfile(SCRIPT))
-- strict environment: reading an unknown global or writing any global fails
setfenv(chunk, setmetatable({}, {
  __index = function(_, k)
    local v = _G[k]
    if v == nil then error("script reads undeclared global '" .. tostring(k) .. "'", 2) end
    return v
  end,
  __newindex = function(_, k) error("script writes global '" .. tostring(k) .. "'", 2) end,
}))
co = coroutine.create(chunk)
boundary() -- runs the chunk until its first emu.frameadvance()

local function run(n, keys)
  E.keys = keys or {}
  for _ = 1, n do tick() end
end
local function lastFc() return E.drawn[#E.drawn].fc end
local function lastText() return E.drawn[#E.drawn].text end
local function rate(nticks, keys)
  local a = lastFc(); run(nticks, keys); return (lastFc() - a) / nticks
end
local function check(cond, msg) if cond then print("  ok   " .. msg) else fail(msg) end end
local function press(k, n) run(1, { [k] = true }); run(n or 1) end

------------------------------------------------------------------ scenarios
print("== playback, then rewind / resume cycles")
run(1200)
local liveFc = lastFc()
check(liveFc == 1000 + 1201 - 1 or liveFc > 2000, "plays at 1x while live (fc " .. liveFc .. ")")
run(90, { R = true })
local afterRw = lastFc()
check(afterRw < liveFc - 200, string.format("rewound from %d to %d", liveFc, afterRw))
run(1)
local r1 = rate(300)
check(math.abs(r1 - 1) < 0.01, string.format("resumes at 1x after rewind (rate %.3f)", r1))
for cycle = 1, 5 do run(40, { R = true }); run(120) end
check(E.errors == 0, "5 more rewind/resume cycles kept state == reference")
check(lastText():find("REPLAY") and lastText():find("PLAY"), "overlay: " .. lastText())

print("== speeds")
local expect = { 0.25, 0.5, 1, 1.25, 1.5, 2, 4 }
for i = 1, 7 do
  press(tostring(i), 0)
  run(30)
  local r = rate(1200)
  check(math.abs(r - expect[i]) / expect[i] < 0.03, string.format("speed key %d -> %.3fx (want %gx)", i, r, expect[i]))
end
press("N", 0)
local rn = rate(600)
check(math.abs(rn - 1) < 0.01, string.format("N restores 1x (%.3f)", rn))

print("== pause / step")
press("space", 2)
local p0 = lastFc()
run(120)
check(lastFc() == p0, "paused: same frame for 120 refreshes")
press("right", 2); check(lastFc() == p0 + 1, "RIGHT steps +1")
press("right", 2); check(lastFc() == p0 + 2, "RIGHT steps +1 again")
for _ = 1, 7 do press("left", 4) end
check(lastFc() == p0 - 5, string.format("7x LEFT steps back exactly (fc %d, want %d)", lastFc(), p0 - 5))
run(60); check(lastFc() == p0 - 5, "still paused after stepping back")
local h0 = lastFc(); run(40, { left = true }); run(5)
check(lastFc() < h0 - 2, string.format("holding LEFT auto-repeats (%d -> %d)", h0, lastFc()))
press("space", 1)
local rp = rate(300)
check(math.abs(rp - 1) < 0.01, string.format("SPACE resumes at 1x (%.3f)", rp))
press("2", 0); press("space", 2); local q = lastFc(); run(60)
check(lastFc() == q, "pause works in slow motion"); press("space", 0); press("3", 0)
run(50, { R = true }); press("space", 2); local q2 = lastFc(); run(30, { R = true }); run(3)
check(lastFc() < q2, "rewind while paused stays paused at the earlier frame"); run(60)
local q3 = lastFc(); run(30); check(lastFc() == q3, "remains paused after releasing R")
press("space", 1)

print("== long run: snapshot ring recycling (save_mem ring is 4096)")
run(6000)
run(200, { R = true, shift = true }); run(1)
run(600)
check(E.errors == 0, string.format("after %d save_mem calls, no stale snapshot was loaded", E.saveMemCalls))
check(E.maxRingBytes <= 4096, "emulator snapshot ring stays bounded at 4096 slots")
for _ = 1, 3 do run(400, { R = true, shift = true }) end
run(2)
local txt = lastText()
check(E.drawn[#E.drawn].text and E.errors == 0, "rewinding to the history limit clamps safely: " .. txt)
print("  overlay line: " .. txt)

check(E.streamPos < STREAM_LEN, "stream still flowing before the stream-end test (" .. E.streamPos .. " consumed)")
print("== stream end + Alt+1 detach")
local before_end = E.streamPos
press("space", 2)
while E.streamPos < STREAM_LEN do tick() end -- paused: stream drains ahead
local stalledFc = lastFc(); local f0 = E.frames
run(30)
check(E.frames == f0, "stream ended: emulator stops running frames (Lua frozen)")
E.hotkeys[1]()
run(5)
check(E.frames > f0, "Alt+1 detach: frames run again locally")
press("space", 1)
run(400)
check(E.errors == 0, "detached playback uses recorded inputs (state == reference)")
local endFc = 1000 + STREAM_LEN
run(STREAM_LEN) -- play to the end of recorded data
check(lastFc() == endFc, string.format("stops exactly at last recorded frame (%d)", lastFc()))
run(60); check(lastFc() == endFc, "stays paused at end of data")
run(100, { R = true }); run(1); press("space", 1); run(50)
check(E.errors == 0 and lastFc() < endFc, "rewind still works after detaching")

print("== after ring wrap-around: rewind to the oldest surviving snapshot")
check(E.saveMemCalls > 4096, "ring has wrapped (" .. E.saveMemCalls .. " saves)")
local guard = 0
repeat run(50, { R = true, shift = true }); guard = guard + 50
until lastText():find("Start of rewind history") or guard > 20000
check(lastText():find("Start of rewind history") ~= nil, "rewind reached the history limit: " .. lastText())
run(60, { R = true }) -- keep pushing against the limit
run(1)
check(E.errors == 0, "clamped at oldest valid snapshot, no recycled slot loaded")
press("space", 1); run(600)
check(E.errors == 0, "plays forward in sync from the history limit")
print("")
print(string.format("ticks %d, frames emulated %d, save_mem calls %d, failures %d",
  E.ticks, E.frames, E.saveMemCalls, E.errors))
if exitfn then exitfn() end
check(E.turbo == false, "exit handler restores normal speed")
os.exit(E.errors == 0 and 0 or 1)
