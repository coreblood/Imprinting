-- ============================================================================
-- Imprinting v1.0.0 -- by Mhortai
-- Standalone remake of the Uncapped Dashboard's Extraction tab.
--   * Collection tab: browse unlocked effects (named rows, working search and
--     filters), right-click to hide effects you never use, stamp onto gear.
--   * Unlock tab: burn a bag item to learn its proc forever (named consent).
--   * Target list shows what each piece ALREADY carries before you stamp.
-- Wire: same UNC/REAGENTBANK protocol as the Dashboard; parses BOTH the
-- ICEXI dialect (requested) and the ICINV dialect (pushed by the live realm).
-- ============================================================================

local VERSION = "1.0.0"
local SEND_PREFIX, RECV_PREFIX = "REAGENTBANK", "UNC"
local ME = UnitName("player")

local TRIGGER_LABEL = { [0]="On Use", [1]="Passive", [2]="On Hit", [3]="On Cast" }
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

ImprintingDB = ImprintingDB or nil
local db  -- set at ADDON_LOADED

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local state = {
  collection = {},      -- { {spell, trigger, src} } sorted by name
  collSet = {},         -- ["spell:trigger"] = true
  items = {},           -- committed gear list: { key,bag,slot,entry,equipped,procs={{spell,trigger}},done }
  exiStaging = nil,     -- ICEXI sweep in progress
  doneStaging = nil,    -- ICEXD marks in the same sweep
  buckets = {},         -- ICINV-dialect cache: [key] = { procs = {...} } (key "E:n" / "B:a:b")
  bStaging = nil, bCurKey = nil,
  banned = {},          -- [spellId] = reason sentence
  bpStaging = nil,
  haveExi = false,      -- at least one ICEXI sweep committed this session
  selEffect = nil,      -- selected collection entry (apply)
  selTarget = nil,      -- selected gear row (apply)
  selSource = nil,      -- selected unlockable row (unlock)
  tab = "coll",         -- "coll" | "unlock"
  filter = "all",       -- all | hit | pass
  search = "",
  status = "",
  lastReq = 0,
}

local UI, dbgOn

-- small debug handle (harness + live /run diagnosis)
_G.Imprinting = { version = VERSION, state = state }

local function dbg(t) if dbgOn then DEFAULT_CHAT_FRAME:AddMessage("|cff8080ff[Imprinting]|r " .. t) end end
local function send(body) dbg("-> " .. body); SendAddonMessage(SEND_PREFIX, body, "WHISPER", ME) end

local function setStatus(t)
  state.status = t or ""
  if UI and UI.status then UI.status:SetText(state.status) end
end

local function spellName(id) return (GetSpellInfo(id)) or ("Spell " .. tostring(id)) end
local function spellIcon(id) local _, _, tex = GetSpellInfo(id); return tex or QUESTION end
local function trigLabel(t) return TRIGGER_LABEL[t] or ("Trigger " .. tostring(t)) end

-- Duplicate display names get their spell id appended so two "Poison"s stay
-- tellable apart. Rebuilt whenever the collection or gear list commits.
local nameCount = {}
local function rebuildNameCounts()
  nameCount = {}
  for _, e in ipairs(state.collection) do
    local n = spellName(e.spell); nameCount[n] = (nameCount[n] or 0) + 1
  end
end
local function effectName(spell)
  local n = spellName(spell)
  if (nameCount[n] or 0) > 1 then return n .. " |cff808080(" .. spell .. ")|r" end
  return n
end

local function hiddenKey(e) return e.spell .. ":" .. e.trigger end
local function isHidden(e) return db.hidden[hiddenKey(e)] and true or false end

-- ---------------------------------------------------------------------------
-- Gear list assembly
-- ---------------------------------------------------------------------------
-- Preferred source: a committed ICEXI sweep (entry + equipped flag + exact
-- server coords). Fallback when the realm never answers ICEXSRC third-party:
-- the pushed ICINV buckets ("E:<invSlot>" / "B:<bag>:<slot>" keys).
local function itemLabel(it)
  if it.entry then
    local name = GetItemInfo(it.entry)
    if name then return name end
    return "Item " .. it.entry
  end
  if it.invSlot then
    local link = GetInventoryItemLink("player", it.invSlot)
    local name = link and GetItemInfo(link)
    return name or ("Worn slot " .. it.invSlot)
  end
  -- server-numbered bag bucket; try the same coords client-side for a name
  local link = GetContainerItemLink(it.bag, it.slot)
  local name = link and GetItemInfo(link)
  return name or ("Bag item " .. it.bag .. ":" .. it.slot)
end

local function itemIcon(it)
  if it.entry then
    local tex = select(10, GetItemInfo(it.entry))
    if tex then return tex end
  end
  if it.invSlot then return GetInventoryItemTexture("player", it.invSlot) or QUESTION end
  local tex = GetContainerItemInfo(it.bag, it.slot)
  return tex or QUESTION
end

local function rebuildFromBuckets()
  local out = {}
  for key, b in pairs(state.buckets) do
    local invSlot = key:match("^E:(%d+)$")
    local bag, slot = key:match("^B:(%d+):(%d+)$")
    if invSlot then
      out[#out + 1] = { key = key, invSlot = tonumber(invSlot), equipped = 1,
                        bag = -1, slot = tonumber(invSlot), procs = b.procs, fromBucket = true }
    elseif bag then
      out[#out + 1] = { key = key, bag = tonumber(bag), slot = tonumber(slot),
                        equipped = 0, procs = b.procs, fromBucket = true }
    end
  end
  return out
end

local function commitItems()
  local out
  if state.exiStaging then
    out = {}
    for _, it in pairs(state.exiStaging) do out[#out + 1] = it end
    state.haveExi = true
  else
    out = rebuildFromBuckets()
  end
  table.sort(out, function(a, b)
    if a.equipped ~= b.equipped then return a.equipped > b.equipped end
    return itemLabel(a) < itemLabel(b)
  end)
  state.items = out
  -- drop dead selections
  local function still(sel)
    if not sel then return nil end
    for _, it in ipairs(state.items) do if it.key == sel.key then return it end end
    return nil
  end
  state.selTarget = still(state.selTarget)
  state.selSource = state.selSource and still({ key = state.selSource.key }) and state.selSource or nil
  if UI and UI:IsShown() then UI:Refresh() end
end

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------
local function requestAll(force)
  local now = GetTime()
  if not force and now - state.lastReq < 10 then
    setStatus("Asked the server recently -- wait a moment.")
    return
  end
  state.lastReq = now
  state.exiStaging = nil
  send("ICEXSRC"); send("ICCOLL"); send("ICBPGET")
  setStatus("Asking the server...")
end

-- delayed re-request after a successful apply/unlock (server pushes may cover
-- it, but the explicit ask keeps the target procs honest)
local reqTimer = CreateFrame("Frame"); reqTimer:Hide()
reqTimer:SetScript("OnUpdate", function(self, elapsed)
  self.left = self.left - elapsed
  if self.left <= 0 then self:Hide(); requestAll(true) end
end)
local function requestSoon(delay) reqTimer.left = delay or 1.5; reqTimer:Show() end

local function onWire(msg)
  local cmd, rest = msg:match("^([A-Z]+):(.*)$")
  if not cmd then cmd = msg; rest = "" end

  if cmd == "ICEXI" then                -- <bag>:<slot>:<entry>:<equipped>:<spell>:<trigger>
    local bag, slot, entry, eq, spell, trig = rest:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if bag then
      state.exiStaging = state.exiStaging or {}
      local key = "X:" .. bag .. ":" .. slot
      local it = state.exiStaging[key]
      if not it then
        it = { key = key, bag = tonumber(bag), slot = tonumber(slot),
               entry = tonumber(entry), equipped = tonumber(eq), procs = {} }
        state.exiStaging[key] = it
      end
      if tonumber(spell) > 0 then
        it.procs[#it.procs + 1] = { spell = tonumber(spell), trigger = tonumber(trig) }
      end
    end
  elseif cmd == "ICEXD" then            -- <bag>:<slot> finished mark
    local bag, slot = rest:match("^(%d+):(%d+)$")
    if bag then
      state.doneStaging = state.doneStaging or {}
      state.doneStaging[bag .. ":" .. slot] = true
    end
  elseif cmd == "ICEXIEND" then
    local done = state.doneStaging or {}
    state.doneStaging = nil
    if state.exiStaging then
      for _, it in pairs(state.exiStaging) do
        it.done = done[it.bag .. ":" .. it.slot] and true or false
      end
    end
    commitItems()
    state.exiStaging = nil
    setStatus("")

  -- ---- ICINV dialect (pushed by the live realm on bag changes) ------------
  elseif cmd == "ICITEM" then
    state.bStaging = state.bStaging or {}
    state.bCurKey = rest
    state.bStaging[rest] = { procs = {} }
  elseif cmd == "ICIPROC" then          -- <spell>:<trig>:<chance>:<mag>[:<cap>]
    local sid, tr = rest:match("^(%d+):(%d+):")
    local b = state.bCurKey and state.bStaging and state.bStaging[state.bCurKey]
    if sid and b then
      b.procs[#b.procs + 1] = { spell = tonumber(sid), trigger = tonumber(tr) }
    end
  elseif cmd == "ICINVEND" then
    if state.bStaging then
      state.buckets = state.bStaging
      state.bStaging = nil; state.bCurKey = nil
      if not state.haveExi then commitItems() end
    end

  -- ---- collection ----------------------------------------------------------
  elseif cmd == "ICCOLLROW" then        -- <spell>:<trigger>:<sourceEntry>
    local sp, tr, src = rest:match("^(%d+):(%d+):(%d+)$")
    if sp then
      state.collStaging = state.collStaging or {}
      state.collStaging[#state.collStaging + 1] =
        { spell = tonumber(sp), trigger = tonumber(tr), src = tonumber(src) }
    end
  elseif cmd == "ICCOLLEND" then
    state.collection = state.collStaging or {}
    state.collStaging = nil
    state.collSet = {}
    for _, e in ipairs(state.collection) do state.collSet[e.spell .. ":" .. e.trigger] = true end
    rebuildNameCounts()
    table.sort(state.collection, function(a, b)
      local an, bn = spellName(a.spell), spellName(b.spell)
      if an ~= bn then return an < bn end
      return a.trigger < b.trigger
    end)
    if UI and UI:IsShown() then UI:Refresh() end

  -- ---- banned register ------------------------------------------------------
  elseif cmd == "ICBPR" then            -- <idx>:<sentence>
    local idx, text = rest:match("^(%d+):(.+)$")
    if idx then
      state.bpStaging = state.bpStaging or { reasons = {}, spells = {} }
      state.bpStaging.reasons[tonumber(idx)] = text
    end
  elseif cmd == "ICBPS" then            -- <reasonIdx>:<id>,<id>,...
    local idx, ids = rest:match("^(%d+):(.+)$")
    if idx then
      state.bpStaging = state.bpStaging or { reasons = {}, spells = {} }
      local r = tonumber(idx)
      for id in ids:gmatch("(%d+)") do state.bpStaging.spells[tonumber(id)] = r end
    end
  elseif cmd == "ICBPEND" then
    state.banned = {}
    if state.bpStaging then
      for id, r in pairs(state.bpStaging.spells) do
        state.banned[id] = state.bpStaging.reasons[r] or "Disabled on this realm."
      end
      state.bpStaging = nil
    end
    if UI and UI:IsShown() then UI:Refresh() end

  -- ---- action replies --------------------------------------------------------
  elseif cmd == "ICUNLOCKED" then       -- <spell>:<trigger>
    local sp, tr = rest:match("^(%d+):(%d+)$")
    if sp then
      local e = { spell = tonumber(sp), trigger = tonumber(tr), src = 0 }
      if not state.collSet[sp .. ":" .. tr] then
        state.collection[#state.collection + 1] = e
        state.collSet[sp .. ":" .. tr] = true
        rebuildNameCounts()
      end
      setStatus("|cff9CC243Unlocked|r " .. spellName(e.spell) .. " -- yours permanently, account-wide.")
      state.selSource = nil
      requestSoon()
    end
  elseif cmd == "ICEXOK" then           -- <spell> apply succeeded
    local sp = tonumber(rest)
    setStatus("|cff9CC243Imprinted|r " .. (sp and spellName(sp) or "the effect") .. ".")
    requestSoon()
  elseif cmd == "ICERR" then
    local _, reason = rest:match("^(%a+):(.+)$")
    reason = reason or rest
    if reason == "equipped" then
      setStatus("|cffff8040You are wearing that. Unlocking destroys the item -- take it off first.|r")
    elseif reason == "already_known" then
      setStatus("|cffff8040That effect is already in your collection.|r")
    else
      setStatus("|cffff8040Server refused:|r " .. reason)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------
local pendingApply, pendingUnlock

StaticPopupDialogs["IMPRINTING_APPLY"] = {
  text = "%s",
  button1 = "Imprint", button2 = CANCEL,
  OnAccept = function()
    local p = pendingApply
    if p then send(string.format("ICAPPLY:%d:%d:%d:%d", p.spell, p.trigger, p.bag, p.slot)) end
    pendingApply = nil
  end,
  OnCancel = function() pendingApply = nil end,
  timeout = 0, whileDead = 1, hideOnEscape = 1,
}

StaticPopupDialogs["IMPRINTING_UNLOCK"] = {
  text = "%s",
  button1 = "Unlock", button2 = CANCEL,
  OnAccept = function()
    local p = pendingUnlock
    if p then send(string.format("ICUNLOCK:%d:%d:%d:%d", p.bag, p.slot, p.spell, p.trigger)) end
    pendingUnlock = nil
  end,
  OnCancel = function() pendingUnlock = nil end,
  timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1,
}

local function doApply()
  local e, t = state.selEffect, state.selTarget
  if not (e and t) then setStatus("Pick an effect and a piece of gear first."); return end
  pendingApply = { spell = e.spell, trigger = e.trigger, bag = t.bag, slot = t.slot }
  local existing = ""
  if t.procs and #t.procs > 0 then
    local names = {}
    for _, p in ipairs(t.procs) do names[#names + 1] = spellName(p.spell) end
    existing = "\n\n|cffff8040Already carries:|r |cffc080f0" .. table.concat(names, ", ") .. "|r"
  end
  if existing ~= "" and db.confirmOverwrite then
    StaticPopup_Show("IMPRINTING_APPLY", string.format(
      "Stamp |cffb384ff%s|r onto |cffffffff%s|r?%s", spellName(e.spell), itemLabel(t), existing))
  elseif db.confirmOverwrite then
    StaticPopup_Show("IMPRINTING_APPLY", string.format(
      "Stamp |cffb384ff%s|r onto |cffffffff%s|r?", spellName(e.spell), itemLabel(t)))
  else
    send(string.format("ICAPPLY:%d:%d:%d:%d", pendingApply.spell, pendingApply.trigger,
      pendingApply.bag, pendingApply.slot))
    pendingApply = nil
  end
end

local function doUnlock()
  local s = state.selSource
  if not s then setStatus("Pick a proc to unlock first."); return end
  if state.collSet[s.spell .. ":" .. s.trigger] then
    setStatus("Already in your collection."); return
  end
  pendingUnlock = { bag = s.bag, slot = s.slot, spell = s.spell, trigger = s.trigger }
  StaticPopup_Show("IMPRINTING_UNLOCK", string.format(
    "Unlock |cffb384ff%s|r from |cffffffff%s|r?\n\n|cffff4040This DESTROYS the item.|r The effect is yours forever, on every character.",
    spellName(s.spell), itemLabel(s.item)))
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
local ROW_H, EFF_ROWS, TGT_ROWS = 24, 12, 12
local effRows, tgtRows = {}, {}

local function skinButton(b)
  b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 } })
  b:SetBackdropColor(0.18, 0.13, 0.28, 1)
  b:SetBackdropBorderColor(0.5, 0.4, 0.7, 1)
  b:SetNormalFontObject(GameFontHighlightSmall)
  b:SetHighlightFontObject(GameFontNormalSmall)
end

local function makeButton(parent, text, w, h)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  skinButton(b)
  b:SetText(text)
  return b
end

-- Which collection entries are visible under the current filter/search/hide set.
local function visibleEffects()
  local out = {}
  local q = state.search:lower()
  for _, e in ipairs(state.collection) do
    local ok
    if state.filter == "hit" then ok = (e.trigger == 2 or e.trigger == 3)
    elseif state.filter == "pass" then ok = (e.trigger == 0 or e.trigger == 1)
    else ok = true end
    if ok and isHidden(e) and not db.showHidden then ok = false end
    if ok and q ~= "" then ok = spellName(e.spell):lower():find(q, 1, true) ~= nil end
    if ok then out[#out + 1] = e end
  end
  return out
end

local function hiddenCount()
  local n = 0
  for _ in pairs(db.hidden) do n = n + 1 end
  return n
end

-- Unlockable rows: one per proc on each un-worn bag item.
local function unlockRows()
  local out = {}
  for _, it in ipairs(state.items) do
    if it.equipped ~= 1 then
      for _, p in ipairs(it.procs or {}) do
        out[#out + 1] = { key = it.key, item = it, bag = it.bag, slot = it.slot,
                          spell = p.spell, trigger = p.trigger }
      end
    end
  end
  table.sort(out, function(a, b)
    local an, bn = itemLabel(a.item), itemLabel(b.item)
    if an ~= bn then return an < bn end
    return spellName(a.spell) < spellName(b.spell)
  end)
  return out
end

local function BuildUI()
  if UI then return end
  local f = CreateFrame("Frame", "ImprintingFrame", UIParent)
  f:SetSize(720, 480)
  f:SetPoint(db.pos.point or "CENTER", UIParent, db.pos.point or "CENTER",
    db.pos.x or 0, db.pos.y or 0)
  f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  f:SetBackdropColor(0.06, 0.05, 0.09, 1)
  f:SetBackdropBorderColor(0.5, 0.4, 0.7, 1)
  f:SetAlpha(db.opacity)
  f:SetMovable(true); f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    db.pos = { point = point, x = x, y = y }
  end)
  f:SetFrameStrata("HIGH")
  tinsert(UISpecialFrames, "ImprintingFrame")

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOP", 0, -12)
  f.title:SetText("|cffb384ffImprinting|r |cff808080v" .. VERSION .. "|r")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  -- options cog
  local cog = CreateFrame("Button", nil, f)
  cog:SetSize(18, 18); cog:SetPoint("TOPRIGHT", -32, -10)
  cog:SetNormalTexture("Interface\\Icons\\INV_Misc_Gear_01")
  cog:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
  cog:SetScript("OnClick", function() f.opts:SetShown_(not f.opts:IsShown()) end)
  cog:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:SetText("Options"); GameTooltip:Show()
  end)
  cog:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- ---- tabs -----------------------------------------------------------------
  f.tabColl = makeButton(f, "Collection", 100, 22)
  f.tabColl:SetPoint("TOPLEFT", 14, -36)
  f.tabColl:SetScript("OnClick", function() state.tab = "coll"; f:Refresh() end)
  f.tabUnlock = makeButton(f, "Unlock", 100, 22)
  f.tabUnlock:SetPoint("LEFT", f.tabColl, "RIGHT", 6, 0)
  f.tabUnlock:SetScript("OnClick", function() state.tab = "unlock"; f:Refresh() end)

  f.refreshBtn = makeButton(f, "Refresh", 70, 22)
  f.refreshBtn:SetPoint("TOPRIGHT", -14, -36)
  f.refreshBtn:SetScript("OnClick", function() requestAll() end)

  -- ---- left pane: effect / source list --------------------------------------
  local search = CreateFrame("EditBox", "ImprintingSearch", f, "InputBoxTemplate")
  search:SetSize(150, 20)
  search:SetPoint("TOPLEFT", 22, -66)
  search:SetAutoFocus(false)
  search:SetScript("OnTextChanged", function(self)
    state.search = self:GetText() or ""
    f:Refresh()
  end)
  search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  f.search = search
  f.searchHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.searchHint:SetPoint("LEFT", search, "LEFT", 2, 0)
  f.searchHint:SetText("Search...")
  search:SetScript("OnEditFocusGained", function() f.searchHint:Hide() end)
  search:SetScript("OnEditFocusLost", function(self)
    if (self:GetText() or "") == "" then f.searchHint:Show() end
  end)

  f.filters = {}
  local fdefs = { { "all", "All" }, { "hit", "On Hit" }, { "pass", "Passive" } }
  for i, fd in ipairs(fdefs) do
    local b = makeButton(f, fd[2], 60, 20)
    if i == 1 then b:SetPoint("LEFT", search, "RIGHT", 10, 0)
    else b:SetPoint("LEFT", f.filters[i - 1], "RIGHT", 4, 0) end
    b.key = fd[1]
    b:SetScript("OnClick", function(self) state.filter = self.key; f:Refresh() end)
    f.filters[i] = b
  end

  f.showHidden = CreateFrame("CheckButton", "ImprintingShowHidden", f, "UICheckButtonTemplate")
  f.showHidden:SetSize(20, 20)
  f.showHidden:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -4, -2)
  _G["ImprintingShowHiddenText"]:SetText("Show hidden")
  _G["ImprintingShowHiddenText"]:SetFontObject(GameFontHighlightSmall)
  f.showHidden:SetScript("OnClick", function(self)
    db.showHidden = self:GetChecked() and true or false
    f:Refresh()
  end)

  f.hiddenNote = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.hiddenNote:SetPoint("LEFT", f.showHidden, "RIGHT", 90, 0)

  local escroll = CreateFrame("ScrollFrame", "ImprintingEffects", f, "FauxScrollFrameTemplate")
  escroll:SetPoint("TOPLEFT", 22, -114)
  escroll:SetSize(300, EFF_ROWS * ROW_H)
  escroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() f:Refresh() end)
  end)
  f.escroll = escroll

  for i = 1, EFF_ROWS do
    local r = CreateFrame("Button", nil, f)
    r:SetSize(296, ROW_H - 2)
    if i == 1 then r:SetPoint("TOPLEFT", escroll, "TOPLEFT", 0, 0)
    else r:SetPoint("TOPLEFT", effRows[i - 1], "BOTTOMLEFT", 0, -2) end
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints(); r.sel:SetTexture(0.45, 0.3, 0.7, 0.45); r.sel:Hide()
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.1)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 6, ROW_H - 6); r.icon:SetPoint("LEFT", 2, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 5, 0); r.name:SetWidth(200); r.name:SetJustifyH("LEFT")
    if r.name.SetWordWrap then r.name:SetWordWrap(false) end
    r.trig = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.trig:SetPoint("RIGHT", -4, 0)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
      if not self.data then return end
      if state.tab == "coll" then
        if button == "RightButton" then
          local k = hiddenKey(self.data)
          if db.hidden[k] then db.hidden[k] = nil else db.hidden[k] = true end
          f:Refresh()
          return
        end
        state.selEffect = self.data
      else
        state.selSource = self.data
      end
      f:Refresh()
    end)
    r:SetScript("OnEnter", function(self)
      if not self.data then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if state.tab == "coll" then
        GameTooltip:SetHyperlink("spell:" .. self.data.spell)
        local reason = state.banned[self.data.spell]
        if reason then GameTooltip:AddLine("|cffff4040Disabled:|r " .. reason, 1, 1, 1, true) end
        if isHidden(self.data) then
          GameTooltip:AddLine("Hidden. Right-click to show it again.", 0.7, 0.7, 0.7)
        else
          GameTooltip:AddLine("Right-click to hide this effect.", 0.7, 0.7, 0.7)
        end
      else
        GameTooltip:SetHyperlink("spell:" .. self.data.spell)
        GameTooltip:AddLine("From: " .. itemLabel(self.data.item), 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffff4040Unlocking destroys the item.|r", 1, 1, 1)
      end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:Hide()
    effRows[i] = r
  end

  f.effEmpty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.effEmpty:SetPoint("TOPLEFT", escroll, "TOPLEFT", 10, -30)
  f.effEmpty:SetWidth(280); f.effEmpty:SetJustifyH("LEFT")

  -- ---- right pane: target gear list ------------------------------------------
  f.tgtHead = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.tgtHead:SetPoint("TOPLEFT", 370, -66)

  local tscroll = CreateFrame("ScrollFrame", "ImprintingTargets", f, "FauxScrollFrameTemplate")
  tscroll:SetPoint("TOPLEFT", 370, -114)
  tscroll:SetSize(310, TGT_ROWS * ROW_H)
  tscroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() f:Refresh() end)
  end)
  f.tscroll = tscroll

  for i = 1, TGT_ROWS do
    local r = CreateFrame("Button", nil, f)
    r:SetSize(306, ROW_H - 2)
    if i == 1 then r:SetPoint("TOPLEFT", tscroll, "TOPLEFT", 0, 0)
    else r:SetPoint("TOPLEFT", tgtRows[i - 1], "BOTTOMLEFT", 0, -2) end
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints(); r.sel:SetTexture(0.45, 0.3, 0.7, 0.45); r.sel:Hide()
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1, 1, 1, 0.1)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 6, ROW_H - 6); r.icon:SetPoint("LEFT", 2, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 5, 0); r.name:SetWidth(230); r.name:SetJustifyH("LEFT")
    if r.name.SetWordWrap then r.name:SetWordWrap(false) end
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.sub:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 5, -1); r.sub:SetWidth(230); r.sub:SetJustifyH("LEFT")
    if r.sub.SetWordWrap then r.sub:SetWordWrap(false) end
    r.tick = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.tick:SetPoint("RIGHT", -4, 0); r.tick:SetText("|cff40ff40v|r"); r.tick:Hide()
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
      if not self.data then return end
      if button == "RightButton" then
        send(string.format("ICDONE:%d:%d:%d", self.data.bag, self.data.slot, self.data.done and 0 or 1))
        self.data.done = not self.data.done
        f:Refresh()
        return
      end
      state.selTarget = self.data
      f:Refresh()
    end)
    r:SetScript("OnEnter", function(self)
      if not self.data then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(itemLabel(self.data))
      if self.data.procs and #self.data.procs > 0 then
        for _, p in ipairs(self.data.procs) do
          GameTooltip:AddLine("|cffc080f0" .. spellName(p.spell) .. "|r |cff808080("
            .. trigLabel(p.trigger) .. ")|r", 1, 1, 1)
        end
      else
        GameTooltip:AddLine("No proc on this piece yet.", 0.7, 0.7, 0.7)
      end
      GameTooltip:AddLine("Right-click to mark finished.", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:Hide()
    tgtRows[i] = r
  end

  f.tgtEmpty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.tgtEmpty:SetPoint("TOPLEFT", tscroll, "TOPLEFT", 10, -30)
  f.tgtEmpty:SetWidth(290); f.tgtEmpty:SetJustifyH("LEFT")

  -- ---- bottom: action + status ------------------------------------------------
  f.actBtn = makeButton(f, "Imprint", 160, 26)
  f.actBtn:SetPoint("BOTTOM", 0, 40)
  f.actBtn:SetScript("OnClick", function()
    if state.tab == "coll" then doApply() else doUnlock() end
  end)

  f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.status:SetPoint("BOTTOMLEFT", 20, 16); f.status:SetPoint("BOTTOMRIGHT", -20, 16)
  f.status:SetJustifyH("CENTER")

  -- ---- options panel -----------------------------------------------------------
  local o = CreateFrame("Frame", nil, f)
  o:SetSize(240, 160)
  o:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -60)
  o:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  o:SetBackdropColor(0.1, 0.08, 0.15, 1)
  o:SetBackdropBorderColor(0.5, 0.4, 0.7, 1)
  o:SetFrameLevel(f:GetFrameLevel() + 10)
  o:EnableMouse(true)
  function o:SetShown_(show) if show then self:Show() else self:Hide() end end
  f.opts = o

  local ot = o:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ot:SetPoint("TOPLEFT", 12, -10); ot:SetText("Options")

  local function optCheck(name, label, y, get, set)
    local c = CreateFrame("CheckButton", name, o, "UICheckButtonTemplate")
    c:SetSize(22, 22); c:SetPoint("TOPLEFT", 10, y)
    _G[name .. "Text"]:SetText(label)
    _G[name .. "Text"]:SetFontObject(GameFontHighlightSmall)
    c:SetChecked(get())
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    return c
  end

  o.cMini = optCheck("ImprintingOptMini", "Minimap button", -30,
    function() return db.minimap.show end,
    function(v) db.minimap.show = v; if ImprintingMini then ImprintingMini:SetShown_(v) end end)
  o.cConfirm = optCheck("ImprintingOptConfirm", "Confirm before imprinting", -54,
    function() return db.confirmOverwrite end,
    function(v) db.confirmOverwrite = v end)

  local sl = CreateFrame("Slider", "ImprintingOptOpacity", o, "OptionsSliderTemplate")
  sl:SetPoint("TOPLEFT", 16, -100); sl:SetWidth(200)
  sl:SetMinMaxValues(0.5, 1); sl:SetValueStep(0.05)
  _G["ImprintingOptOpacityText"]:SetText("Window opacity")
  _G["ImprintingOptOpacityLow"]:SetText("50%"); _G["ImprintingOptOpacityHigh"]:SetText("100%")
  sl:SetValue(db.opacity)
  sl:SetScript("OnValueChanged", function(self, v)
    db.opacity = v; f:SetAlpha(v)
  end)

  local oc = makeButton(o, "Close", 70, 20)
  oc:SetPoint("BOTTOM", 0, 8)
  oc:SetScript("OnClick", function() o:Hide() end)
  o:Hide()

  -- ---- refresh ---------------------------------------------------------------
  function f:Refresh()
    -- tab visuals
    local onColl = state.tab == "coll"
    f.tabColl:SetBackdropColor(onColl and 0.35 or 0.18, onColl and 0.25 or 0.13, onColl and 0.55 or 0.28, 1)
    f.tabUnlock:SetBackdropColor(onColl and 0.18 or 0.35, onColl and 0.13 or 0.25, onColl and 0.28 or 0.55, 1)
    for _, b in ipairs(f.filters) do
      local on = b.key == state.filter
      b:SetBackdropColor(on and 0.35 or 0.18, on and 0.25 or 0.13, on and 0.55 or 0.28, 1)
    end
    f.showHidden:SetChecked(db.showHidden)
    local hc = hiddenCount()
    f.hiddenNote:SetText(hc > 0 and ("(" .. hc .. " hidden)") or "")
    if onColl then
      for _, b in ipairs(f.filters) do b:Show() end
      f.showHidden:Show(); _G["ImprintingShowHiddenText"]:Show()
    else
      for _, b in ipairs(f.filters) do b:Hide() end
      f.showHidden:Hide(); _G["ImprintingShowHiddenText"]:Hide()
    end

    -- left list
    local list
    if onColl then list = visibleEffects() else list = unlockRows() end
    FauxScrollFrame_Update(f.escroll, #list, EFF_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(f.escroll)
    for i = 1, EFF_ROWS do
      local r = effRows[i]; local d = list[i + offset]
      if d then
        r.data = d
        r.icon:SetTexture(spellIcon(d.spell))
        local nm
        if onColl then
          nm = effectName(d.spell)
          if state.banned[d.spell] then nm = "|cff707070" .. spellName(d.spell) .. " (disabled)|r"
          elseif isHidden(d) then nm = "|cff707070" .. spellName(d.spell) .. "|r" end
          if state.selEffect and state.selEffect.spell == d.spell
             and state.selEffect.trigger == d.trigger then r.sel:Show() else r.sel:Hide() end
        else
          local known = state.collSet[d.spell .. ":" .. d.trigger]
          nm = (known and "|cff707070" or "") .. spellName(d.spell)
            .. " |cff808080-- " .. itemLabel(d.item) .. "|r"
          if known then nm = nm .. " |cff40ff40(known)|r" end
          if state.selSource and state.selSource.key == d.key
             and state.selSource.spell == d.spell then r.sel:Show() else r.sel:Hide() end
        end
        r.name:SetText(nm)
        r.trig:SetText(trigLabel(d.trigger))
        r:Show()
      else
        r.data = nil; r:Hide()
      end
    end
    if #list == 0 then
      if onColl then
        f.effEmpty:SetText(#state.collection == 0
          and "Nothing unlocked yet, or the server has not answered.\nUnlock effects on the Unlock tab, then Refresh."
          or "Nothing matches the current filter or search.")
      else
        f.effEmpty:SetText(#state.items == 0
          and "No gear data yet. Open your bags or press Refresh."
          or "No unlockable procs on your bag items.")
      end
      f.effEmpty:Show()
    else f.effEmpty:Hide() end

    -- right list
    local tgt = {}
    if onColl then
      for _, it in ipairs(state.items) do tgt[#tgt + 1] = it end
    end
    f.tgtHead:SetText(onColl and "Apply to:" or "")
    FauxScrollFrame_Update(f.tscroll, #tgt, TGT_ROWS, ROW_H)
    local toff = FauxScrollFrame_GetOffset(f.tscroll)
    for i = 1, TGT_ROWS do
      local r = tgtRows[i]; local d = onColl and tgt[i + toff] or nil
      if d then
        r.data = d
        r.icon:SetTexture(itemIcon(d))
        r.name:SetText(itemLabel(d) .. (d.equipped == 1 and " |cff40c0ff[Worn]|r" or ""))
        if d.procs and #d.procs > 0 then
          local names = {}
          for _, p in ipairs(d.procs) do names[#names + 1] = spellName(p.spell) end
          r.sub:SetText("|cffc080f0" .. table.concat(names, ", ") .. "|r")
        else
          r.sub:SetText("|cff606060no proc|r")
        end
        if d.done then r.tick:Show() else r.tick:Hide() end
        if state.selTarget and state.selTarget.key == d.key then r.sel:Show() else r.sel:Hide() end
        r:Show()
      else
        r.data = nil; r:Hide()
      end
    end
    if onColl and #tgt == 0 then
      f.tgtEmpty:SetText("No gear data yet.\nPress Refresh, or open the Dashboard's Extraction tab once so the stream flows.")
      f.tgtEmpty:Show()
    else f.tgtEmpty:Hide() end

    -- action button
    if onColl then
      f.actBtn:SetText("Imprint")
      if state.selEffect and state.selTarget and not state.banned[state.selEffect.spell] then
        f.actBtn:Enable()
      else f.actBtn:Disable() end
    else
      f.actBtn:SetText("Unlock")
      if state.selSource and not state.collSet[state.selSource.spell .. ":" .. state.selSource.trigger] then
        f.actBtn:Enable()
      else f.actBtn:Disable() end
    end

    f.status:SetText(state.status)
  end

  UI = f
  f:Hide()  -- 3.3.5a: frames show by default; a toggle window must start hidden
end

local function Toggle()
  BuildUI()
  if UI:IsShown() then UI:Hide()
  else
    UI:Show()
    UI:Refresh()
    requestAll()
  end
end

-- ---------------------------------------------------------------------------
-- Minimap button
-- ---------------------------------------------------------------------------
local function BuildMini()
  local b = CreateFrame("Button", "ImprintingMiniBtn", Minimap)
  b:SetSize(24, 24)
  b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp")
  b:RegisterForDrag("LeftButton")
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(16, 16); icon:SetPoint("CENTER")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Rune_01")
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(42, 42); border:SetPoint("CENTER", 10, -10)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  local function place()
    local a = math.rad(db.minimap.angle or 200)
    b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
  end
  place()

  b:SetScript("OnClick", Toggle)
  b:SetScript("OnDragStart", function(self) self.drag = true end)
  b:SetScript("OnDragStop", function(self) self.drag = false end)
  b:SetScript("OnUpdate", function(self)
    if not self.drag then return end
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    place()
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Imprinting")
    GameTooltip:AddLine("Click to open. Drag to move.", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  function b:SetShown_(show) if show then self:Show() else self:Hide() end end
  _G.ImprintingMini = b
  if not db.minimap.show then b:Hide() end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("CHAT_MSG_ADDON")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
  if event == "ADDON_LOADED" and arg1 == "Imprinting" then
    ImprintingDB = ImprintingDB or {}
    db = ImprintingDB
    db.hidden = db.hidden or {}
    if db.showHidden == nil then db.showHidden = false end
    if db.confirmOverwrite == nil then db.confirmOverwrite = true end
    db.opacity = db.opacity or 1
    db.minimap = db.minimap or { show = true, angle = 200 }
    if db.minimap.show == nil then db.minimap.show = true end
    db.pos = db.pos or {}
  elseif event == "PLAYER_LOGIN" then
    if db then BuildMini() end
    DEFAULT_CHAT_FRAME:AddMessage("|cffb384ffImprinting|r v" .. VERSION
      .. " loaded. /imprint to open.")
  elseif event == "CHAT_MSG_ADDON" and arg1 == RECV_PREFIX and arg4 == ME then
    if db then
      dbg("<- " .. tostring(arg2))
      onWire(arg2)
    end
  end
end)

SLASH_IMPRINTING1 = "/imprint"
SLASH_IMPRINTING2 = "/imp"
SlashCmdList["IMPRINTING"] = function(msg)
  msg = (msg or ""):lower():match("^%s*(%S*)")
  if msg == "debug" then
    dbgOn = not dbgOn
    DEFAULT_CHAT_FRAME:AddMessage("|cffb384ffImprinting|r debug "
      .. (dbgOn and "ON" or "OFF"))
  else
    Toggle()
  end
end
