-- Runner to execute all test files.
__REFORGE_TEST_ACCUMULATE=true
require('test_harness')
dofile('test_unholy_dk.lua')
RunReforgeTests()
