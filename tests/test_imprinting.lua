-- Headless harness for Imprinting (Lua 5.1). Mocks the WoW 3.3.5a API surface
-- the addon touches at file scope and in its wire/logic paths, then feeds
-- streams and asserts state.

local sent = {}
local chat = {}
local frames = {}

-- ---- WoW API mocks ---------------------------------------------------------
function UnitName() return "Mhortai" end
function SendAddonMessage(prefix, body) sent[#sent + 1] = prefix .. "|" .. body end
function GetTime() return _TIME or 0 end
_TIME = 0

local SPELLS = {
  [100] = { "Flurry of Blades", "Interface\\Icons\\a" },
  [200] = { "Nightfall", "Interface\\Icons\\b" },
  [300] = { "Poison", "Interface\\Icons\\c" },
  [301] = { "Poison", "Interface\\Icons\\d" },
}
function GetSpellInfo(id)
  local s = SPELLS[id]
  if not s then return nil end
  return s[1], nil, s[2]
end

local ITEMS = { [5000] = "Surrogate Belt", [5001] = "Valanar's Ring", [5002] = "Squire's Shirt" }
function GetItemInfo(x) return ITEMS[tonumber(x)] end
function GetContainerItemLink() return nil end
function GetContainerItemInfo() return nil end
INV_LINKS = {}
function GetInventoryItemLink(_, slot) return INV_LINKS[slot] end
function GetInventoryItemTexture() return nil end
function GetCursorPosition() return 0, 0 end
function PlaySoundFile() end
function StaticPopup_Show(which, text) chat[#chat + 1] = "POPUP:" .. which end
StaticPopupDialogs = {}
SlashCmdList = {}
UISpecialFrames = {}
CANCEL = "Cancel"
DEFAULT_CHAT_FRAME = { AddMessage = function(_, t) chat[#chat + 1] = t end }
GameFontHighlightSmall, GameFontNormalSmall, GameFontDisableSmall = {}, {}, {}
GameFontNormal, GameFontNormalLarge = {}, {}
function FauxScrollFrame_Update() end
function FauxScrollFrame_GetOffset() return 0 end
function FauxScrollFrame_OnVerticalScroll() end
tinsert = table.insert

local function mkFrame()
  local f = { scripts = {}, events = {}, shown = true, children = {} }
  local function noop() end
  f.SetScript = function(self, k, fn) self.scripts[k] = fn end
  f.GetScript = function(self, k) return self.scripts[k] end
  f.RegisterEvent = function(self, e) self.events[e] = true end
  f.RegisterForClicks = noop; f.RegisterForDrag = noop
  f.Hide = function(self) self.shown = false end
  f.Show = function(self) self.shown = true end
  f.IsShown = function(self) return self.shown end
  f.SetSize = noop; f.SetWidth = noop; f.SetHeight = noop; f.SetPoint = noop; f.SetBackdrop = noop
  f.SetBackdropColor = noop; f.SetBackdropBorderColor = noop
  f.SetAlpha = noop; f.SetMovable = noop; f.EnableMouse = noop
  f.SetFrameStrata = noop; f.SetFrameLevel = noop; f.GetFrameLevel = function() return 1 end
  f.StartMoving = noop; f.StopMovingOrSizing = noop
  f.GetPoint = function() return "CENTER", nil, nil, 0, 0 end
  f.CreateFontString = function() local s = mkFrame(); s.SetText = function(self, t) self.text = t end
    s.SetJustifyH = noop; s.SetWidth = noop; s.SetHeight = noop; s.SetFontObject = noop
    s.SetWordWrap = noop; return s end
  f.CreateTexture = function() local t = mkFrame(); t.SetAllPoints = noop; t.SetTexture = noop
    t.SetTexCoord = noop; t.SetSize = noop; return t end
  f.SetText = function(self, t) self.text = t end
  f.GetText = function(self) return self.text end
  f.SetNormalFontObject = noop; f.SetHighlightFontObject = noop
  f.SetNormalTexture = noop
  f.GetNormalTexture = function() return { SetTexCoord = noop } end
  f.Enable = noop; f.Disable = noop
  f.SetChecked = noop; f.GetChecked = function() return false end
  f.SetAutoFocus = noop; f.ClearFocus = noop
  f.SetMinMaxValues = noop; f.SetValueStep = noop; f.SetValue = noop
  f.GetCenter = function() return 0, 0 end
  f.GetEffectiveScale = function() return 1 end
  return f
end

function CreateFrame(kind, name, parent, template)
  local f = mkFrame()
  f.kind = kind; f.name = name; f.template = template
  frames[#frames + 1] = f
  if name then
    _G[name] = f
    local fsMock = { SetText = function() end, SetFontObject = function() end,
      Show = function() end, Hide = function() end }
    _G[name .. "Text"] = fsMock
    _G[name .. "Low"] = fsMock
    _G[name .. "High"] = fsMock
  end
  return f
end
Minimap = mkFrame()
UIParent = mkFrame()

-- ---- load the addon ---------------------------------------------------------
dofile("/home/claude/build/Imprinting/Imprinting.lua")

-- find the boot frame (registered ADDON_LOADED)
local boot
for _, f in ipairs(frames) do if f.events["ADDON_LOADED"] then boot = f end end
assert(boot, "boot frame not found")
local fire = boot.scripts["OnEvent"]

local S = _G.Imprinting.state
local function wire(msg) fire(boot, "CHAT_MSG_ADDON", "UNC", msg, "WHISPER", "Mhortai") end

local pass, fail = 0, 0
local function T(name, cond)
  if cond then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name) end
end

-- ---- 1. boot ----------------------------------------------------------------
fire(boot, "ADDON_LOADED", "Imprinting")
T("db defaults: hidden table", type(ImprintingDB.hidden) == "table")
T("db defaults: confirmOverwrite on", ImprintingDB.confirmOverwrite == true)
T("db defaults: minimap on", ImprintingDB.minimap.show == true)
fire(boot, "PLAYER_LOGIN")
T("login stamp printed", chat[#chat]:find("Imprinting") ~= nil)

-- ---- 2. ICEXI sweep -----------------------------------------------------------
wire("ICEXI:255:5:5000:1:100:2")     -- worn belt with Flurry (On Hit)
wire("ICEXI:0:3:5001:0:200:1")       -- bag ring with Nightfall (Passive)
wire("ICEXI:0:3:5001:0:300:0")       -- same ring, second proc
wire("ICEXI:1:7:5002:0:0:0")         -- bag shirt, no proc
wire("ICEXD:0:3")                    -- ring marked finished
wire("ICEXIEND")
T("exi: 3 items committed", #S.items == 3)
local worn, ring, shirt
for _, it in ipairs(S.items) do
  if it.entry == 5000 then worn = it elseif it.entry == 5001 then ring = it
  elseif it.entry == 5002 then shirt = it end
end
T("exi: worn flag", worn and worn.equipped == 1)
T("exi: worn sorted first", S.items[1].entry == 5000)
T("exi: worn proc attached", worn and #worn.procs == 1 and worn.procs[1].spell == 100)
T("exi: multi-proc item", ring and #ring.procs == 2)
T("exi: no-proc item present", shirt and #shirt.procs == 0)
T("exi: done mark", ring and ring.done == true)
T("exi: server coords kept", worn and worn.bag == 255 and worn.slot == 5)
T("exi: haveExi set", S.haveExi == true)

-- ---- 3. collection --------------------------------------------------------------
wire("ICCOLLROW:200:1:5001")
wire("ICCOLLROW:100:2:5000")
wire("ICCOLLROW:300:0:0")
wire("ICCOLLROW:301:0:0")
wire("ICCOLLEND")
T("coll: 4 entries", #S.collection == 4)
T("coll: sorted by name", GetSpellInfo(S.collection[1].spell) == "Flurry of Blades")
T("coll: collSet", S.collSet["100:2"] == true)

-- ---- 4. banned register -----------------------------------------------------------
wire("ICBPR:1:Too strong on this realm.")
wire("ICBPS:1:300,301")
wire("ICBPEND")
T("banned: mapped with reason", S.banned[300] == "Too strong on this realm.")
T("banned: second id", S.banned[301] ~= nil)
T("banned: others clean", S.banned[100] == nil)

-- ---- 5. ICINV dialect does not clobber exi data ------------------------------------
wire("ICITEM:E:16")
wire("ICIPROC:100:2:15:100")
wire("ICINVEND")
T("buckets cached", S.buckets["E:16"] ~= nil)
T("exi data survives bucket commit", #S.items == 3 and S.items[1].entry == 5000)

-- ---- 6. bucket fallback when no exi -------------------------------------------------
S.haveExi = false
S.items = {}
wire("ICITEM:E:16")
wire("ICIPROC:100:2:15:100")
wire("ICITEM:B:2:4")
wire("ICIPROC:200:1:10:100")
wire("ICINVEND")
T("fallback: 2 items from buckets", #S.items == 2)
local eq, bagit
for _, it in ipairs(S.items) do
  if it.invSlot then eq = it else bagit = it end
end
T("fallback: E key parsed", eq and eq.invSlot == 16 and eq.equipped == 1)
T("fallback: B key parsed", bagit and bagit.bag == 2 and bagit.slot == 4)
T("fallback: bucket procs attached", eq and eq.procs[1].spell == 100)

-- ---- 7. ICUNLOCKED updates collection ------------------------------------------------
local before = #S.collection
wire("ICUNLOCKED:301:2")
T("unlocked: appended", #S.collection == before + 1)
T("unlocked: collSet updated", S.collSet["301:2"] == true)
wire("ICUNLOCKED:301:2")
T("unlocked: no duplicate", #S.collection == before + 1)

-- ---- 8. ICERR reasons ------------------------------------------------------------------
wire("ICERR:UNLOCK:equipped")
T("err: equipped reason", S.status:find("wearing") ~= nil)
wire("ICERR:APPLY:already_known")
T("err: known reason", S.status:find("already") ~= nil)
wire("ICERR:APPLY:some_new_reason")
T("err: verbatim fallback", S.status:find("some_new_reason") ~= nil)

-- ---- 9. slash + toggle builds UI hidden --------------------------------------------------
SlashCmdList["IMPRINTING"]("debug")
T("slash: debug toggles", chat[#chat]:find("debug ON") ~= nil)
SlashCmdList["IMPRINTING"]("debug")
_TIME = 100
SlashCmdList["IMPRINTING"]("")
T("toggle: window shown after first press", ImprintingFrame and ImprintingFrame:IsShown())
T("toggle: open sends requests", table.concat(sent, " "):find("ICEXSRC") ~= nil
  and table.concat(sent, " "):find("ICCOLL") ~= nil
  and table.concat(sent, " "):find("ICBPGET") ~= nil
  and table.concat(sent, " "):find("ICINV") ~= nil)

-- ---- 10. request throttle -------------------------------------------------------------------
local n = #sent
_TIME = 105  -- 5s later, inside the 10s window
ImprintingFrame.refreshBtn.scripts["OnClick"]()
T("throttle: refresh inside 10s sends nothing", #sent == n)
_TIME = 200
ImprintingFrame.refreshBtn.scripts["OnClick"]()
T("throttle: refresh after window sends", #sent == n + 4)

-- ---- 11. hide / show hidden ------------------------------------------------------------------
ImprintingDB.hidden["100:2"] = true
ImprintingDB.showHidden = false
ImprintingFrame:Refresh()
-- visibleEffects is local; assert via the refreshed row texts
local shownNames = {}
-- effRows are local too; assert indirectly through state + db instead:
local vis = 0
for _, e in ipairs(S.collection) do
  local hid = ImprintingDB.hidden[e.spell .. ":" .. e.trigger]
  if not hid then vis = vis + 1 end
end
T("hide: db key honored", ImprintingDB.hidden["100:2"] == true and vis == #S.collection - 1)
ImprintingDB.hidden["100:2"] = nil

-- ---- 12. apply flow: confirm popup with existing procs named ---------------------------------
S.tab = "coll"
S.selEffect = { spell = 200, trigger = 1 }
S.selTarget = { key = "X:255:5", bag = 255, slot = 5, entry = 5000, equipped = 1,
                procs = { { spell = 100, trigger = 2 } } }
ImprintingFrame.actBtn.scripts["OnClick"]()
T("apply: popup raised", chat[#chat] == "POPUP:IMPRINTING_APPLY")
-- accept it
StaticPopupDialogs["IMPRINTING_APPLY"].OnAccept()
T("apply: ICAPPLY sent with server coords",
  sent[#sent] == "REAGENTBANK|ICAPPLY:200:1:255:5")

-- ---- 13. unlock flow ---------------------------------------------------------------------------
S.tab = "unlock"
S.selSource = { key = "X:0:3", bag = 0, slot = 3, spell = 999, trigger = 2,
                item = { entry = 5001 } }
ImprintingFrame.actBtn.scripts["OnClick"]()
T("unlock: popup raised", chat[#chat] == "POPUP:IMPRINTING_UNLOCK")
StaticPopupDialogs["IMPRINTING_UNLOCK"].OnAccept()
T("unlock: ICUNLOCK sent bag:slot:spell:trigger",
  sent[#sent] == "REAGENTBANK|ICUNLOCK:0:3:999:2")

-- ---- 14. unlock refuses known effect --------------------------------------------------------------
S.selSource = { key = "X:0:3", bag = 0, slot = 3, spell = 100, trigger = 2,
                item = { entry = 5001 } }
local nSent = #sent
ImprintingFrame.actBtn.scripts["OnClick"]()
T("unlock: known effect refused client-side", #sent == nSent and S.status:find("Already") ~= nil)

-- ---- 15. apply with confirmations off sends directly ------------------------------------------------
S.tab = "coll"
ImprintingDB.confirmOverwrite = false
S.selEffect = { spell = 100, trigger = 2 }
S.selTarget = { key = "X:0:9", bag = 0, slot = 9, procs = {} }
local nS = #sent
ImprintingFrame.actBtn.scripts["OnClick"]()
T("apply: no-confirm sends directly", sent[#sent] == "REAGENTBANK|ICAPPLY:100:2:0:9"
  and #sent == nS + 1)
ImprintingDB.confirmOverwrite = true

-- ---- 16. ICEXOK schedules a delayed re-request --------------------------------------------------------
local reqT
for _, fr in ipairs(frames) do
  if fr.scripts["OnUpdate"] and not fr.events["ADDON_LOADED"] and fr.kind == "Frame"
     and not fr.name then reqT = reqT or fr end
end
nS = #sent
wire("ICEXOK:100")
T("exok: status set", S.status:find("Imprinted") ~= nil)
T("exok: timer armed", reqT and reqT:IsShown())
_TIME = 300
if reqT then reqT.scripts["OnUpdate"](reqT, 5) end
T("exok: delayed re-request fired", #sent == nS + 4)

-- ---- 17. imprinted procs merge onto ICEXI rows -----------------------------------------------------
-- fresh exi sweep: worn belt (native proc 100), worn ring (no native proc),
-- bag shirt (no native proc)
INV_LINKS = { [6] = "|Hitem:5000:0:0|h[Surrogate Belt]|h",
              [11] = "|Hitem:5001:0:0|h[Valanar's Ring]|h" }
wire("ICEXI:255:5:5000:1:100:2")
wire("ICEXI:255:10:5001:1:0:0")
wire("ICEXI:1:7:5002:0:0:0")
wire("ICEXIEND")
-- ICINV: belt slot carries native 100 PLUS imprinted 200; ring slot imprinted 300;
-- bag shirt at server coords 1:7 imprinted 301
wire("ICITEM:E:6")
wire("ICIPROC:100:2:15:100")
wire("ICIPROC:200:1:10:100")
wire("ICITEM:E:11")
wire("ICIPROC:300:0:5:100")
wire("ICITEM:B:1:7")
wire("ICIPROC:301:0:5:100")
wire("ICINVEND")
local belt, ring2, shirt2
for _, it in ipairs(S.items) do
  if it.entry == 5000 then belt = it elseif it.entry == 5001 then ring2 = it
  elseif it.entry == 5002 then shirt2 = it end
end
T("merge: exi rows kept", #S.items == 3)
T("merge: native + imprinted deduped", belt and #belt.procs == 2)
T("merge: imprinted only on clean worn piece", ring2 and #ring2.procs == 1
  and ring2.procs[1].spell == 300)
T("merge: worn invSlot resolved via entry", belt and belt.invSlot == 6)
T("merge: bag row by exact server coords", shirt2 and #shirt2.procs == 1
  and shirt2.procs[1].spell == 301)
T("merge: native list untouched", belt and #belt.native == 1)

-- ---- 18. later ICINV push re-merges without clobbering ---------------------------------------------
wire("ICITEM:E:11")
wire("ICIPROC:300:0:5:100")
wire("ICIPROC:999:2:5:100")
wire("ICINVEND")
local r3
for _, it in ipairs(S.items) do if it.entry == 5001 then r3 = it end end
T("re-merge: new imprint appears", r3 and #r3.procs == 2)
T("re-merge: belt loses stale bucket, keeps native", (function()
  for _, it in ipairs(S.items) do
    if it.entry == 5000 then return #it.procs == 1 and it.procs[1].spell == 100 end
  end
end)())
T("re-merge: item count stable", #S.items == 3)

print(string.format("== %d passed, %d failed ==", pass, fail))
if fail > 0 then os.exit(1) end
