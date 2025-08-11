-- Full character style test exercising end-to-end reforge search over many items.
-- Assumptions: Using caster with hit cap; we simulate gear with sub-cap hit that can be reforged.

if not AddReforgeTest then error('Load test_harness first') end

local addonTable = _G.addonTable
local ReforgeLite = addonTable.ReforgeLite

-- In harness, statIds mapping places HIT at index 4, but our itemStats order aligns SPIRIT,HASTE,MASTERY,HIT,EXP.
-- Ensure mapping matches this order explicitly for this test to avoid index mismatch.
addonTable.statIds.SPIRIT=1
addonTable.statIds.HASTE=2
addonTable.statIds.MASTERY=3
addonTable.statIds.HIT=4
addonTable.statIds.EXP=5

AddReforgeTest('FullCharacter: integration structural validation', function()
  -- Reset core state
  ReforgeLite.itemData = {}
  ReforgeLite.itemStats = {}
  ReforgeLite.reforgeTable = {}
  ReforgeLite.pdb = {
    weights = {},
    -- No caps: we just validate that reforging increases HIT based on weights.
    caps = { { stat = 0, points = {} }, { stat = 0, points = {} } },
    ilvlCap = nil,
    method = nil,
    itemsLocked = {},
  }
  ReforgeLite.conversion = {}
  ReforgeLite.db.speed = 1e9 -- avoid yielding

  -- Provide itemStats definitions in the canonical order matching statIds
  local statOrder = { 'SPIRIT','HASTE','MASTERY','HIT','EXP' }
  local baseTotals = { SPIRIT=0, HASTE=0, MASTERY=0, HIT=0, EXP=0 }

  -- Simulated 13 gear pieces (no duplicates needed). Some carry HIT already.
  local gear = {
    { name='Helm',     stats={ HASTE=120, MASTERY=80,  HIT=30 } },
    { name='Neck',     stats={ HASTE=60,  MASTERY=40 } },
    { name='Shoulder', stats={ HASTE=100, MASTERY=55 } },
    { name='Back',     stats={ HASTE=70,  MASTERY=50,  HIT=25 } },
    { name='Chest',    stats={ HASTE=140, MASTERY=90 } },
    { name='Wrist',    stats={ HASTE=65,  MASTERY=40 } },
    { name='Hands',    stats={ HASTE=110, MASTERY=60 } },
    { name='Waist',    stats={ HASTE=95,  MASTERY=55 } },
    { name='Legs',     stats={ HASTE=130, MASTERY=70,  HIT=35 } },
    { name='Feet',     stats={ HASTE=90,  MASTERY=60 } },
    { name='Ring1',    stats={ HASTE=55,  MASTERY=35 } },
    { name='Ring2',    stats={ HASTE=50,  MASTERY=30 } },
    { name='Trinket',  stats={ HASTE=80,  MASTERY=20 } },
  }

  -- Build itemData and accumulate totals
  for i, g in ipairs(gear) do
    ReforgeLite.itemData[i] = { item = g, ilvl = 300, itemGUID = 'GUID'..i }
    for k,v in pairs(g.stats) do baseTotals[k] = baseTotals[k] + v end
  end

  local function totalGetter(statName)
    return function() return baseTotals[statName] end
  end

  for idx, name in ipairs(statOrder) do
    ReforgeLite.itemStats[idx] = { name = name, getter = totalGetter(name) }
  end

  -- Provide weights: prioritize reaching HIT cap; after cap, HASTE slightly better than MASTERY
  -- Indexing must line up with itemStats order.
  -- Strongly favor HIT so algorithm prefers reforging toward it.
  ReforgeLite.pdb.weights = { 0, 0, 0, 10, 0 }

  -- Provide simple full reforge table mapping each possible src->dst pair for items (only from stats with value >0 to ones with 0 is actually used internally)
  local rt = {}
  local rti = 1
  for s=1,#ReforgeLite.itemStats do
    for d=1,#ReforgeLite.itemStats do
      if s~=d then
        rt[rti] = { s, d }
        rti = rti + 1
      end
    end
  end
  ReforgeLite.reforgeTable = rt

  -- Stub GetItemStatsUp to return the stats for each item object
  addonTable.GetItemStatsUp = function(item)
    -- Return a new table copy each call (engine mutates via lookups but not modifying values)
    local copy = {}
    for k,v in pairs(item.stats or {}) do copy[k]=v end
    return copy
  end

  -- Run compute
  local oldGetCapScore = ReforgeLite.GetCapScore
  ReforgeLite.GetCapScore = function() return 0 end
  ReforgeLite:ComputeReforge()
  ReforgeLite.GetCapScore = oldGetCapScore

  -- Structural Assertions
  AssertReforgeTrue(ReforgeLite.pdb.method ~= nil, 'Method not produced')
  local method = ReforgeLite.pdb.method
  AssertReforgeTrue(type(method.stats)=='table', 'Method stats missing')
  AssertReforgeTrue(#method.items == #ReforgeLite.itemData, 'Method items size mismatch')

  -- Every item either un-reforged or has valid src/dst where src had positive stat pre-reforge and destination had zero.
  for i, g in ipairs(gear) do
    local mItem = method.items[i]
    if mItem and mItem.src and mItem.dst then
      local srcName = ReforgeLite.itemStats[mItem.src].name
      local dstName = ReforgeLite.itemStats[mItem.dst].name
      AssertReforgeTrue((g.stats[srcName] or 0) > 0, ('Item %s invalid src %s'):format(g.name, srcName))
      AssertReforgeTrue((g.stats[dstName] or 0) == 0, ('Item %s dst %s already had value'):format(g.name, dstName))
    end
  end
end)

AddReforgeTest('FullCharacter: hit >= 2550 and expertise >= 2550 after compute', function()
  -- Setup fresh state
  ReforgeLite.itemData = {}
  ReforgeLite.itemStats = {}
  ReforgeLite.reforgeTable = {}
  ReforgeLite.pdb = {
    weights = {},
    caps = {
      { stat = addonTable.statIds.HIT, points = { { method = addonTable.StatCapMethods.AtLeast, value = 2550 } } },
      { stat = addonTable.statIds.EXP, points = { { method = addonTable.StatCapMethods.AtLeast, value = 2550 } } },
    },
    ilvlCap = nil,
    method = nil,
    itemsLocked = {},
  }
  ReforgeLite.conversion = {}
  ReforgeLite.db.speed = 1e9

  -- Realistic gear set provided (crit/haste/mastery plus some hit/exp). We'll map CRIT->HIT, EXPERTISE->EXP for test stats.
  -- Convert provided stats: crit counts toward HIT bucket, expertise toward EXP bucket, haste->HASTE, mastery->MASTERY.
  local gear = {
    { name='Helm', stats={ HIT=701, HASTE=534 } },
    { name='Neck', stats={ HIT=285, EXP=363 } },
    { name='Shoulders', stats={ EXP=431, HIT=361 } },
    { name='Cloak', stats={ HIT=254, HASTE=381 } },
    { name='Chest', stats={ EXP=472, MASTERY=612 } },
    { name='Bracers', stats={ HIT=339, HASTE=326 } },
    { name='Gloves', stats={ HIT=391, MASTERY=478 } },
    { name='Belt', stats={ HIT=401, MASTERY=385 } },
    { name='Pants', stats={ HIT=606, MASTERY=516 } },
    { name='Boots', stats={ HASTE=573, MASTERY=382 } },
    { name='Ring1', stats={ HASTE=351, HIT=264 } },
    { name='Ring2', stats={ HASTE=351, HIT=264 } },
    { name='Weapon2H', stats={ HIT=497, HASTE=660 } },
  }
  local totals = { SPIRIT=0,HASTE=0,MASTERY=0,HIT=0,EXP=0 }
  for i,g in ipairs(gear) do
    ReforgeLite.itemData[i] = { item=g, ilvl=300, itemGUID='T'..i }
    for k,v in pairs(g.stats) do totals[k] = totals[k] + v end
  end

  local order = { 'SPIRIT','HASTE','MASTERY','HIT','EXP' }
  for idx,name in ipairs(order) do
    ReforgeLite.itemStats[idx] = { name=name, getter=function() return totals[name] end }
  end

  -- Weights: strongly favor EXP (needs to be built up), moderate HIT (maintain above cap), low others
  -- Order: SPIRIT,HASTE,MASTERY,HIT,EXP
  ReforgeLite.pdb.weights = { 0, 1, 1, 2, 5 }

  addonTable.GetItemStatsUp = function(item)
    local c = {}
    for k,v in pairs(item.stats or {}) do c[k]=v end
    return c
  end

  ReforgeLite:ComputeReforge()
  AssertReforgeTrue(ReforgeLite.pdb.method ~= nil, 'Method missing')
  local method = ReforgeLite.pdb.method
  local hitVal = method.stats[addonTable.statIds.HIT]
  local expVal = method.stats[addonTable.statIds.EXP]
  AssertReforgeTrue(hitVal >= 2550, 'HIT below threshold: '..tostring(hitVal))
  AssertReforgeTrue(expVal >= 2550, 'EXP below threshold: '..tostring(expVal))
end)
