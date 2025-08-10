-- Simple test harness for ReforgeLite engine logic (offline environment)
-- NOTE: This is a lightweight harness; WoW API references are stubbed.

-- Global shared test registry so additional files can add tests before running.
local tests = _G.__ReforgeTests or {}
_G.__ReforgeTests = tests

local function assertEquals(a,b,msg)
  if a ~= b then error((msg or 'assertEquals failed') .. '\nexpected: '..tostring(b)..'\nactual  : '..tostring(a), 2) end
end
local function assertTrue(c,msg) if not c then error(msg or 'assertTrue failed',2) end end
local function approxEquals(a,b,eps,msg) eps = eps or 1e-6 if math.abs(a-b) > eps then error((msg or 'approxEquals failed').. string.format('\nexpected: %.6f\nactual  : %.6f', b,a),2) end end

local function addTest(name, fn) tests[#tests+1] = {name=name, fn=fn} end
_G.AddReforgeTest = addTest
_G.AssertReforgeEquals = assertEquals
_G.AssertReforgeTrue = assertTrue
_G.ApproxReforgeEquals = approxEquals

-- Minimal stubs & module load
local addonTable = {
  REFORGE_COEFF = 0.4,
  statIds = {SPIRIT=1,HASTE=2,MASTERY=3,HIT=4,EXP=5},
  GetItemStatsUp = function() return {} end,
  MergeTables = function(dst, src) for k,v in pairs(src) do dst[k]=v end end,
  GetItemInfoUp = function() return nil,nil end,
  GetRandPropPoints = function() return 0 end,
  StatCapMethods = { AtLeast = 1, AtMost = 2, Exactly = 3 },
  GUI = { Unlock = function() end },
  DeepCopy = function(t, cache)
    if type(t) ~= 'table' then return t end
    cache = cache or {}
    if cache[t] then return cache[t] end
    local c = {}
    cache[t] = c
    for k,v in pairs(t) do c[k] = type(v)=='table' and addonTable.DeepCopy(v, cache) or v end
    return c
  end,
}

local ReforgeLite = { itemData = {}, itemStats = {}, pdb={weights={},caps={{stat=0,points={}}, {stat=0,points={}}}}, reforgeTable={}, db={speed=1e9}, capPresets={{getter=nil}}, computeButton={RenderText=function() end}, conversion={}, methodDebug=nil }
addonTable.ReforgeLite = ReforgeLite
_G.Round = function(x) return math.floor(x+0.5) end
_G.SPEC_DRUID_BALANCE=1
_G.SPEC_MONK_MISTWEAVER=1
_G.SPEC_PRIEST_SHADOW=3
_G.SPEC_SHAMAN_RESTORATION=3
_G.addonName='ReforgeLite'
_G.RunNextFrame=function(cb) cb() end -- immediate for tests
_G.debugprofilestop = function() return os.clock()*1000 end
_G.C_SpecializationInfo = { GetSpecialization=function() return nil end }
_G.addonTable = addonTable
_G.tinsert = table.insert
_G.floor = math.floor

-- Provide default GetCapScore used in ChooseReforgeClassic (returns 0 impact).
function ReforgeLite:GetCapScore()
  return 0
end

function ReforgeLite:UpdateMethodCategory() end

-- Inject file under test
local enginePath = 'ReforgeEngine.lua'
local chunk, loadErr = loadfile(enginePath)
if not chunk then error('Failed to load engine: '..tostring(loadErr)) end
-- Call chunk with addonName, addonTable (matching addon file contract: local addonName, addonTable = ...)
chunk('ReforgeLite', addonTable)

function _G.ReloadEngine()
  local chunk2, err2 = loadfile(enginePath)
  if not chunk2 then error('ReloadEngine failed: '..tostring(err2)) end
  chunk2('ReforgeLite', addonTable)
end

-- Helper to build fake reforge options
local function makeOpt(d1,d2,score) return {d1=d1,d2=d2,score=score} end

addTest('ComputeReforgeCore basic combination aggregation', function()
  local opts = {
    { makeOpt(0,0, 10), makeOpt(1,0, 12) },
    { makeOpt(0,0, 5), makeOpt(0,1, 7) },
  }
  local scores, codes = ReforgeLite:ComputeReforgeCore(opts)
  assertTrue(next(scores) ~= nil, 'scores table empty')
  local maxScore=-1
  for _,s in pairs(scores) do if s>maxScore then maxScore=s end end
  -- Expect best is 12 + 7 = 19
  assertEquals(19, maxScore, 'Unexpected maxScore')
end)

function _G.RunReforgeTests()
  local passed, failed = 0,0
  for _,t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
      io.stdout:write('[PASS] '..t.name..'\n')
      passed=passed+1
    else
      io.stdout:write('[FAIL] '..t.name..'\n'..err..'\n')
      failed=failed+1
    end
  end
  io.stdout:write(string.format('\nSummary: %d passed, %d failed\n', passed, failed))
  if failed>0 then os.exit(1) end
end

-- Auto-run unless accumulation mode is enabled
if not _G.__REFORGE_TEST_ACCUMULATE then
  RunReforgeTests()
end
