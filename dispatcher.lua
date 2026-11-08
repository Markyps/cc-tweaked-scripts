-- Spatial Dispatcher v2.1. One shared physical cell for ALL endpoints.
local CFG = {NETWORK="spatial_main", STATE="spatial_dispatcher_v2_state", LOG="spatial_dispatcher_v2.log"}
local PROTOCOL = "spatial_hub_v2_1"


-- Shared helpers are embedded in both deliverables; no extra library is required.
local function copy(v)
  if type(v) ~= "table" then return v end
  local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
end
local function contains(t, x)
  for _, v in ipairs(t) do if v == x then return true end end
  return false
end
local function unique(t)
  local r = {}; for _, v in ipairs(t) do if not contains(r, v) then r[#r+1] = v end end
  return r
end
local function check(ok, why) if not ok then error(why, 0) end end
local function checksum(s)
  local a, b = 1, 0
  for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
  return b * 65536 + a
end
local function journal(path)
  local seq, chosen, seen, damaged = 0, nil, false, false
  for _, suffix in ipairs({".a", ".b"}) do
    if fs.exists(path .. suffix) then
      seen = true
      local ok, v = pcall(function()
        local f = assert(fs.open(path .. suffix, "r")); local raw = f.readAll(); f.close()
        local w = textutils.unserialize(raw)
        check(type(w) == "table" and type(w.seq) == "number" and type(w.payload) == "string", "Bad journal")
        check(w.sum == checksum(w.payload), "Journal checksum mismatch")
        local data = textutils.unserialize(w.payload); check(type(data) == "table", "Bad journal payload")
        return {seq=w.seq, data=data}
      end)
      if ok then if v.seq > seq then seq, chosen = v.seq, v.data end else damaged = true end
    end
  end
  check(not seen or chosen ~= nil, "Both state copies are unreadable: " .. path .. ". Do not reset an occupied cell.")
  local function save(data)
    local nextSeq = seq + 1
    local payload = textutils.serialize(data, {compact=true})
    local f, err = fs.open(path .. (nextSeq % 2 == 1 and ".a" or ".b"), "w")
    check(f ~= nil, "Cannot persist state: " .. tostring(err))
    f.write(textutils.serialize({seq=nextSeq, payload=payload, sum=checksum(payload)}, {compact=true})); f.close()
    seq = nextSeq
  end
  return chosen, save, damaged
end
local function logger(path)
  return function(message)
    -- Log failure must not prevent recovery; state-write failure DOES stop it.
    pcall(function()
      if fs.exists(path) and fs.getSize(path) > 131072 then
        if fs.exists(path .. ".old") then fs.delete(path .. ".old") end
        fs.move(path, path .. ".old")
      end
      local f = assert(fs.open(path, "a")); f.writeLine(tostring(os.epoch("utc")) .. " " .. message); f.close()
    end)
  end
end
local function openModems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then
      local ok = pcall(rednet.open, name); if ok then n = n + 1 end
    end
  end
  check(n > 0, "No usable modem. Connect an Ender Modem for interdimensional links.")
end
local function decode(raw)
  if type(raw) == "table" then return raw end
  if type(raw) ~= "string" or #raw > 32768 then return nil end
  local ok, v = pcall(textutils.unserialize, raw)
  if ok and type(v) == "table" then return v end
end
local function legacyGuard(path, hub)
  if not fs.exists(path) then return end
  local f = assert(fs.open(path, "r")); local raw = f.readAll(); f.close()
  local v = textutils.unserialize(raw)
  check(type(v) == "table", "Unreadable v1 state " .. path .. "; inspect the old operation first.")
  check(hub and v.phase == "IDLE" or not hub and not v.locked,
    "Unfinished v1 operation in " .. path .. ". Recover the player/cell with v1 before migration.")
end
local function upgradeHubState(state, network, hub, dispatcher)
  local identity = network .. ":" .. hub .. ":" .. dispatcher
  if not state then return identity end
  if state.layout == "single_cell_zone_v1" then
    check(state.identity == identity, "Endpoint identity changed; restore original settings")
  else
    local prefix, suffix = network .. ":", ":" .. hub .. ":" .. dispatcher
    local old = state.identity or ""
    check(old == identity or (old:sub(1,#prefix) == prefix and old:sub(-#suffix) == suffix), "Endpoint identity changed")
    check(not state.active and not state.request, "Finish the v2 operation before upgrading to v2.1")
    for _, j in pairs(state.ops or {}) do check(j.closed, "Unfinished v2 endpoint operation") end
  end
  return identity
end
local function upgradeDispatcherState(state)
  if state and state.layout ~= "single_cell_zone_v1" then
    for _, t in pairs(state.ops or {}) do
      check(t.phase == "CLOSED", "Finish all v2 operations before upgrading to v2.1")
      t.pool = nil -- Retire the old journal field only after the operation has ended.
    end
  end
end


local Dispatcher = {}
Dispatcher.__index = Dispatcher
local MUTATES = {FETCH=true, ACQUIRE=true, CAPTURE=true, OFFER=true, ACQUIRE_DEST=true, RELEASE=true, SETTLE=true}
function Dispatcher.new(io, state)
  local self = setmetatable({io=io, s=state or {version=2, counter=0, ops={}, requests={}, pins={}}, hubs={}, sent={}}, Dispatcher)
  check(self.s.version == 2, "Unsupported dispatcher state")
  return self
end
function Dispatcher:save() self.io.persist(self.s) end
function Dispatcher:emit(to, cmd, data) self.io.send(to, cmd, data or {}) end
function Dispatcher:locked(hub)
  for _, t in pairs(self.s.ops) do
    if t.phase ~= "CLOSED" then
      if t.phase ~= "CLOSING" then return true end -- The only physical cell is still in use.
      if contains(t.members, hub) and not (t.finished and t.finished[hub]) then return true end
    end
  end
  return false
end
function Dispatcher:fresh(id)
  local h = self.hubs[id]; return h and self.io.now() - h.seen < 20 and not h.conflict
end
function Dispatcher:reject(from, request, reason)
  self.s.requests[request] = {src=from, reason=reason, at=self.io.now()}; self:save()
  self:emit(from, "DENY", {request=request, reason=reason})
end
function Dispatcher:command(t, to, action)
  local k = t.op .. ":" .. to .. ":" .. action
  if self.sent[k] and self.io.now() - self.sent[k] < 2 then return end
  self.sent[k] = self.io.now()
  self:emit(to, "COMMAND", {op=t.op, request=t.request, action=action, src=t.src, dst=t.dst,
    holder=t.holder, player=t.player, outcome=t.outcome,
    expires=t.expires, reason=t.reason})
end
function Dispatcher:close(t, outcome)
  t.phase, t.outcome, t.finished = "CLOSING", outcome, {}
  t.closedAt = self.io.now(); self:save()
  self.io.log("op=" .. t.op .. " physical result=" .. outcome .. "; shared cell released, endpoint cleanup pending")
end
function Dispatcher:abort(t, reason)
  if t.phase ~= "RUNNING" then return end
  t.reason = tostring(reason)
  if next(t.mutated) == nil then self:close(t, "CANCELLED"); return end
  t.phase, t.fenced = "FENCING", {}
  t.required = copy(t.mutated); t.required[t.src] = true
  self:save(); self.io.log("op=" .. t.op .. " abort: " .. t.reason)
end
function Dispatcher:receive(sender, m)
  if type(m) ~= "table" or type(m.from) ~= "string" then return end
  local from = m.from
  if m.cmd == "HELLO" then
    if type(m.label) ~= "string" then return end
    if self.s.pins[from] and self.s.pins[from] ~= sender then
      if self.hubs[from] then self.hubs[from].conflict = true end
      self.io.log("Duplicate hub ID " .. from .. " from computer " .. tostring(sender)); return
    end
    if not self.s.pins[from] then self.s.pins[from] = sender; self:save() end
    self.hubs[from] = {seen=self.io.now(), sender=sender, label=m.label,
      cell=m.cell, busy=m.busy, occupied=m.occupied, fault=m.fault}
    return
  end
  if self.s.pins[from] ~= sender then return end
  if m.cmd == "REQUEST" then
    if type(m.request) ~= "string" or #m.request > 160 then return end
    local old = self.s.requests[m.request]
    if old then
      if old.src ~= from then return end
      if old.op then
        local t = self.s.ops[old.op]
        self:emit(from, "ACCEPTED", {request=m.request, op=old.op, outcome=t.outcome})
      else self:emit(from, "DENY", {request=m.request, reason=old.reason}) end
      return
    end
    local src, dst = self.hubs[from], self.hubs[m.dst]
    if type(m.player) ~= "string" or #m.player > 32 or type(m.expires) ~= "number" or m.expires < self.io.now() or m.expires > self.io.now()+40 then
      self:reject(from, m.request, "INVALID_OR_EXPIRED_REQUEST"); return
    end
    if from == m.dst or not self:fresh(from) or not self:fresh(m.dst) then
      self:reject(from, m.request, "ENDPOINT_OFFLINE"); return
    end
    if self:locked(from) or self:locked(m.dst) or src.busy or dst.busy or dst.occupied or src.fault or dst.fault then
      self:reject(from, m.request, "RESOURCE_BUSY"); return
    end
    local owners = {}
    for id, h in pairs(self.hubs) do
      if self:fresh(id) and h.cell == 1 then owners[#owners+1] = id end
      if self:fresh(id) and type(h.cell) == "number" and h.cell > 1 then
        self:reject(from, m.request, "MULTIPLE_SPATIAL_CELLS"); return
      end
    end
    if #owners ~= 1 then self:reject(from, m.request, #owners == 0 and "CELL_NOT_LOCATED" or "MULTIPLE_SPATIAL_CELLS"); return end
    local holder = self.hubs[owners[1]]
    if holder.busy or holder.fault or self:locked(owners[1]) then self:reject(from, m.request, "CELL_HOLDER_BUSY"); return end
    self.s.counter = self.s.counter + 1
    local t = {op=tostring(self.io.id) .. ":" .. self.s.counter, request=m.request, src=from, dst=m.dst,
      player=m.player, holder=owners[1], phase="RUNNING", index=1, mutated={},
      expires=self.io.now()+300, started=self.io.now(), stepAt=self.io.now()}
    t.members = unique({t.src, t.dst, t.holder}); t.plan = {}
    for _, id in ipairs(t.members) do t.plan[#t.plan+1] = {to=id, action="RESERVE"} end
    if t.holder ~= t.src then t.plan[#t.plan+1] = {to=t.holder, action="FETCH"} end
    for _, a in ipairs({"ACQUIRE", "CAPTURE", "OFFER"}) do t.plan[#t.plan+1] = {to=t.src, action=a} end
    for _, a in ipairs({"ACQUIRE_DEST", "RELEASE", "SETTLE"}) do t.plan[#t.plan+1] = {to=t.dst, action=a} end
    self.s.ops[t.op] = t; self.s.requests[m.request] = {src=from, op=t.op, at=self.io.now()}; self:save()
    self:emit(from, "ACCEPTED", {request=m.request, op=t.op}); return
  end
  if m.cmd == "CANCEL_REQUEST" then
    if type(m.request) ~= "string" then return end
    local r = self.s.requests[m.request]
    if not r then self:reject(from, m.request, "CANCELLED"); return end
    if r.src ~= from then return end
    if r.op then self:abort(self.s.ops[r.op], "Source cancelled") end
    self:emit(from, "CANCEL_ACK", {request=m.request}); return
  end
  if m.cmd ~= "RESULT" or type(m.op) ~= "string" then return end
  local t = self.s.ops[m.op]
  if not t or not contains(t.members, from) or t.phase == "CLOSED" then return end
  if not m.ok and t.phase ~= "RUNNING" then
    local err = tostring(m.action) .. " @ " .. from .. ": " .. tostring(m.error)
    if t.recoveryError ~= err then t.recoveryError=err; self:save(); self.io.log("op=" .. t.op .. " recovery waiting: " .. err) end
  end
  if t.phase == "RUNNING" then
    local p = t.plan[t.index]
    if p.to ~= from or p.action ~= m.action then return end
    if not m.ok then self:abort(t, m.error or "Endpoint failure"); return end
    t.index, t.stepAt = t.index + 1, self.io.now()
    if t.index > #t.plan then self:close(t, "DONE") else self:save() end
  elseif t.phase == "FENCING" and m.action == "FENCE" and t.required[from] then
    if m.ok and type(m.data) == "table" and not m.data.uncertain then
      t.fenced[from] = m.data; self:save()
    end
  elseif t.phase == "REPATRIATING" and m.action == "REPATRIATE" and t.returners[t.returnIndex] == from then
    if m.ok then t.returnIndex = t.returnIndex + 1; self:save() end
  elseif t.phase == "RESTORING" and m.action == "RESTORE" and from == t.src then
    if m.ok then
      self:close(t, t.fenced[t.src].captured and "ROLLED_BACK" or "CANCELLED")
    end
  elseif t.phase == "SETTLING" and m.action == "SETTLE" and from == t.dst then
    if m.ok then self:close(t, "DONE") end
  elseif t.phase == "CLOSING" and m.action == "FINISH" and m.ok then
    t.finished[from] = true
    local all = true; for _, id in ipairs(t.members) do if not t.finished[id] then all = false end end
    if all then t.phase = "CLOSED" end
    self:save()
  end
end
function Dispatcher:tick()
  if not self.compactAt or self.io.now()-self.compactAt >= 60 then
    self.compactAt = self.io.now()
    local closed, changed = {}, false
    for op,t in pairs(self.s.ops) do if t.phase == "CLOSED" then closed[#closed+1]={op=op,at=t.closedAt} end end
    table.sort(closed,function(a,b) return a.at>b.at end)
    for i=65,#closed do
      local v=closed[i]
      if self.io.now()-v.at > 360 then
        local t=self.s.ops[v.op]; self.s.requests[t.request]=nil; self.s.ops[v.op]=nil; changed=true
        for key in pairs(self.sent) do if key:sub(1,#v.op+1)==v.op..":" then self.sent[key]=nil end end
      end
    end
    for request,r in pairs(self.s.requests) do
      if not r.op and self.io.now()-(r.at or self.io.now())>60 then self.s.requests[request]=nil; changed=true end
    end
    if changed then self:save() end
  end
  for _, t in pairs(self.s.ops) do
    if t.phase == "RUNNING" then
      local p = t.plan[t.index]
      local timeout = (p.action == "SETTLE" and 65 or 25)
      if self.io.now() - t.stepAt > timeout or self.io.now() > t.expires then
        self:abort(t, "Timeout: " .. p.action .. " @ " .. p.to)
      else
        if MUTATES[p.action] and not t.mutated[p.to] then t.mutated[p.to] = true; self:save() end
        self:command(t, p.to, p.action)
      end
    elseif t.phase == "FENCING" then
      local all = true
      for id in pairs(t.required) do
        if not t.fenced[id] then all = false; self:command(t, id, "FENCE") end
      end
      if all then
        local dest = t.fenced[t.dst]
        if dest and dest.released then t.phase = "SETTLING"
        else
          t.phase, t.returners, t.returnIndex = "REPATRIATING", {}, 1
          for _, id in ipairs(t.members) do if id ~= t.src and t.mutated[id] then t.returners[#t.returners+1] = id end end
        end
        self:save()
      end
    elseif t.phase == "REPATRIATING" then
      local id = t.returners[t.returnIndex]
      if id then self:command(t, id, "REPATRIATE") else t.phase = "RESTORING"; self:save() end
    elseif t.phase == "RESTORING" then self:command(t, t.src, "RESTORE")
    elseif t.phase == "SETTLING" then self:command(t, t.dst, "SETTLE")
    elseif t.phase == "CLOSING" then
      for _, id in ipairs(t.members) do if not t.finished[id] then self:command(t, id, "FINISH") end end
    end
  end
end


if _G.SPATIAL_TEST then return {Dispatcher=Dispatcher, journal=journal, checksum=checksum} end
local log = logger(CFG.LOG)
local state, persist, damaged = journal(CFG.STATE)
if not state then legacyGuard("dispatcher_state.txt", false) end
local id = os.getComputerID()
if state then check(state.identity == CFG.NETWORK .. ":" .. id, "Dispatcher identity changed; keep original ID and NETWORK") end
upgradeDispatcherState(state)
local d
local function send(to, cmd, data)
  local m = copy(data); m.cmd, m.from, m.to, m.network = cmd, "dispatcher", to, CFG.NETWORK
  local target = d and d.s.pins[to]
  if target then
    local ok, result = pcall(rednet.send, target, m, PROTOCOL)
    if not ok or not result then log("TX unavailable: " .. cmd .. " -> " .. to .. " " .. tostring(result)) end
  end
end
d = Dispatcher.new({id=id, now=function() return os.epoch("utc")/1000 end,
  persist=persist, send=send, log=log}, state)
d.s.identity = CFG.NETWORK .. ":" .. id; d.s.layout = "single_cell_zone_v1"; d:save()
if damaged then log("Recovered previous valid journal generation; reconciling operations") end
openModems()
local lastList, lastDisplay = -100, -100
local function show()
  term.setCursorPos(1,1); term.clear()
  print("Spatial dispatcher v2.1 | ID " .. id)
  print("Network: " .. CFG.NETWORK)
  local total = 0
  for _, t in pairs(d.s.ops) do
    if t.phase ~= "CLOSED" then
      total = total + 1
      print(t.op .. " " .. t.phase)
      print("  " .. t.src .. " -> " .. t.dst .. " / " .. t.player)
      if t.reason then print("  " .. t.reason) end
      if t.recoveryError then print("  " .. t.recoveryError) end
    end
  end
  if total == 0 then print("Ready. No active operations.") end
  print("State: " .. CFG.STATE .. ".a/.b")
end
while true do
  local sender, raw = rednet.receive(PROTOCOL, 0.25)
  local m = decode(raw)
  if m and m.network == CFG.NETWORK and m.to == "dispatcher" then d:receive(sender, m) end
  d:tick()
  local now = os.clock()
  if now-lastList >= 3 then
    pcall(openModems) -- Reopen a modem reattached while the dispatcher was running.
    local list = {}
    for hub, h in pairs(d.hubs) do
      if d:fresh(hub) then list[#list+1] = {id=hub,label=h.label,busy=h.busy,occupied=h.occupied,fault=h.fault} end
    end
    table.sort(list, function(a,b) return a.label:lower() < b.label:lower() end)
    for hub in pairs(d.hubs) do if d:fresh(hub) then send(hub, "HUB_LIST", {hubs=list}) end end
    lastList = now
  end
  if now-lastDisplay >= 1 then show(); lastDisplay = now end
end
