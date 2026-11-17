-- A mock grandMA3 for the marker export's Lua: pools of pages, executors, sequences (with cues
-- and their stored contents) and timecode shows, the object calls the export uses (ObjectList,
-- Children, GetClass, Set, Append, properties) and the command lines it sends through Cmd.
-- Children appended to a timecode show appear a few frames later, as on the console, and a new
-- TrackGroup grows a Track and a Track a TimeRange on their own.
--
-- Anything the export does that would destroy something (storing over an existing sequence, cue
-- or timecode show, copying onto a taken slot, assigning over another sequence) is a violation.
-- Unknown commands, object paths and properties are errors.
--
-- Usage: lua console.lua plans.lua   (exit 1 on any failure)

local plans = dofile(arg[1])
local failures, passes = 0, 0
local function check(ok, what)
  if ok then passes = passes + 1 else failures = failures + 1; print('  FAIL ' .. what) end
end

-- Objects -------------------------------------------------------------------------------------

local known = { name = true, note = true, no = true, object = true, target = true, rawtime = true, token = true, cuedestination = true }
local Obj = {}
local W -- the world (console state)

local function new(class, props)
  local o = { class = class, props = props or {}, kids = {}, pending = {} }
  return setmetatable(o, Obj)
end

-- The mock's own bookkeeping; anything else on a handle is a mistake in the export.
local internal = { content = true, parent = true, wantsRange = true, pending = true, kids = true }
Obj.__index = function(o, k)
  local m = rawget(Obj, k)
  if m then return m end
  if internal[k] then return nil end
  local lk = string.lower(k)
  if not known[lk] then error('unknown property ' .. k .. ' on ' .. o.class, 2) end
  return o.props[lk]
end
Obj.__newindex = function(o, k, v)
  if not internal[k] then error('assigning field ' .. tostring(k) .. ' on a handle', 2) end
  rawset(o, k, v)
end

function Obj.GetClass(o) return o.class end
function Obj.Children(o)
  local t = {}
  for i, c in ipairs(o.kids) do t[i] = c end
  return t
end
function Obj.Set(o, k, v)
  local lk = string.lower(k)
  if not known[lk] then error('unknown property ' .. k .. ' set on ' .. o.class, 2) end
  o.props[lk] = v
end
local allowed = { Timecode = { TrackGroup = true }, TrackGroup = { Track = true }, Track = {}, TimeRange = { CmdSubTrack = true },
                  CmdSubTrack = { CmdEvent = true } }
function Obj.Append(o, class)
  if not (allowed[o.class] and allowed[o.class][class]) then error('cannot append ' .. class .. ' to ' .. o.class, 2) end
  local c = new(class)
  c.parent = o
  -- Structure appears on a later frame; events and subtracks at once.
  if class == 'TrackGroup' or class == 'Track' then table.insert(o.pending, c) else table.insert(o.kids, c) end
  return c
end

-- One console frame: pending children appear; new groups and tracks grow their defaults.
local function frame()
  local function walk(o)
    local grown = {}
    for _, c in ipairs(o.pending) do table.insert(o.kids, c); table.insert(grown, c) end
    o.pending = {}
    for _, c in ipairs(grown) do
      if c.class == 'TrackGroup' then table.insert(c.pending, new('Track')) end
      if c.class == 'Track' then c.wantsRange = true end
    end
    for _, c in ipairs(o.kids) do
      if c.wantsRange then c.wantsRange = nil; table.insert(c.kids, new('TimeRange')) end
      walk(c)
    end
  end
  for _, t in pairs(W.tc) do walk(t) end
end
local function pause() for _ = 1, 4 do frame() end end

-- The console --------------------------------------------------------------------------------

local function violation(msg) table.insert(W.violations, msg) end
local function fail(msg) table.insert(W.errors, msg); error(msg, 3) end

local function newWorld()
  W = { seq = {}, tc = {}, page = {}, log = {}, printed = {}, violations = {}, errors = {} }
end

local function seq(n, name, cues)
  local s = new('Sequence', { name = name, no = n })
  for i, c in ipairs(cues or {}) do
    local cue = new('Cue', { no = i, name = c.name })
    cue.content = c.content
    table.insert(s.kids, cue)
  end
  W.seq[n] = s
  return s
end
local function page(p, name)
  W.page[p] = { obj = new('Page', { name = name, no = p }), exec = {} }
  return W.page[p]
end
local function assign(p, e, s) W.page[p].exec[e] = s end
local function findCue(s, m)
  for _, c in ipairs(s.kids) do if c.props.no == m then return c end end
end

function ObjectList(path)
  local n, m = path:match('^Sequence (%d+) Cue (%d+)$')
  if n then
    local s = W.seq[tonumber(n)]
    return { s and findCue(s, tonumber(m)) or nil }
  end
  n = path:match('^Sequence (%d+)$')
  if n then return { W.seq[tonumber(n)] } end
  n = path:match('^Timecode (%d+)$')
  if n then return { W.tc[tonumber(n)] } end
  local p, e = path:match('^Page (%d+)%.(%d+)$')
  if p then
    local pg = W.page[tonumber(p)]
    if not pg then return {} end
    return { new('Exec', { object = pg.exec[tonumber(e)], no = tonumber(e) }) }
  end
  p = path:match('^Page (%d+)$')
  if p then return { W.page[tonumber(p)] and W.page[tonumber(p)].obj } end
  fail('unknown object path: ' .. path)
end

function Cmd(c)
  table.insert(W.log, c)
  local n, m
  n = c:match('^Store Page (%d+) /NoConfirmation$')
  if n then
    n = tonumber(n)
    if W.page[n] then violation('stored over Page ' .. n) else page(n, 'Page ' .. n) end
    return
  end
  n, m = c:match('^Store Sequence (%d+) Cue (%d+) /NoConfirmation$')
  if n then
    local s = W.seq[tonumber(n)] or seq(tonumber(n), 'Sequence ' .. n)
    if findCue(s, tonumber(m)) then violation('stored over Sequence ' .. n .. ' Cue ' .. m) return end
    local cue = new('Cue', { no = tonumber(m), name = 'Cue ' .. m })
    cue.content = W.programmer
    table.insert(s.kids, cue)
    table.sort(s.kids, function(a, b) return a.props.no < b.props.no end)
    return
  end
  n = c:match('^Store Sequence (%d+) /NoConfirmation$')
  if n then
    if W.seq[tonumber(n)] then violation('stored over Sequence ' .. n) else seq(tonumber(n), 'Sequence ' .. n) end
    return
  end
  n, m = c:match('^Copy Sequence (%d+) At Sequence (%d+) /NoConfirmation$')
  if n then
    local from, to = W.seq[tonumber(n)], tonumber(m)
    if not from then fail('copy of missing Sequence ' .. n) end
    if W.seq[to] then violation('copied onto taken Sequence ' .. to) return end
    local cues = {}
    for _, k in ipairs(from.kids) do table.insert(cues, { name = k.props.name, content = k.content }) end
    seq(to, from.props.name, cues).props.note = from.props.note
    return
  end
  n = c:match('^Delete Sequence (%d+) Cue 1 Thru /NoConfirmation$')
  if n then
    local s = W.seq[tonumber(n)]
    local keep = {}
    for _, k in ipairs(s.kids) do if k.props.no < 1 then table.insert(keep, k) end end
    s.kids = keep
    return
  end
  n = c:match('^Delete Timecode (%d+) /NoConfirmation$')
  if n then W.tc[tonumber(n)] = nil return end
  n = c:match('^Store Timecode (%d+) /NoConfirmation$')
  if n then
    if W.tc[tonumber(n)] then violation('stored over Timecode ' .. n) else W.tc[tonumber(n)] = new('Timecode', { name = 'Timecode ' .. n, no = tonumber(n) }) end
    return
  end
  local s, p, e = c:match('^Assign Sequence (%d+) At Page (%d+)%.(%d+) /NoConfirmation$')
  if s then
    local pg = W.page[tonumber(p)]
    if not pg then fail('assign to missing Page ' .. p) end
    local cur = pg.exec[tonumber(e)]
    if cur and cur ~= W.seq[tonumber(s)] then violation('assigned over Page ' .. p .. '.' .. e) return end
    pg.exec[tonumber(e)] = W.seq[tonumber(s)]
    return
  end
  fail('unknown command: ' .. c)
end

function Printf(fmt, ...) table.insert(W.printed, string.format(fmt, ...)) end

-- Running the export --------------------------------------------------------------------------

local function runSteps(steps)
  for i, line in ipairs(steps) do
    local body = line:match('^Lua "(.*)"$')
    if not body or body:find('"', 1, true) then fail('step ' .. i .. ' is not one Lua "…" line') end
    local chunk, err = load(body, 'step ' .. i, 't')
    if not chunk then fail('step ' .. i .. ' does not compile: ' .. err) end
    local ok, e = pcall(chunk)
    if not ok then fail('step ' .. i .. ' failed: ' .. tostring(e)) end
    pause()
  end
end

local function runPlugin(src)
  local chunk, err = load(src, 'plugin', 't')
  if not chunk then fail('plugin does not compile: ' .. err) end
  local co = coroutine.create(chunk())
  while true do
    local ok, e = coroutine.resume(co)
    if not ok then fail('plugin failed: ' .. tostring(e)) end
    if coroutine.status(co) == 'dead' then break end
    pause()
  end
end

-- What the console holds, as text, for comparing runs.
local function dump()
  local out = {}
  local function add(s) table.insert(out, s) end
  local function keys(t) local k = {} for n in pairs(t) do table.insert(k, n) end table.sort(k) return k end
  for _, p in ipairs(keys(W.page)) do
    add('Page ' .. p .. ' ' .. tostring(W.page[p].obj.props.name))
    for _, e in ipairs(keys(W.page[p].exec)) do add('  ' .. p .. '.' .. e .. ' = Sequence ' .. W.page[p].exec[e].props.no) end
  end
  for _, n in ipairs(keys(W.seq)) do
    local s = W.seq[n]
    add('Sequence ' .. n .. ' ' .. tostring(s.props.name) .. ' [' .. tostring(s.props.note) .. ']')
    for _, c in ipairs(s.kids) do add('  Cue ' .. c.props.no .. ' ' .. tostring(c.props.name) .. ' {' .. tostring(c.content) .. '}') end
  end
  for _, n in ipairs(keys(W.tc)) do
    local t = W.tc[n]
    add('Timecode ' .. n .. ' ' .. tostring(t.props.name))
    for _, g in ipairs(t.kids) do
      add('  TrackGroup')
      for _, tr in ipairs(g.kids) do
        add('    Track ' .. tostring(tr.props.name) .. ' -> ' .. (tr.props.target and ('Sequence ' .. tr.props.target.props.no) or 'none'))
        for _, r in ipairs(tr.kids) do
          for _, st in ipairs(r.kids) do
            for _, ev in ipairs(st.kids) do
              local d = ev.props.cuedestination
              add('      ' .. ev.props.token .. ' @' .. ev.props.rawtime .. ' -> ' .. (d and ('Cue ' .. d.props.no) or 'nil'))
            end
          end
        end
      end
    end
  end
  return table.concat(out, '\n')
end

-- Helpers for the checks.
local function cueNames(n)
  local t = {}
  for _, c in ipairs(W.seq[n] and W.seq[n].kids or {}) do table.insert(t, c.props.name) end
  return table.concat(t, ' | ')
end
local function contents(n)
  local t = {}
  for _, c in ipairs(W.seq[n].kids) do table.insert(t, tostring(c.content)) end
  return table.concat(t, ',')
end
local function tracks(n)
  local t = {}
  local tc = W.tc[n]
  if not tc or not tc.kids[1] then return t end
  for _, tr in ipairs(tc.kids[1].kids) do
    local evs = {}
    for _, r in ipairs(tr.kids) do for _, st in ipairs(r.kids) do for _, ev in ipairs(st.kids) do
      table.insert(evs, { raw = ev.props.rawtime, cue = ev.props.cuedestination and ev.props.cuedestination.props.no,
                          token = ev.props.token, dest = ev.props.cuedestination })
    end end end
    table.insert(t, { target = tr.props.target and tr.props.target.props.no, events = evs })
  end
  return t
end
local function exec(p, e) local pg = W.page[p] return pg and pg.exec[e] and pg.exec[e].props.no end
local function printed(s) for _, l in ipairs(W.printed) do if l:find(s, 1, true) then return true end end return false end
local function raw(sec) return math.floor((sec - 1 / 30) * plans.override.rawPerSecond + 0.5) end
local function near(a, b) return a and math.abs(a - b) <= 1 end
local function clean(name)
  check(#W.violations == 0, name .. ': no violations (' .. table.concat(W.violations, '; ') .. ')')
  check(#W.errors == 0, name .. ': no errors (' .. table.concat(W.errors, '; ') .. ')')
end
local function scenario(name, f)
  print(name)
  newWorld()
  local ok, e = pcall(f)
  if not ok then failures = failures + 1; print('  FAIL ' .. tostring(e)) end
end

-- Scenarios -----------------------------------------------------------------------------------

local function freshOverride(name)
  check(W.page[3] and W.page[3].obj.props.name == "ALL'S WELL", name .. ': page 3 made and named')
  check(W.page[4] and W.page[4].obj.props.name == 'BONES', name .. ': page 4 made and named')
  check(exec(3, 201) == 4225 and exec(3, 202) == 4229 and exec(4, 201) == 4245, name .. ': executors assigned')
  check(W.seq[4250] and not exec(4, 203), name .. ': pyro sequence made, not assigned')
  check(W.seq[4225].props.note == 'Made by Understudy', name .. ': sequences noted as Understudy\'s')
  check(cueNames(4225) == "01:00:24:16 Choreo – Verse one | 01:00:30:00 Choreo – It's on", name .. ': cue names (' .. cueNames(4225) .. ')')
  local t15 = tracks(15)
  check(#t15 == 2 and t15[1].target == 4225 and t15[2].target == 4229, name .. ': Timecode 15 tracks target the song\'s sequences')
  check(#t15[1].events == 2 and t15[1].events[1].cue == 1 and t15[1].events[2].cue == 2 and t15[1].events[1].token == 'Goto',
        name .. ': Goto events at cues 1 and 2')
  check(t15[1].events[2].dest == W.seq[4225].kids[2], name .. ': event points at the cue object')
  check(near(t15[1].events[1].raw, raw(3624 + 16 / 30)) and near(t15[1].events[2].raw, raw(3630)), name .. ': raw times, one frame early')
  local t16 = tracks(16)
  check(#t16 == 2 and t16[1].target == 4245 and t16[2].target == 4250 and W.tc[16].props.name == 'BONES', name .. ': Timecode 16 for BONES')
  check(#W.tc[15].kids == 1, name .. ': one track group')
end

scenario('empty console, over OSC', function()
  runSteps(plans.override.steps)
  clean('osc')
  freshOverride('osc')
  check(W.seq[4251] == nil, 'osc: nothing to back up on a fresh console')
end)

local oscState
scenario('plugin builds the same as OSC', function()
  runSteps(plans.override.steps)
  oscState = dump()
  newWorld()
  runPlugin(plans.override.plugin)
  clean('plugin')
  freshOverride('plugin')
  check(dump() == oscState, 'plugin: same console state as OSC')
  check(printed('2 markers sent') == false and printed('markers sent'), 'plugin: says it finished')
end)

scenario('sending twice', function()
  runSteps(plans.override.steps)
  runSteps(plans.override.steps)
  clean('twice')
  check(cueNames(4225) == "01:00:24:16 Choreo – Verse one | 01:00:30:00 Choreo – It's on" and #W.seq[4229].kids == 1, 'twice: no duplicate cues')
  -- Override backs its sequences up each time, above the export's numbers.
  check(W.seq[4251] and W.seq[4251].props.name == "ALL'S WELL · Choreo (before Understudy)", 'twice: override backed up 4225 to 4251')
  check(W.seq[4252] and W.seq[4252].props.note == 'Backup by Understudy', 'twice: and 4245 to 4252, noted as a backup')
  local t15 = tracks(15)
  check(#t15 == 2 and #t15[1].events == 2 and #t15[2].events == 1, 'twice: timecode show rebuilt, not doubled')
  -- A third send must not treat the backups as its own.
  runSteps(plans.override.steps)
  clean('third')
  check(W.seq[4253] and W.seq[4254] and cueNames(4251) == "01:00:24:16 Choreo – Verse one | 01:00:30:00 Choreo – It's on",
        'third: new backups, old backups untouched')
end)

scenario('a console with someone else\'s show on it', function()
  page(3, 'Old page')
  seq(500, 'Verse looks', { { name = 'Look A', content = 'A' }, { name = 'Look B', content = 'B' }, { name = 'Look C', content = 'C' } })
  assign(3, 201, W.seq[500])
  seq(4229, 'Kick drum', { { name = 'Kick', content = 'K' } })
  W.tc[16] = new('Timecode', { name = 'LD show', no = 16 })
  page(4, 'Strobes')
  seq(77, 'Strobe', { { name = 'Hit', content = 'S' } })
  assign(4, 202, W.seq[77])
  assign(4, 201, W.seq[77])
  local before77 = cueNames(77) .. contents(77)
  runSteps(plans.override.steps)
  clean('foreign')
  check(W.page[3].obj.props.name == 'Old page' and W.page[4].obj.props.name == 'Strobes', 'foreign: existing pages keep their names')
  check(W.seq[4229].props.name == 'Kick drum' and contents(4229) == 'K' and cueNames(4229) == 'Kick', 'foreign: taken pool slot untouched')
  check(printed('Sequence 4229 was not made by Understudy'), 'foreign: says so')
  check(exec(3, 202) == nil, 'foreign: no exec for a sequence it left alone')
  check(W.tc[16].props.name == 'LD show' and #W.tc[16].kids == 0 and printed('Timecode 16 was not made by Understudy'),
        'foreign: someone else\'s timecode show untouched')
  -- Override on the executor's sequence: backed up, then replaced.
  check(W.seq[4251] and W.seq[4251].props.name == 'Verse looks (before Understudy)' and contents(4251) == 'A,B,C',
        'foreign: exec 3.201 sequence backed up with its looks')
  check(exec(3, 201) == 500 and cueNames(500) == "01:00:24:16 Choreo – Verse one | 01:00:30:00 Choreo – It's on" and contents(500) == 'nil,nil',
        'foreign: its cues replaced in place')
  check(W.seq[500].props.name == 'Verse looks', 'foreign: its name kept')
  check(#tracks(15) == 1 and tracks(15)[1].target == 500, 'foreign: Timecode 15 fires the exec sequence only')
  -- BONES' choreo: exec 4.201 holds Strobe, so it uses Strobe (On exec) and backs it up.
  check(exec(4, 201) == 77 and exec(4, 202) == 77, 'foreign: executors still hold Strobe')
  check(cueNames(4252) .. contents(4252) == before77, 'foreign: Strobe backed up before override')
end)

scenario('an executor holding another sequence', function()
  page(3, 'Show')
  seq(88, 'Chase', { { name = 'Go', content = 'X' } })
  assign(3, 202, W.seq[88])
  runSteps(plans.override.steps)
  clean('taken exec')
  check(exec(3, 202) == 88 and printed('Page 3.202 holds Sequence 88, left alone'), 'taken exec: left on its sequence, and says so')
  check(W.seq[4229] and cueNames(4229) == '01:00:47:16 Lighting – Drop', 'taken exec: the lighting sequence is still made')
  check(cueNames(88) .. contents(88) == 'GoX', 'taken exec: its sequence untouched')
end)

scenario('merge into programmed cues on an executor', function()
  page(3, 'Show')
  seq(500, 'Verse looks', { { name = 'Big look', content = 'A' } })
  assign(3, 201, W.seq[500])
  W.programmer = nil
  runSteps(plans.merge.steps)
  clean('merge')
  check(cueNames(500) == "Big look | 01:00:30:00 Choreo – It's on" and contents(500) == 'A,nil', 'merge: existing cue kept, missing one added')
  check(W.seq[4251] == nil and W.seq[4246] == nil, 'merge: no backup')
  local t = tracks(15)
  check(t[1].target == 500 and t[1].events[1].dest == W.seq[500].kids[1], 'merge: marker 1 fires the existing cue 1')
  for _, c in ipairs(W.log) do check(not c:find('Delete Sequence', 1, true) and not c:find('Copy', 1, true), 'merge: no delete or copy (' .. c .. ')') end
end)

scenario('an older Understudy export is reused', function()
  seq(1001, 'Understudy · Spring', { { name = 'old 1' }, { name = 'old 2' } })
  W.tc[101] = new('Timecode', { name = 'Understudy · Spring', no = 101 })
  runSteps(plans.single.steps)
  clean('single')
  check(#W.seq[1001].kids == 5 and W.seq[1001].kids[3].props.name == '01:00:47:16 Lighting – Drop', 'single: merged into the old sequence')
  check(W.tc[101].props.name == 'Understudy · Summer' and #tracks(101) == 1 and #tracks(101)[1].events == 5, 'single: old timecode show rebuilt')
  check(next(W.page) == nil, 'single: no pages without a page setting')
end)

scenario('batches', function()
  runSteps(plans.batches.steps)
  clean('batches')
  check(#W.seq[2001].kids == 60 and #tracks(201)[1].events == 60, 'batches: 60 cues and 60 events')
end)

scenario('a stored programmer is noticed', function()
  W.programmer = 'P'
  runSteps(plans.batches.steps)
  check(contents(2001):find('P', 1, true) ~= nil, 'programmer: cues are stored from the programmer (documented: clear it first)')
end)

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
