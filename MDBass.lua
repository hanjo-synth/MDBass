-- MDBass
-- Machinedrum Tone generator
-- 
-- HANJO, Tokyo, Japan.
-- (unofficial OS "X", TONAL pitch)
--
-- One track. Every note step sends:
--   1. CC on the track's MIDI channel
--      -> Synth parameter 1 (PTCH),
--      scale-quantized
--   2. a trigger note
--
-- E1: target track (1-16)
-- E2: select parameter
-- E3: change parameter
-- K2: play / stop
-- K3: regenerate bassline
--
-- hold K1 (shift):
-- K1+K2: audition root + octave
--        (use to calibrate tuning)
-- K1+K3: mutate once
-- K1+E2: select step / preview its CC
--
-- MACHINEDRUM SETUP
--  * MD base channel = "MD base channel"
--    param (default 1). Track t listens
--    for CC on base + (t-1)//4.
--  * On the target track use a machine
--    with tuning and set its tonality
--    to TONAL (EDIT KIT > tuning).
--  * Calibrate: K1+K2 plays the root and
--    the octave above. Adjust
--    "tune: CC @ C2" until the root is
--    right, and "CC steps per semitone"
--    (1 or 2) until the second note is
--    exactly one octave up.
--
-- RECORD MODE (E2 > MODE > REC)
--  K2 runs ONE clean 16-step take:
--  (optional) rec-arm note, bar-aligned
--  MIDI START, count-in bar(s), 16 steps,
--  MIDI STOP. PROB% / EVOLVE% ignored.
--  MD: external clock + transport in,
--  norns CLOCK menu: MIDI clock out
--  to the MD, empty 16-step pattern,
--  REC armed (by hand or via a note
--  mapped in MAP EDITOR > CTRL).

local util = require "util"
local musicutil = require "musicutil"

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------

local MAX_STEPS = 16
local REF_NOTE  = 36     -- MIDI note that "tune: CC @ C2" refers to

-- Default MD Map Editor trigger notes, tracks 1..16 (verify on your MD;
-- override with the "trig note" param).
local MD_NOTES = {36,38,40,41,43,45,47,48,50,52,53,55,57,59,60,62}

-- CC number of Synth parameter 1 (PTCH) for the 4 tracks that share a
-- MIDI channel (tracks 1-4 on base+0, 5-8 on base+1, ...).
-- Source: midi.guide MachineDrum table (param 01 = 16, 40, 72, 96).
local PTCH_CC = {16, 40, 72, 96}

local DIV_NAMES = {"1/8", "1/16", "1/32"}
local DIV_BEATS = {1/2, 1/4, 1/8}

local ROOT_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local STYLE_NAMES = {"IDM", "DNB", "HOUSE", "TECHNO", "TRANCE", "ELECTRO"}

-- pats  : candidate rhythms, 0-based steps of a 16-step bar
-- rand  : {min,max} random hit count (IDM), lens: possible lengths
-- move  : max scale-degree step between notes
-- oct   : % chance of an octave jump
-- root  : % chance of the root on strong steps (1, 5, 9, 13)
-- ghost : % of extra quiet notes on empty steps
-- evolve: % chance per loop that one step mutates
local STYLES = {
  IDM = {rand = {3, 8}, lens = {16, 15, 14, 13, 12},
         move = 4, oct = 25, root = 40, ghost = 15, evolve = 25},
  DNB = {pats = {{0, 10}, {0, 3, 10, 14}, {0, 6, 10, 11}, {0, 3, 6, 10}},
         move = 2, oct = 15, root = 70, ghost = 5, evolve = 8},
  HOUSE = {pats = {{2, 6, 10, 14}, {2, 3, 6, 10, 14}, {0, 3, 6, 10, 12},
                   {0, 3, 6, 8, 11, 14}},
           move = 2, oct = 25, root = 50, ghost = 10, evolve = 5},
  TECHNO = {pats = {{2, 6, 10, 14}, {2, 3, 6, 10, 11, 14}, {0, 3, 6, 10, 12, 15},
                    {0, 2, 3, 6, 7, 10, 11, 14}},
            move = 1, oct = 15, root = 60, ghost = 10, evolve = 12},
  TRANCE = {pats = {{1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15},
                    {2, 3, 6, 7, 10, 11, 14, 15}},
            move = 1, oct = 30, root = 80, ghost = 0, evolve = 3},
  ELECTRO = {pats = {{0, 3, 6, 10}, {0, 3, 7, 10, 12}, {0, 6, 10, 13}, {0, 3, 6, 9, 12}},
             move = 2, oct = 20, root = 60, ghost = 8, evolve = 8},
}

-- E2 parameter list: all are norns params, edited with E3
local LIST = {
  {id = "style",    name = "STYLE"},
  {id = "scale",    name = "SCALE"},
  {id = "root",     name = "ROOT"},
  {id = "octave",   name = "OCTAVE"},
  {id = "range",    name = "RANGE OCT"},
  {id = "length",   name = "LENGTH"},
  {id = "move",     name = "MOVE"},
  {id = "oct_pct",  name = "OCT JUMP%"},
  {id = "root_pct", name = "ROOT%"},
  {id = "ghost",    name = "GHOST%"},
  {id = "prob",     name = "PROB%"},
  {id = "evolve",   name = "EVOLVE%"},
  {id = "mode",     name = "MODE"},
}

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local out
local gate, deg, vel = {}, {}, {}
local pos = 0
local param_sel = 1
local sel_step = 1
local shift = false
local playing = false
local seq_id = nil
local rec_task = nil       -- running record take
local rec_state = nil      -- nil | "count" | "rec"
local rec_step = 0
local last_note, last_cc = nil, nil
local dirty = true

---------------------------------------------------------------------
-- MACHINEDRUM / MUSIC HELPERS
---------------------------------------------------------------------

local function target_track() return params:get("track") end

-- CC channel of the active track: base + (track-1)//4
local function cc_channel(t)
  return util.clamp(params:get("base_ch") + (t - 1) // 4, 1, 16)
end

local function trig_channel(t)
  if params:get("trig_on") == 2 then return cc_channel(t) end
  return params:get("base_ch")
end

local function trig_note(t)
  local n = params:get("trig_note")
  if n > 0 then return n end
  return MD_NOTES[t]
end

-- scale intervals within one octave (trailing 12 removed)
local function scale_intervals()
  local sc = musicutil.SCALES[params:get("scale")]
  local iv = {}
  for _, v in ipairs(sc.intervals) do
    if v < 12 then iv[#iv + 1] = v end
  end
  return iv
end

local function top_degree()
  return params:get("range") * #scale_intervals()
end

-- reflect a degree back into 0..top
local function fold(d, top)
  if top <= 0 then return 0 end
  while d < 0 or d > top do
    if d < 0 then d = -d end
    if d > top then d = 2 * top - d end
  end
  return d
end

-- scale degree (0 = root of the base octave) -> MIDI note
local function degree_to_note(d)
  local iv = scale_intervals()
  local n = #iv
  local base = 12 * (params:get("octave") + 1) + (params:get("root") - 1)
  return base + (d // n) * 12 + iv[d % n + 1]
end

-- MIDI note -> PTCH CC value on a TONAL track (quantized: integer
-- steps of 1 semitone = "CC steps per semitone" CC values).
local function note_to_cc(note)
  local cps = params:get("cc_per_semi")
  local cc = params:get("ref_cc") + (note - REF_NOTE) * cps
  while cc > 127 do cc = cc - 12 * cps end
  while cc < 0 do cc = cc + 12 * cps end
  return cc
end

-- send PTCH CC + trigger note (in this order, same coroutine)
local function send_degree(d, v, delay)
  local t = target_track()
  local note = degree_to_note(fold(d, top_degree()))
  local cc = note_to_cc(note)
  last_note, last_cc = note, cc
  dirty = true

  local cc_ch = cc_channel(t)
  local tr_ch = trig_channel(t)
  local tn = trig_note(t)
  local cc_num = PTCH_CC[(t - 1) % 4 + 1]

  clock.run(function()
    if delay and delay > 0 then clock.sleep(delay) end
    out:cc(cc_num, cc, cc_ch)
    out:note_on(tn, v, tr_ch)
    clock.sleep(0.02)
    out:note_off(tn, 0, tr_ch)
  end)
end

-- a short note used for MD Map Editor CTRL functions (0 = off)
local function send_ctrl_note(note)
  if note < 1 then return end
  local ch = params:get("base_ch")
  clock.run(function()
    out:note_on(note, 127, ch)
    clock.sleep(0.02)
    out:note_off(note, 0, ch)
  end)
end

-- preview the PTCH CC of a given step without triggering the drum,
-- so you can scroll steps and watch/hear the pitch CC alone.
local function preview_step(i)
  local t = target_track()
  local note = degree_to_note(fold(deg[i], top_degree()))
  local cc = note_to_cc(note)
  last_note, last_cc = note, cc
  dirty = true

  local cc_ch = cc_channel(t)
  local cc_num = PTCH_CC[(t - 1) % 4 + 1]
  out:cc(cc_num, cc, cc_ch)
end

---------------------------------------------------------------------
-- BASSLINE GENERATION
---------------------------------------------------------------------

local function load_style_defaults()
  local st = STYLES[STYLE_NAMES[params:get("style")]]
  params:set("move", st.move, true)
  params:set("oct_pct", st.oct, true)
  params:set("root_pct", st.root, true)
  params:set("ghost", st.ghost, true)
  params:set("evolve", st.evolve, true)
end

local function generate()
  local st = STYLES[STYLE_NAMES[params:get("style")]]
  if st.lens then
    params:set("length", st.lens[math.random(#st.lens)], true)
  end
  local len = params:get("length")

  for i = 1, MAX_STEPS do
    gate[i] = false
    deg[i] = 0
    vel[i] = 95
  end

  -- 1. rhythm
  if st.pats then
    local pat = st.pats[math.random(#st.pats)]
    for _, s in ipairs(pat) do
      if s < len then gate[s + 1] = true end
    end
  else
    local n = math.min(math.random(st.rand[1], st.rand[2]), len)
    gate[1] = true
    n = n - 1
    while n > 0 do
      local s = math.random(1, len)
      if not gate[s] then
        gate[s] = true
        n = n - 1
      end
    end
  end
  -- ghost notes (quiet)
  for i = 1, len do
    if not gate[i] and math.random(100) <= params:get("ghost") then
      gate[i] = true
      vel[i] = math.random(50, 70)
    end
  end

  -- 2. pitch: random walk over scale degrees, root on strong steps
  local n = #scale_intervals()
  local top = params:get("range") * n
  local mv = params:get("move")
  local cur = 0
  local first = true
  for i = 1, len do
    if gate[i] then
      local strong = (i - 1) % 4 == 0
      local d
      if (first or strong) and math.random(100) <= params:get("root_pct") then
        d = 0
      else
        d = cur + math.random(-mv, mv)
        if math.random(100) <= params:get("oct_pct") then
          d = d + ((math.random(2) == 1) and n or -n)
        end
      end
      d = fold(d, top)
      deg[i] = d
      cur = d
      first = false
      if vel[i] >= 95 then vel[i] = strong and 115 or 95 end
    end
  end
end

-- change one thing: nudge a pitch, toggle a step (keeps >= 1 note)
local function mutate()
  local len = params:get("length")
  local top = top_degree()
  local mv = params:get("move")
  local count = 0
  for i = 1, len do if gate[i] then count = count + 1 end end

  local i = math.random(len)
  if gate[i] and math.random(100) <= 60 then
    local delta = math.random(1, math.max(1, mv))
    if math.random(2) == 1 then delta = -delta end
    deg[i] = fold(deg[i] + delta, top)
  elseif gate[i] then
    if count > 1 then gate[i] = false end
  else
    gate[i] = true
    deg[i] = fold(deg[(i - 2) % len + 1] + math.random(-mv, mv), top)
    vel[i] = math.random(55, 85)
  end
end

---------------------------------------------------------------------
-- SEQUENCER
---------------------------------------------------------------------

-- clean = true during a record take: deterministic (no EVOLVE, PROB
-- ignored) so the MD captures exactly what is on screen.
local function step(clean)
  local len = params:get("length")
  pos = pos % len + 1

  local evolve = params:get("evolve")
  if not clean and pos == 1 and evolve > 0 and math.random(100) <= evolve then
    mutate()
  end

  if gate[pos] and (clean or math.random(100) <= params:get("prob")) then
    send_degree(deg[pos], vel[pos],
      clean and params:get("rec_nudge") / 1000 or nil)
  end
end

local function seq()
  while true do
    clock.sync(DIV_BEATS[params:get("div")])
    step(false)
    dirty = true
  end
end

local function start()
  pos = 0
  seq_id = clock.run(seq)
  playing = true
end

local function stop()
  if seq_id then clock.cancel(seq_id) end
  seq_id = nil
  playing = false
end

---------------------------------------------------------------------
-- RECORD MODE: one clean 16-step pass captured by the MD's sequencer
---------------------------------------------------------------------

local function disarm()
  if params:get("rec_note_end") == 2 then
    send_ctrl_note(params:get("rec_note"))
  end
end

local function cancel_take()
  if rec_task then
    clock.cancel(rec_task)
    rec_task = nil
    out:stop()
    disarm()
  end
  rec_state = nil
  rec_step = 0
  dirty = true
end

local function start_take()
  if rec_task then return end
  pos = 0
  rec_task = clock.run(function()
    send_ctrl_note(params:get("rec_note"))   -- arm MD record (if mapped)
    clock.sync(4)                            -- next bar
    out:start()                              -- MD PLAY
    rec_state = "count"
    dirty = true
    for _ = 1, 16 * params:get("count_in") do clock.sync(1 / 4) end

    rec_state = "rec"
    for s = 1, 16 do
      rec_step = s
      step(true)
      dirty = true
      clock.sync(1 / 4)
    end

    out:stop()
    disarm()
    pos = 0
    rec_task = nil
    rec_state = nil
    rec_step = 0
    dirty = true
  end)
end

-- root, then the octave above: verify tuning by ear / tuner
local function audition()
  local n = #scale_intervals()
  clock.run(function()
    send_degree(0, 110)
    clock.sleep(0.6)
    send_degree(n, 110)
  end)
end

---------------------------------------------------------------------
-- NORNS INIT / CONTROLS
---------------------------------------------------------------------

function init()
  math.randomseed(os.time())

  local scale_names = {}
  local default_scale = 1
  for i, sc in ipairs(musicutil.SCALES) do
    scale_names[i] = sc.name
    if sc.name == "Minor Pentatonic" then default_scale = i end
  end

  params:add_separator("MDBASS")
  params:add{type = "number", id = "midi_dev", name = "MIDI device",
    min = 1, max = 4, default = 1,
    action = function(x) out = midi.connect(x) end}
  params:add{type = "number", id = "base_ch", name = "MD base channel",
    min = 1, max = 13, default = 1}
  params:add{type = "number", id = "track", name = "target track",
    min = 1, max = 16, default = 1,
    action = function() dirty = true end}
  params:add{type = "option", id = "div", name = "step division",
    options = DIV_NAMES, default = 2}
  params:add{type = "option", id = "trig_on", name = "trigger note on",
    options = {"BASE CH", "TRACK CH"}, default = 1}
  params:add{type = "number", id = "trig_note", name = "trig note (0=auto)",
    min = 0, max = 127, default = 0}

  params:add_separator("bassline")
  params:add{type = "option", id = "style", name = "style",
    options = STYLE_NAMES, default = 4,
    action = function()
      load_style_defaults()
      generate()
      dirty = true
    end}
  params:add{type = "option", id = "scale", name = "scale",
    options = scale_names, default = default_scale,
    action = function() dirty = true end}
  params:add{type = "option", id = "root", name = "root",
    options = ROOT_NAMES, default = 1,
    action = function() dirty = true end}
  params:add{type = "number", id = "octave", name = "base octave",
    min = 0, max = 4, default = 2,
    action = function() dirty = true end}
  params:add{type = "number", id = "range", name = "range (octaves)",
    min = 1, max = 3, default = 2,
    action = function() dirty = true end}
  params:add{type = "number", id = "length", name = "length",
    min = 1, max = 16, default = 16,
    action = function()
      generate()
      sel_step = math.min(sel_step, params:get("length"))
      dirty = true
    end}
  params:add{type = "number", id = "move", name = "move (max degrees)",
    min = 1, max = 7, default = 1}
  params:add{type = "number", id = "oct_pct", name = "octave jump %",
    min = 0, max = 100, default = 15}
  params:add{type = "number", id = "root_pct", name = "root on strong %",
    min = 0, max = 100, default = 60}
  params:add{type = "number", id = "ghost", name = "ghost notes %",
    min = 0, max = 100, default = 10}
  params:add{type = "number", id = "prob", name = "probability %",
    min = 0, max = 100, default = 100}
  params:add{type = "number", id = "evolve", name = "evolve %",
    min = 0, max = 100, default = 12}

  params:add_separator("PTCH tuning (TONAL)")
  params:add{type = "number", id = "ref_cc", name = "tune: CC @ C2",
    min = 0, max = 127, default = 64}
  params:add{type = "number", id = "cc_per_semi", name = "CC steps per semitone",
    min = 1, max = 2, default = 2}

  params:add_separator("record")
  params:add{type = "option", id = "mode", name = "mode",
    options = {"PLAY", "REC"}, default = 1,
    action = function(x)
      if x == 2 then stop() else cancel_take() end
      dirty = true
    end}
  params:add{type = "number", id = "count_in", name = "rec count-in bars",
    min = 0, max = 4, default = 1}
  params:add{type = "number", id = "rec_nudge", name = "rec nudge (ms)",
    min = 0, max = 60, default = 10}
  params:add{type = "number", id = "rec_note", name = "MD rec-arm note (0=off)",
    min = 0, max = 127, default = 0}
  params:add{type = "option", id = "rec_note_end", name = "send arm note again at end",
    options = {"NO", "YES"}, default = 1}

  out = midi.connect(params:get("midi_dev"))

  load_style_defaults()
  generate()

  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      if dirty then
        dirty = false
        redraw()
      end
    end
  end)
end

function key(n, z)
  if n == 1 then
    shift = (z == 1)
  elseif z == 1 then
    if n == 2 then
      if shift then
        audition()
      elseif params:get("mode") == 2 then
        if rec_task then cancel_take() else start_take() end
      elseif playing then
        stop()
      else
        start()
      end
    elseif n == 3 then
      if shift then mutate() else generate() end
    end
  end
  dirty = true
end

function enc(n, d)
  if n == 1 then
    params:delta("track", d)
  elseif n == 2 then
    if shift then
      local len = params:get("length")
      sel_step = (sel_step - 1 + d) % len + 1
      preview_step(sel_step)
    else
      param_sel = (param_sel - 1 + d) % #LIST + 1
    end
  elseif n == 3 then
    params:delta(LIST[param_sel].id, d)
  end
  dirty = true
end

function cleanup()
  stop()
  cancel_take()
end

---------------------------------------------------------------------
-- SCREEN
---------------------------------------------------------------------

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_size(8)

  local t = target_track()
  local len = params:get("length")
  local top = math.max(top_degree(), 1)

  -- header: target track, CC channel + CC number, last note sent
  screen.level(15)
  screen.move(0, 7)
  screen.text("T" .. t .. " CH" .. cc_channel(t) .. " CC" .. PTCH_CC[(t - 1) % 4 + 1])
  if last_note then
    screen.level(8)
    screen.move(128, 7)
    if shift then
      screen.text_right("S" .. sel_step .. " " .. musicutil.note_num_to_name(last_note, true) .. " cc" .. last_cc)
    else
      screen.text_right(musicutil.note_num_to_name(last_note, true) .. " cc" .. last_cc)
    end
  end

  -- step bars: height = pitch (scale degree), dim dot = rest
  local base_y = 44
  for i = 1, len do
    local x = 8 + (i - 1) * 7
    if gate[i] then
      local d = fold(deg[i], top_degree())
      local h = 3 + math.floor(28 * d / top)
      screen.level(util.round(4 + (vel[i] / 127) * 11))
      screen.rect(x, base_y - h, 5, h)
      screen.fill()
    else
      screen.level(2)
      screen.rect(x, base_y - 1, 5, 1)
      screen.fill()
    end
    if (playing or rec_state == "rec") and i == pos then
      screen.level(15)
      screen.move(x, base_y + 3)
      screen.line_rel(5, 0)
      screen.stroke()
    end
    if shift and i == sel_step then
      screen.level(15)
      screen.rect(x, base_y + 6, 5, 1)
      screen.fill()
    end
  end

  -- bottom: selected parameter + status
  local p = LIST[param_sel]
  screen.level(15)
  screen.move(0, 62)
  screen.text(p.name .. " " .. params:string(p.id))
  screen.level(6)
  local status = playing and "PLAY" or "STOP"
  if params:get("mode") == 2 then
    if rec_state == "count" then status = "COUNT-IN"
    elseif rec_state == "rec" then status = "REC " .. rec_step .. "/16"
    else status = "REC READY" end
  end
  screen.move(128, 62)
  screen.text_right(status)

  screen.update()
end
