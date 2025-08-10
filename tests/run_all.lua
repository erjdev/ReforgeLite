-- Runner to execute all test files.
__REFORGE_TEST_ACCUMULATE=true
dofile('tests/test_harness.lua')
dofile('tests/test_unholy_dk.lua')
dofile('tests/test_reforge_engine.lua')
RunReforgeTests()
