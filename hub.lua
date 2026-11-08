-- Spatial Hub v2. All endpoints AND the dispatcher must use v2 together.
-- Edit this block for EACH endpoint. See README_RU.md before the first run.
local CFG = {
  CONFIGURED = false,
  HUB_ID = "earth", HUB_LABEL = "Earth Hub",
  DISPATCHER_ID = -1, -- Computer ID printed on the dispatcher computer (NOT HUB_ID).
  NETWORK = "spatial_main", POOL = "shared_cell_1",
  DIMENSION = "minecraft:overworld", SPATIAL_DIMENSION = "ae2:spatial_storage",
  ZONE_MIN = {x=363, y=66, z=-4006}, ZONE_MAX = {x=366, y=69, z=-4003},
  CELL = "ae2:spatial_storage_cell_16",
  PORT_NAME = "", VAULT_NAME = "", RELAY_NAME = "", DETECTOR_NAME = "", MONITOR_NAME = "",
  RELAY_SIDE = "back", -- ONLY the side connected to THIS spatial port. Never all six sides.
  MANAGER_SIDE = "up", -- Vault direction relative to each player's Inventory Manager.
  PULSE_SECONDS = 0.2,
  STATE = "spatial_hub_v2_state", LOG = "spatial_hub_v2.log",
}
local PROTOCOL = "spatial_hub_v2"


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


local Hub = {}; Hub.__index = Hub
local NORMAL = {RESERVE=true, FETCH=true, ACQUIRE=true, CAPTURE=true, OFFER=true, ACQUIRE_DEST=true, RELEASE=true}
function Hub.new(io, state)
  local self = setmetatable({io=io, s=state or {version=2, ops={}, counter=0}}, Hub)
  check(self.s.version == 2, "Unsupported endpoint state"); return self
end
function Hub:save() self.io.persist(self.s) end
function Hub:compact()
  local list={}
  for op,j in pairs(self.s.ops) do
    if j.closed then list[#list+1]={op=op,seq=tonumber(op:match(":(%d+)$")) or 0} end
  end
  table.sort(list,function(a,b) return a.seq>b.seq end)
  for i=33,#list do self.s.ops[list[i].op]=nil end
end
function Hub:result(m, ok, data, err)
  self.io.send("RESULT", {op=m.op, action=m.action, ok=ok, data=data, error=err})
end
function Hub:request(player, dst)
  if self.s.active or self.s.request then return end
  self.s.counter = self.s.counter + 1
  self.s.request = {request=self.io.id .. ":" .. self.s.counter, player=player, dst=dst, expires=self.io.now()+35}
  self:save()
end
function Hub:control(m)
  local r = self.s.request
  if not r or m.request ~= r.request then return end
  if m.cmd == "ACCEPTED" then r.op = m.op; if m.outcome then self.s.request = nil end
  elseif m.cmd == "DENY" or m.cmd == "CANCEL_ACK" then self.s.request = nil
  else return end
  self:save()
end
function Hub:command(m)
  if type(m.op) ~= "string" or type(m.action) ~= "string" or type(m.player) ~= "string" then return end
  if m.pool ~= self.io.pool or not contains({m.src, m.dst, m.holder}, self.io.id) then return end
  local j = self.s.ops[m.op]
  local sequence = tonumber(m.op:match(":(%d+)$"))
  if not sequence then return end
  if not j and sequence <= (self.s.closedThrough or 0) then
    -- Durable high-water mark rejects old commands even after detailed tombstones are compacted.
    self:result(m, m.action == "FINISH", {}, m.action ~= "FINISH" and "STALE_OPERATION" or nil); return
  end
  if j and (j.src ~= m.src or j.dst ~= m.dst or j.player ~= m.player or j.holder ~= m.holder) then return end
  if j and j.closed then
    local old = j.results[m.action]
    if old then self:result(m, old.ok, old.data, old.error)
    elseif m.action == "FINISH" then self:result(m, true, {outcome=j.closed})
    else self:result(m, false, nil, "CLOSED_OPERATION") end
    return
  end
  if NORMAL[m.action] and (type(m.expires) ~= "number" or self.io.now() > m.expires) then
    self:result(m, false, nil, "EXPIRED_COMMAND"); return
  end
  if self.s.active and self.s.active ~= m.op then
    -- A late FINISH for an untouched reservation may write its tombstone without disturbing another operation.
    if m.action == "FINISH" and not j then
      self.s.ops[m.op] = {src=m.src,dst=m.dst,player=m.player,holder=m.holder,results={},closed=m.outcome or "CANCELLED"}
      self.s.closedThrough = math.max(self.s.closedThrough or 0, sequence); self:compact()
      self:save(); self:result(m, true, {}); return
    end
    self:result(m, false, nil, "HUB_BUSY"); return
  end
  if not j then
    if m.action ~= "RESERVE" and m.action ~= "FENCE" and m.action ~= "FINISH" then
      self:result(m, false, nil, "NO_RESERVATION"); return
    end
    j = {src=m.src,dst=m.dst,player=m.player,holder=m.holder,results={},pulses={}}
    self.s.ops[m.op], self.s.active = j, m.op; self:save()
  end
  if self.s.request and self.s.request.request == m.request then self.s.request = nil; self:save() end
  if j.cancelled and NORMAL[m.action] then self:result(m, false, nil, "FENCED_OPERATION"); return end
  -- SETTLE is retried after temporary detection failures. Recovery commands are always retryable.
  local cached = j.results[m.action]
  if cached and m.action ~= "FENCE" and (cached.ok or NORMAL[m.action]) then
    self:result(m, cached.ok, cached.data, cached.error); return
  end
  local function commit() self:save() end
  local hw = self.io.hw
  local ok, data = pcall(function()
    if m.action == "RESERVE" then
      hw.reserve(j, self.io.id); j.reserved = true; commit(); return {}
    elseif m.action == "FENCE" then
      j.cancelled = true; commit(); hw.reconcile(j, commit)
      return {captured=j.captured or false, released=j.released or false, uncertain=hw.uncertain(j)}
    elseif m.action == "FINISH" then
      check(not hw.uncertain(j), "UNRESOLVED_PULSE")
      j.closed, j.cancelled = m.outcome or "CANCELLED", true
      self.s.closedThrough = math.max(self.s.closedThrough or 0, sequence)
      if self.s.active == m.op then self.s.active = nil end
      if self.io.id == j.src or self.io.id == j.dst then self.s.waitExit = j.player end
      self:compact(); commit(); return {outcome=j.closed}
    end
    check(j.reserved, "NOT_RESERVED")
    if m.action == "FETCH" then
      check(self.io.id == j.holder and not j.cancelled, "BAD_FETCH_ROLE")
      hw.give(j, commit); return {}
    elseif m.action == "ACQUIRE" then
      check(self.io.id == j.src, "BAD_SOURCE_ROLE")
      hw.acquire(j, commit, false); return {}
    elseif m.action == "CAPTURE" then
      check(self.io.id == j.src and j.results.ACQUIRE and j.results.ACQUIRE.ok, "ACQUIRE_REQUIRED")
      hw.pulse(j, "capture", commit); return {}
    elseif m.action == "OFFER" then
      check(self.io.id == j.src and j.captured, "CAPTURE_REQUIRED")
      hw.give(j, commit); return {}
    elseif m.action == "ACQUIRE_DEST" then
      check(self.io.id == j.dst, "BAD_DESTINATION_ROLE")
      hw.acquire(j, commit, true); return {}
    elseif m.action == "RELEASE" then
      check(self.io.id == j.dst and j.results.ACQUIRE_DEST and j.results.ACQUIRE_DEST.ok, "DEST_ACQUIRE_REQUIRED")
      hw.pulse(j, "release", commit); return {}
    elseif m.action == "SETTLE" then
      check(self.io.id == j.dst and j.released, "RELEASE_REQUIRED")
      hw.settle(j, commit); return {}
    elseif m.action == "REPATRIATE" then
      check(j.cancelled and not j.released and not hw.uncertain(j), "FENCE_REQUIRED")
      hw.repatriate(j, commit); return {}
    elseif m.action == "RESTORE" then
      hw.reconcile(j, commit)
      check(self.io.id == j.src and j.cancelled and not hw.uncertain(j), "FENCE_REQUIRED")
      return hw.restore(j, commit)
    end
    error("UNKNOWN_ACTION", 0)
  end)
  -- A failed disk write is fatal, never convert it into an ordinary hardware error.
  if self.io.persistFailed and self.io.persistFailed() then error(data, 0) end
  local result = {ok=ok, data=ok and data or nil, error=not ok and tostring(data) or nil}
  j.lastAction = m.action
  if not ok then j.lastError = tostring(data) end
  if m.action ~= "FENCE" then j.results[m.action] = result; self:save() end
  self.io.log("op=" .. m.op .. " action=" .. m.action .. " ok=" .. tostring(ok) .. (ok and "" or " error=" .. tostring(data)))
  self:result(m, result.ok, result.data, result.error)
end


local function hardware(cfg, log)
  local H = {}
  local sides = {left=true,right=true,top=true,bottom=true,front=true,back=true}
  local function methods(name, list)
    if not peripheral.isPresent(name) then return false end
    local have = {}; for _, x in ipairs(peripheral.getMethods(name) or {}) do have[x] = true end
    for _, x in ipairs(list) do if not have[x] then return false end end; return true
  end
  local function find(explicit, required, tag)
    if explicit and explicit ~= "" then check(methods(explicit, required), "Bad peripheral: " .. explicit); return explicit end
    local wired, direct = {}, {}
    for _, name in ipairs(peripheral.getNames()) do
      local types = {peripheral.getType(name)}; local match = not tag
      for _, t in ipairs(types) do if type(t) == "string" and t:find(tag or "", 1, true) then match = true end end
      if tag and name:find(tag, 1, true) then match = true end
      if match and methods(name, required) then
        local target = sides[name] and direct or wired; target[#target+1] = name
      end
    end
    local matches = #wired > 0 and wired or direct
    check(#matches == 1, "Set peripheral name explicitly (" .. tostring(tag or required[1]) .. "): " .. table.concat(matches, ","))
    return matches[1]
  end
  local portName = find(cfg.PORT_NAME, {"list","pushItems"}, "spatial_io")
  local vaultName = find(cfg.VAULT_NAME, {"list","pushItems"}, "item_vault")
  check(portName ~= vaultName, "Port and vault must be different inventories")
  local relayName = find(cfg.RELAY_NAME, {"setOutput","getOutput"})
  local detectorName = find(cfg.DETECTOR_NAME, {"getPlayersInCoords","getPlayerPos"})
  local monitorName = find(cfg.MONITOR_NAME, {"getSize","write","setCursorPos","clear"})
  check(sides[cfg.RELAY_SIDE], "RELAY_SIDE must be one of the six CC sides")
  local port, vault = peripheral.wrap(portName), peripheral.wrap(vaultName)
  local relay, detector = peripheral.wrap(relayName), peripheral.wrap(detectorName)
  H.monitor, H.monitorName = peripheral.wrap(monitorName), monitorName
  H.names = {port=portName,vault=vaultName,relay=relayName,detector=detectorName,monitor=monitorName}
  function H.low() relay.setOutput(cfg.RELAY_SIDE, false) end
  local function cells(inv)
    local items = inv.list(); check(type(items) == "table", "Inventory unavailable")
    local count, slot, item = 0
    for k, v in pairs(items) do
      if v.name == cfg.CELL then count = count + v.count; slot = tonumber(k); item = v end
    end
    check(count <= 1, "More than one spatial cell in inventory")
    return count, slot, item, items
  end
  function H.localCell()
    local a = cells(port); local b = cells(vault)
    check(a+b <= 1, "Multiple local spatial cells; use one cell per pool")
    return a+b
  end
  local function inputOutput()
    local _, _, _, items = cells(port); return items[1], items[2]
  end
  local function manager(player)
    local wired, direct = {}, {}
    for _, name in ipairs(peripheral.getNames()) do
      if methods(name, {"getOwner","getItems","addItemToPlayer","removeItemFromPlayer"}) then
        local p = peripheral.wrap(name)
        if p.getOwner() == player then
          local t = sides[name] and direct or wired; t[#t+1] = p
        end
      end
    end
    local t = #wired > 0 and wired or direct
    check(#t == 1, "Need exactly one Inventory Manager for " .. player); return t[1]
  end
  local function playerCells(player)
    local p = manager(player); local items = p.getItems()
    check(type(items) == "table", "Cannot read player inventory (offline?)")
    local count, slot = 0
    for k, v in pairs(items) do
      if v.name == cfg.CELL then
        count = count + (v.count or 0); slot = tonumber(v.slot or k)
      end
    end
    check(count <= 1, "Player carries multiple spatial cells")
    return count, slot, p
  end
  function H.players()
    local v = detector.getPlayersInCoords(cfg.ZONE_MIN, cfg.ZONE_MAX)
    check(type(v) == "table", "Player detector unavailable")
    local out = {}
    for k, x in pairs(v) do
      local name = type(x) == "string" and x or type(x) == "table" and (x.name or x.username or x.player)
      if not name and type(k) == "string" then name = k end
      if name then
        local p = detector.getPlayerPos(name)
        check(type(p) == "table" and type(p.dimension) == "string", "Cannot verify zone player's dimension")
        if p.dimension == cfg.DIMENSION then out[#out+1] = name end
      end
    end
    table.sort(out); return out
  end
  local function pos(player)
    local p = detector.getPlayerPos(player)
    check(type(p) == "table" and type(p.dimension) == "string", "Player position unavailable; check online status and multidimensional detector config")
    return p
  end
  local function alone(player)
    local p = H.players(); check(#p == 1 and p[1] == player, "Source zone must contain only " .. player)
    check(pos(player).dimension == cfg.DIMENSION, "Wrong source DIMENSION setting")
  end
  local function empty() check(#H.players() == 0, "Spatial zone occupied") end
  local function toVault()
    local n, slot = cells(port)
    if n == 1 then
      check(cells(vault) == 0, "Vault already contains a cell")
      port.pushItems(vaultName, slot, 1)
      check(cells(port) == 0 and cells(vault) == 1, "Port -> vault transfer failed")
    end
  end
  local function toInput(j, commit)
    local a, b = inputOutput()
    check(not b, "Spatial output must be empty before preparing input")
    if a then check(a.name == cfg.CELL and a.count == 1, "Input occupied by another item")
    else
      local n, slot = cells(vault); check(n == 1, "Cell missing from vault")
      vault.pushItems(portName, slot, 1, 1)
      a, b = inputOutput(); check(a and a.name == cfg.CELL and not b, "Vault -> port transfer failed")
    end
    j.cellNbt = a.nbt; commit()
  end
  local function collect(j)
    local localCount = H.localCell()
    local count, slot, p = playerCells(j.player)
    check(localCount + count <= 1, "Cell ambiguity between player and local inventories")
    if localCount == 0 then
      check(count == 1 and slot ~= nil, "Cell not found locally or on player")
      p.removeItemFromPlayer(cfg.MANAGER_SIDE, {name=cfg.CELL,fromSlot=slot,count=1})
      check(H.localCell() == 1 and playerCells(j.player) == 0, "Player -> vault transfer failed; check MANAGER_SIDE")
    end
  end
  function H.reserve(j, id)
    H.localCell(); local a, b = inputOutput()
    check(not a and not b, "Port must be empty at reservation; inspect/move the idle cell to its vault")
    manager(j.player)
    if id == j.src then
      alone(j.player)
      local count, _, p = playerCells(j.player)
      check(count == 0, "Remove unrelated spatial cells from player inventory before teleport")
      if p.isSpaceAvailable then check(p.isSpaceAvailable(), "Player inventory is full") end
    end
    if id == j.dst then empty() end
    if id == j.holder then check(cells(vault) == 1, "Advertised cell is no longer in holder vault")
    else check(H.localCell() == 0, "Unexpected second cell in this pool") end
  end
  function H.give(j, commit)
    local n = H.localCell(); local carried, _, p = playerCells(j.player)
    if n == 0 then check(carried == 1, "Cell disappeared during handoff"); return end
    check(carried == 0, "Player already carries a spatial cell")
    toVault(); local _, slot = cells(vault)
    p.addItemToPlayer(cfg.MANAGER_SIDE, {name=cfg.CELL,fromSlot=slot,count=1})
    check(H.localCell() == 0 and playerCells(j.player) == 1, "Vault -> player transfer failed")
  end
  function H.acquire(j, commit, destination)
    if destination then empty(); check(pos(j.player).dimension == cfg.SPATIAL_DIMENSION, "Player is not in spatial dimension")
    else alone(j.player) end
    collect(j); toVault(); toInput(j, commit)
  end
  function H.uncertain(j)
    for _, p in pairs(j.pulses or {}) do if p.stage == "INTENT" then return true end end
    return false
  end
  function H.reconcile(j, commit)
    for kind, p in pairs(j.pulses or {}) do
      if p.stage == "INTENT" then
        local a, b = inputOutput()
        if not a and b and b.name == cfg.CELL and b.count == 1 then
          p.stage = "APPLIED"; j.cellNbt = b.nbt
          if kind == "capture" then j.captured = true elseif kind == "release" then j.released = true else j.rolledBack = true end
          commit(); log("Reconciled " .. kind .. " from output slot; no repeat pulse")
        end
      end
    end
  end
  function H.pulse(j, kind, commit)
    j.pulses = j.pulses or {}; H.reconcile(j, commit)
    local previous = j.pulses[kind]
    if previous then check(previous.stage == "APPLIED", "Ambiguous pulse intent; refusing to pulse twice"); return end
    check(not H.uncertain(j), "Another pulse is unresolved")
    local a, b = inputOutput()
    check(a and a.name == cfg.CELL and a.count == 1 and not b, "Expected cell in input and empty output")
    check(j.cellNbt == a.nbt, "Input cell NBT changed unexpectedly")
    if kind == "capture" then alone(j.player)
    else empty(); check(pos(j.player).dimension == cfg.SPATIAL_DIMENSION, "Player is no longer in spatial dimension") end
    H.low()
    j.pulses[kind] = {stage="INTENT", at=os.epoch("utc")}; commit()
    local ok, err = pcall(function()
      relay.setOutput(cfg.RELAY_SIDE, true); sleep(cfg.PULSE_SECONDS)
    end)
    local lowOK, lowErr = pcall(H.low)
    check(ok and lowOK, tostring(err or lowErr))
    local deadline = os.clock()+8
    repeat
      H.reconcile(j, commit)
      if j.pulses[kind].stage == "APPLIED" then return end
      sleep(0.1)
    until os.clock() >= deadline
    -- The input staying in slot 1 is deliberately not treated as proof of a completed exchange.
    error("PULSE_UNCERTAIN: no verified output cell; inspect power/port without clearing state", 0)
  end
  function H.settle(j, commit)
    local deadline = os.clock()+12
    repeat
      local ok, p = pcall(pos, j.player)
      if ok and p.dimension ~= cfg.SPATIAL_DIMENSION then
        j.arrivalDimension = p.dimension; j.arrived = true; commit(); toVault(); return
      end
      sleep(0.25)
    until os.clock() >= deadline
    error("Waiting to confirm player outside spatial dimension", 0)
  end
  function H.repatriate(j, commit)
    if H.localCell() == 1 then H.give(j, commit) end
  end
  function H.restore(j, commit)
    if j.rolledBack then H.settle(j, commit); return {returned=true} end
    collect(j)
    if j.captured then
      local p = pos(j.player)
      if p.dimension == cfg.SPATIAL_DIMENSION then
        empty(); toVault(); toInput(j, commit); H.pulse(j, "rollback", commit); H.settle(j, commit)
      else
        j.escaped = true; commit(); toVault()
      end
    else toVault() end
    return {returned=j.rolledBack or false, escaped=j.escaped or false}
  end
  H.low()
  return H
end


if _G.SPATIAL_TEST then return {Hub=Hub, hardware=hardware, journal=journal, checksum=checksum} end
check(CFG.CONFIGURED, "Edit the CFG block, then set CONFIGURED=true. Read README_RU.md first.")
check(type(CFG.DISPATCHER_ID) == "number" and CFG.DISPATCHER_ID >= 0, "Set DISPATCHER_ID")
check(CFG.HUB_ID ~= "" and CFG.HUB_ID ~= "dispatcher", "Set unique HUB_ID")
local log = logger(CFG.LOG)
local state, writer, damaged = journal(CFG.STATE)
if not state then legacyGuard("hub_state.txt", true) end
local identity = CFG.NETWORK .. ":" .. CFG.POOL .. ":" .. CFG.HUB_ID .. ":" .. CFG.DISPATCHER_ID
if state then check(state.identity == identity, "Endpoint identity changed; restore original settings") end
local diskFailed = false
local function persist(v)
  local ok, err = pcall(writer, v)
  if not ok then diskFailed = true; error(err, 0) end
end
local hw = hardware(CFG, log)
local function send(cmd, data)
  local m = copy(data or {}); m.cmd, m.from, m.to, m.network = cmd, CFG.HUB_ID, "dispatcher", CFG.NETWORK
  local ok, result = pcall(rednet.send, CFG.DISPATCHER_ID, m, PROTOCOL)
  if not ok or not result then log("TX unavailable: " .. cmd .. " " .. tostring(result)) end
end
local h = Hub.new({id=CFG.HUB_ID, pool=CFG.POOL, now=function() return os.epoch("utc")/1000 end,
  persist=persist, persistFailed=function() return diskFailed end, send=send, hw=hw, log=log}, state)
h.s.identity = identity; h:save()
if damaged then log("Loaded previous valid journal generation; no automatic repeat pulses") end
openModems()
for key, name in pairs(hw.names) do print(key .. ": " .. name) end
print("Hub " .. CFG.HUB_ID .. ", computer " .. os.getComputerID())
print("Dispatcher computer: " .. CFG.DISPATCHER_ID)
local queue, queued, hubs, notice = {}, {}, {}, ""
local function enqueue(m)
  local key = (m.op or m.request or "local") .. ":" .. (m.action or m.cmd)
  if queued[key] or #queue >= 128 then return end
  queued[key] = true; m.queueKey = key
  if m.action == "FENCE" or m.action == "FINISH" then table.insert(queue, 1, m) else queue[#queue+1] = m end
  os.queueEvent("spatial_work")
end
local function receiver()
  while true do
    local sender, raw = rednet.receive(PROTOCOL)
    local m = decode(raw)
    if sender == CFG.DISPATCHER_ID and m and m.network == CFG.NETWORK and m.from == "dispatcher" and m.to == CFG.HUB_ID then
      if m.cmd == "HUB_LIST" and type(m.hubs) == "table" then hubs = m.hubs
      elseif m.cmd == "COMMAND" or m.cmd == "ACCEPTED" or m.cmd == "DENY" or m.cmd == "CANCEL_ACK" then enqueue(m) end
    end
  end
end
local function worker()
  while true do
    if #queue == 0 then os.pullEvent("spatial_work") end
    local m = table.remove(queue, 1)
    if m then
      if m.cmd == "COMMAND" then h:command(m)
      elseif m.cmd == "LOCAL_REQUEST" then h:request(m.player, m.dst); notice = "Requesting teleport..."
      elseif m.cmd == "TICK" then
        local r = h.s.request
        if r then
          if not r.op and h.io.now() > r.expires then r.cancelled = true; h:save() end
          if r.cancelled then send("CANCEL_REQUEST", {request=r.request})
          elseif not r.op then send("REQUEST", r) end
        end
        if h.s.waitExit then
          local ok, players = pcall(hw.players)
          if ok and not contains(players, h.s.waitExit) then h.s.waitExit=nil; h:save() end
        end
      else
        h:control(m)
        if m.cmd == "DENY" then notice = "Denied: " .. tostring(m.reason)
        elseif m.cmd == "CANCEL_ACK" then notice = "Request cancelled" end
      end
      queued[m.queueKey] = nil
    end
  end
end
local function heartbeat()
  while true do
    pcall(openModems)
    local okCell, cell = pcall(hw.localCell)
    local okPlayers, players = pcall(hw.players)
    local fault = not okCell and tostring(cell) or not okPlayers and tostring(players) or nil
    send("HELLO", {label=CFG.HUB_LABEL,pool=CFG.POOL,cell=okCell and cell or -1,
      busy=h.s.active ~= nil,occupied=not okPlayers or #players > 0,fault=fault})
    enqueue({cmd="TICK"}); sleep(2)
  end
end
local function ui()
  local monitor, page, choices, currentPlayer = hw.monitor, 1, {}, nil
  local function draw()
    local ok, players = pcall(hw.players)
    if not ok then players = {} end
    local lines = {CFG.HUB_LABEL}
    choices, currentPlayer = {}, nil
    if h.s.active then
      local j = h.s.ops[h.s.active]
      lines[#lines+1] = j.cancelled and "Returning / recovering..." or "Teleport in progress..."
      lines[#lines+1] = "Player: " .. j.player
      lines[#lines+1] = "Op: " .. h.s.active
      lines[#lines+1] = "Keep the zone clear"
      lines[#lines+1] = j.lastAction or ""
      lines[#lines+1] = j.lastError or ""
    elseif h.s.request then lines[#lines+1] = h.s.request.cancelled and "Cancelling request..." or "Requesting teleport..."
    elseif not ok then lines[#lines+1] = "Player detector error"
    elseif h.s.waitExit and contains(players, h.s.waitExit) then lines[#lines+1] = "Waiting for exit..."
    elseif #players == 1 then
      currentPlayer = players[1]
      lines[#lines+1] = "Player: " .. currentPlayer; lines[#lines+1] = "Choose destination"
      for _, hub in ipairs(hubs) do
        if hub.pool == CFG.POOL and hub.id ~= CFG.HUB_ID and not hub.busy and not hub.occupied and not hub.fault then choices[#choices+1] = hub end
      end
      local w, height = monitor.getSize()
      local pageSize = math.max(1, math.min(10, height-6))
      page = math.max(1, math.min(page, math.max(1, math.ceil(#choices/pageSize))))
      local first = (page-1)*pageSize+1
      for i=first,math.min(first+pageSize-1,#choices) do lines[#lines+1] = tostring(i-first+1) .. ". " .. choices[i].label end
      if #choices == 0 then lines[#lines+1] = "No available destinations" end
      while #lines < height-2 do lines[#lines+1] = "" end
      lines[height-2] = "< " .. page .. "/" .. math.max(1,math.ceil(#choices/pageSize)) .. " >"
      lines[height-1] = notice
    elseif #players > 1 then lines[#lines+1] = "Only one player allowed"
    else lines[#lines+1] = "Waiting for player..." end
    monitor.setBackgroundColor(colors.black); monitor.setTextColor(colors.white); monitor.clear()
    local w, height = monitor.getSize()
    for y=1,math.min(height,#lines) do
      local x = y == 1 and math.max(1,math.floor((w-#lines[y])/2)+1) or 1
      monitor.setCursorPos(x,y); monitor.write(lines[y]:sub(1,w-x+1))
    end
  end
  local function selectChoice(n)
    local _, height = monitor.getSize(); local pageSize=math.max(1,math.min(10,height-6))
    local choice = choices[(page-1)*pageSize+n]
    if choice and n <= pageSize and currentPlayer and not h.s.active and not h.s.request then
      enqueue({cmd="LOCAL_REQUEST",player=currentPlayer,dst=choice.id})
    end
  end
  local timer = os.startTimer(0.5)
  while true do
    local ok, err = pcall(draw); if not ok then log("Monitor: " .. tostring(err)) end
    local e,a,b,c = os.pullEvent()
    if e == "timer" and a == timer then timer = os.startTimer(0.5)
    elseif e == "monitor_touch" and a == hw.monitorName then
      local w,height = monitor.getSize()
      if c >= 4 and c < height-2 then selectChoice(c-3)
      elseif c == height-2 then if b <= w/3 then page=math.max(1,page-1) elseif b >= w*2/3 then page=page+1 end end
    elseif e == "key" then
      local digits = {keys.one,keys.two,keys.three,keys.four,keys.five,keys.six,keys.seven,keys.eight,keys.nine,keys.zero}
      for n,k in ipairs(digits) do if a == k then selectChoice(n) end end
      if a == keys.left then page=math.max(1,page-1) elseif a == keys.right then page=page+1 end
    end
  end
end
local ok, err = pcall(function() parallel.waitForAll(receiver, worker, heartbeat, ui) end)
pcall(hw.low)
if not ok then log("STOP: " .. tostring(err)); error(err, 0) end
