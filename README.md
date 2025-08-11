# ReforgeLite

Comprehensive overview of the core reforge optimization engine (`ReforgeEngine.lua`), with flow explanation, math model, complexity, and optimization notes.

---
## 1. Overview
ReforgeLite computes optimal reforges for WoW gear given:
- Stat weights
- Up to two stat caps (each supporting AtLeast / AtMost / Exactly conditions)
- Class/spec stat conversions (e.g. Spirit → Hit, Expertise → Hit)
- Race & special item multipliers (e.g. Human Spirit bonus, Amplification items)

It uses a **2D dynamic programming (DP)** approach over cumulative deltas to the *two* tracked cap stats, maximizing a weighted score while satisfying (or approaching) caps. Execution is **frame-sliced** with coroutines to avoid UI hitches.

---
## 2. High-Level Flow
```
Player clicks Compute
        ↓
StartCompute()  (create coroutine + schedule)
        ↓
Compute()
  ↓ InitReforgeClassic()
  ↓ Enumerate per-item reforge options
  ↓ DP combine states (ComputeReforgeCore)
  ↓ Evaluate/end-state feasibility (ChooseReforgeClassic)
  ↓ Apply chosen src/dst to items
  ↓ FinalizeReforge() → recompute aggregate stats
        ↓
Persist (pdb.method) + UI update → EndCompute()
```

---
## 3. Stat Transformation Pipeline
For a finalized solution, the effective stat vector after reforging is:

$$
	ext{method.stats} = \Bigl( (\text{BaseTotals} - \text{OriginalItemStats} + \text{AdjustedItemStats}) + \text{ReforgeDeltas} \Bigr) \cdot \text{Multipliers} + \text{ConversionAdjustments}
$$

Where:
- `BaseTotals` comes from live character stats via `getter()` on each tracked stat.
- `OriginalItemStats` and `AdjustedItemStats` differ if an ilvl cap or scaling applies.
- `ReforgeDeltas`: for each item with a reforge src→dst: remove 40% of src, add 40% to dst (WoW era reforge rule).
- `Multipliers`: race (e.g. Human Spirit ×1.03) + Amplification (ilvl-based scaling factor).
- `ConversionAdjustments`: derived from class/spec table; applied on net change of convertible source stat:
        $$
        \forall (s \to t, f) :\quad \text{stats}[t] \mathrel{+}= \operatorname{Round}\big((\text{stats}[s] - \text{oldstats}[s])\cdot f\big)
        $$

---
## 4. Class / Spec Conversions
Defined in a table mapping `playerClass` + specialization to a conversion structure:
- Form: `conversion[srcStatIndex][dstStatIndex] = factor`.
- Examples: `Expertise → Hit (1.0)` for casters in certain specs, or `Spirit → Hit` (full or partial) for hybrids.
- Populated at runtime (`GetConversion()`) using `C_SpecializationInfo.GetSpecialization()`.

---
## 5. Per-Item Reforge Options
For each item:
1. Gather raw per-stat amounts (possibly ilvl-capped variant).
2. Enumerate valid reforges: choose a source stat with value > 0 and a destination stat currently 0 on the item (historic rule).
3. Compute option deltas:
   - Weighted score delta excluding cap stats.
   - Cap stat deltas `d1`, `d2` (only two caps are tracked).
   - Include secondary effects from conversions both when *removing* (src) and *adding* (dst) stats.
4. Prune dominated options: keep best scoring option per unique `(d1,d2)` pair.

Option record structure:
```
{ d1 = Δcap1, d2 = Δcap2, src = statIndex?, dst = statIndex?, score = ΔweightedScore }
```

---
## 6. Dynamic Programming Model
Let:
- $ I $: number of reforgeable items.
- $ O_i $: options for item $ i $.
- State after processing $ i $ items parameterized by cumulative deltas $ (d_1, d_2) $.

Transition:
$$
S_i(d_1', d_2') = \max_{o \in O_i} \Bigl[ S_{i-1}(d_1' - \Delta d_{1,o},\; d_2' - \Delta d_{2,o}) + \Delta \text{score}_o \Bigr]
$$

Compressed key:
$$
 k = d_1 + d_2\cdot T,\quad T = 10000
$$

Reconstruction: store a growing *code string* where the $i$-th byte indexes the chosen option for item $i$.

Post-pass evaluation (`ChooseReforgeClassic`): iterate final states, reconstruct cap totals, add cap scoring/penalties, and pick best allowable solution (preference order: both caps met → partial → none).

---
## 7. Complexity
Let $ S_i $ be distinct states after item $ i $.

Time:
$$
T = \sum_{i=1}^{I} S_{i-1} \cdot O_i
$$

Worst-case (unrealistic, no merging):
$$
S_i \le \prod_{j=1}^{i} O_j
$$

Practical bound (delta grid density):
$$
S_i \approx D_{1,i} \cdot D_{2,i}
$$
Where $ D_{c,i} $ is distinct count of reachable $ d_c $ values.

Per-item cap delta magnitude (typical MoP-era secondary stat):
$$
|\Delta d_{c,\text{per item}}| \approx 0.4 \cdot \text{StatOnItem} \in [150, 300]
$$
If at most $ K_c $ items materially affect cap $ c $:
$$
|d_c| \lesssim K_c \cdot 300
$$

Memory (scores + code strings):
$$
	ext{Memory} \approx S_I (b_s + b_c)\quad b_s \approx 8\text{ bytes},\; b_c \approx I \text{ bytes}
$$
Typical: $ S_I \sim 1500\text{–}2500, I \sim 15 \Rightarrow <$ a few hundred KB with table overhead.

---
## 8. Performance Example
Assume:
- $ I = 15 $
- Average options $ O_i \approx 15 $
- Average states $ S_i $ stabilizes near 1700

Estimate:
$$
T \approx (\sum_{i=1}^{15} 1700) * 15 \approx 382{,}500 \text{ transitions (upper envelope)}
$$
Earlier empirical reasoning suggested ~180k *effective* transitions (due to growth phase). Frame-slicing (yield after `db.speed` loops) keeps each frame’s cost low.

Wall time on modern hardware: well below 50 ms aggregated (often <<), amortized across frames.

---
## 9. Bottlenecks
| Area | Cause | Impact |
|------|-------|--------|
| Code string building | `codes[k] .. char(j)` per improved state | GC & allocation overhead |
| Hash table churn | Many transient keys (scores/codes tables) | CPU + memory |
| Option generation | Nested loops over stat indices | Setup cost |
| Cap replay | Re-simulating deltas per final state | Extra passes |

---
## 10. Optimization Opportunities
1. **Parent-pointer reconstruction**: store `(prevKey, optionIndex)` instead of concatenating strings each step.
2. **Two-phase DP**: forward pass only scores + predecessor; single backward reconstruction for winning state.
3. **Dense state indexing**: detect min/max $ d_1, d_2 $ ranges and map to 2D array -> faster & lower overhead.
4. **Dominance pruning**: discard any option strictly worse in all of $(d_1,d_2,\text{score})$.
5. **Char cache**: precompute `byte -> char` table.
6. **Adaptive yield**: measure elapsed ms (via `debugprofilestop`) vs fixed loop counter.

---
## 11. Instrumentation (Suggested Hooks)
```lua
self.profile = { transitions = 0, states = {} }
-- In DP inner loop when considering an option:
self.profile.transitions = self.profile.transitions + 1
-- After finishing layer i:
self.profile.states[i] = currentStateCount
-- Around frame-sliced segments:
local t0 = debugprofilestop()
... segment ...
local elapsed = debugprofilestop() - t0
```
Memory delta:
```lua
local m0 = collectgarbage("count")
-- run compute
collectgarbage("collect")
local m1 = collectgarbage("count")
print("KB diff:", m1 - m0)
```

---
## 12. Edge Cases & Safeguards
- Items below ilvl 200 ignored for reforging.
- Caps normalized: if cap1 missing, swap; if both same stat, second disabled.
- Weight injection: if a converted source feeds a capped stat, its weight forced non-zero to allow beneficial movement.
- Spirit→Hit special handling: prefer reforging into Spirit if full conversion exists to retain flexibility.

---
## 13. Limitations
- Supports **exactly two** simultaneous caps (data model baked into state compression).
- Fixed key packing constant `T = 10000`; assumes $|d_1| < 10000$. Extremely large future item scales would require dynamic determination.
- Not trivially extensible to third cap (would need different DP strategy or heuristic search).

---
## 14. Glossary
| Term | Meaning |
|------|---------|
| Cap | Constraint on a stat (AtLeast / AtMost / Exactly) |
| Option | Single candidate reforge (src→dst or none) for one item |
| State | A cumulative pair `(d1,d2)` representing net movement relative to initial cap stats |
| Code | Reconstructive string storing chosen option indices per item |
| Conversion | Automatic stat translation (e.g., Spirit contributing to Hit) |
| Multiplier | Multiplicative stat increase (race / item effect) |

---
## 15. Quick Start (Conceptual)
1. Set weights & caps in UI.
2. Click Compute.
3. Wait while coroutine iterates (button text shows progress state externally).
4. See suggested reforges populated; apply in-game.

---
## 16. Potential Future Enhancements
- Add third cap via heuristic layered search (e.g., branch & bound + current DP core as inner solver).
- Replace string reconstruction with parent-pointer chain (reduces GC churn markedly).
- Provide on-screen profiling overlay for advanced users.
- Integrate dominance pruning statistics.

---
## 17. Mathematical Summary
Objective: maximize
$$
	ext{Score} = \sum_{s \notin Caps} w_s \cdot (\Delta s) + \sum_{c \in Caps} f_c(s_c)
$$
Subject to (for each cap $ c $) constraints depending on method type:
$$
	ext{AtLeast: } s_c \ge v,\quad \text{AtMost: } s_c \le v,\quad \text{Exactly: } s_c = v
$$
Where $ s_c $ after reforging includes conversions & multipliers, and $ f_c $ is a scoring adjustment rewarding closeness or satisfaction (implemented via `GetCapScore`).

---
## 18. Attribution
This documentation summarizes logic in `ReforgeEngine.lua` (MoP-era reforge model). World of Warcraft references and APIs are property of Blizzard Entertainment. This file is an auxiliary explanation, not part of the original gameplay systems.

---
## 19. License Notice
(Insert project license details here if not already specified elsewhere.)

---
## 20. Feedback
Open an issue or submit a PR if you spot inaccuracies or want deeper instrumentation guidance.
