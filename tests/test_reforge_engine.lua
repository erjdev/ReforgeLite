-- Tests focused on ReforgeEngine core behaviors.
-- Loaded after test_harness.lua

if not AddReforgeTest then error('Load test_harness.lua first') end

local addonTable = _G.addonTable
local ReforgeLite = addonTable.ReforgeLite

-- Helper to reset minimal mutable state between tests
local function reset()
  ReforgeLite.itemData = {}
  ReforgeLite.itemStats = {}
  ReforgeLite.pdb = { weights={}, caps={{stat=0,points={}}, {stat=0,points={}}}, ilvlCap=nil, method=nil, itemsLocked={} }
  ReforgeLite.reforgeTable = {}
  ReforgeLite.conversion = {}
end

AddReforgeTest('GetStatMultipliers adds human spirit racial and amplification', function()
  reset()
  _G.playerRace = 'HUMAN'
  _G.addonTable.playerRace = 'HUMAN'
  -- Reload to ensure local playerRace captured
  ReloadEngine()
  ReforgeLite.itemData = {
    { itemId = 123, item = {} },
  }
  local called = 0
  addonTable.GetItemInfoUp = function(id)
    return id, 500 -- id, ilvl
  end
  addonTable.AmplificationItems = { [123] = true }
  addonTable.GetRandPropPoints = function(ilvl, _)
    called = called + 1
    return 840 -- yields factor 1 + round(840/420)*0.01 = 1.02
  end
  local mult = ReforgeLite:GetStatMultipliers()
  AssertReforgeTrue(mult[addonTable.statIds.SPIRIT] > 1.0, 'Spirit multiplier missing')
  AssertReforgeTrue(mult[addonTable.statIds.HASTE] > 1.0, 'Haste multiplier missing')
  AssertReforgeTrue(mult[addonTable.statIds.MASTERY] > 1.0, 'Mastery multiplier missing')
  AssertReforgeEquals(1, called, 'GetRandPropPoints calls expected')
end)

AddReforgeTest('GetConversion applies caster base for MAGE (EXP->HIT)', function()
  reset()
  _G.addonTable.playerClass = 'MAGE'
  _G.playerClass = 'MAGE'
  _G.C_SpecializationInfo.GetSpecialization = function() return nil end
  ReloadEngine() -- ensure local STAT_CONVERSIONS re-evaluated with current globals
  ReforgeLite:GetConversion()
  AssertReforgeTrue(ReforgeLite.conversion[addonTable.statIds.EXP] ~= nil, 'Expected EXP key')
  AssertReforgeEquals(1, ReforgeLite.conversion[addonTable.statIds.EXP][addonTable.statIds.HIT])
end)

AddReforgeTest('CapAllows enforces AtLeast / AtMost / Exactly', function()
  reset()
  local cap = { points = {
    { method = addonTable.StatCapMethods.AtLeast, value = 50 },
    { method = addonTable.StatCapMethods.AtMost, value = 70 },
  }}
  AssertReforgeTrue(ReforgeLite:CapAllows(cap, 60))
  AssertReforgeTrue(not ReforgeLite:CapAllows(cap, 40))
  AssertReforgeTrue(not ReforgeLite:CapAllows(cap, 90))
  cap.points[#cap.points+1] = { method = addonTable.StatCapMethods.Exactly, value = 65 }
  AssertReforgeTrue(ReforgeLite:CapAllows(cap, 65))
  AssertReforgeTrue(not ReforgeLite:CapAllows(cap, 64))
end)

AddReforgeTest('ComputeReforgeCore large branching yields best aggregate', function()
  reset()
  -- Ensure yield threshold high to avoid coroutine scheduling semantics interfering
  ReforgeLite.db.speed = 1e9
  local function make(d1,d2,score) return {d1=d1,d2=d2,score=score} end
  local opts = {
    { make(0,0, 5), make(1,0, 9), make(0,1, 8) },
    { make(0,0, 4), make(0,1, 7) },
    { make(0,0, 3), make(1,0, 6) },
  }
  local scores = select(1, ReforgeLite:ComputeReforgeCore(opts))
  local maxScore = -1
  for _,s in pairs(scores) do if s>maxScore then maxScore=s end end
  AssertReforgeEquals(9+7+6, maxScore)
end)

AddReforgeTest('ChooseReforgeClassic respects caps and picks valid solution', function()
  reset()
  -- Provide necessary pieces for ChooseReforgeClassic logic
  ReforgeLite.GetCapScore = function(_, cap, value) return 0 end
  local data = {
    caps = {
      { stat = 1, init = 45, points = { { method = addonTable.StatCapMethods.AtLeast, value = 50 } } },
      { stat = 2, init = 0, points = {} },
    }
  }
  local opt1 = { {d1=0,d2=0,score=5}, {d1=5,d2=0,score=3} } -- option 2 helps reach cap but lower raw score
  local opt2 = { {d1=0,d2=0,score=4} } -- only one choice
  local reforgeOptions = { opt1, opt2 }
  local scores = { [0]=0, } -- synthetic (k indexes building path) purposely small
  local codes = { [0]=string.char(1)..string.char(1) } -- choose first of each list (keeps under cap) but we want reaching cap
  -- We craft a second entry where path chooses second option in first list giving +5 to stat1
  scores[5] = 3+4 -- aggregated base score
  codes[5] = string.char(2)..string.char(1)
  local chosen = ReforgeLite:ChooseReforgeClassic(data, reforgeOptions, scores, codes)
  AssertReforgeEquals(codes[5], chosen, 'Cap reaching path expected')
end)

AddReforgeTest('IsItemLocked evaluates item presence, ilvl and lock flag', function()
  reset()
  ReforgeLite.itemData = {
    { item=nil, ilvl=250, itemGUID='a' },
    { item={}, ilvl=100, itemGUID='b' },
    { item={}, ilvl=250, itemGUID='c' },
  }
  ReforgeLite.pdb.itemsLocked = { c=true }
  AssertReforgeTrue(ReforgeLite:IsItemLocked(1), 'Missing item should lock')
  AssertReforgeTrue(ReforgeLite:IsItemLocked(2), 'Low ilvl should lock')
  AssertReforgeTrue(ReforgeLite:IsItemLocked(3), 'Explicit lock flag should lock')
end)

AddReforgeTest('ComputeReforge integration runs without error', function()
  reset()
  -- Provide DeepCopy upvalue expected by engine via addonTable
  _G.addonTable.DeepCopy = _G.addonTable.DeepCopy or function(t) return t end
  -- Provide minimal stats and data so loops iterate lightly
  ReforgeLite.itemStats = {
    { name='HIT', getter=function() return 100 end },
    { name='HASTE', getter=function() return 200 end },
  }
  addonTable.statIds.HIT = 4 -- maintain mapping but names in itemStats drive lookups
  addonTable.statIds.HASTE = 2
  ReforgeLite.itemData = {
    { item = {id=1}, ilvl=300, itemGUID='g1' },
  }
  ReforgeLite.reforgeTable = { [1] = {1,2} }
  ReforgeLite.pdb.weights = { 1, 2 }
  ReforgeLite.pdb.caps = { { stat=0, points={} }, { stat=0, points={} } }
  addonTable.GetItemStatsUp = function(_, ilvlCap)
    return { HIT = 50, HASTE = 70 }
  end
  ReforgeLite.db.speed = 1e9
  ReforgeLite:ComputeReforge()
  AssertReforgeTrue(ReforgeLite.pdb.method ~= nil, 'Method should be assigned after compute')
end)
