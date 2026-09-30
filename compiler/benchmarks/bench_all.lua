-- benchmarks/bench_all.lua
-- Run all compilation benchmarks
-- Run with: lua5.4 benchmarks/bench_all.lua

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

print("================================================================================")
print("                    SPATULA COMPILATION BENCHMARKS")
print("================================================================================")
print("")
print("Comparing interpreted (closure-based) vs compiled (inlined code) performance.")
print("Higher speedup = more benefit from compilation.")
print("")

-- Run each benchmark
print("\n")
dofile("benchmarks/bench_forms.lua")

print("\n")
dofile("benchmarks/bench_triggers.lua")

print("\n")
dofile("benchmarks/bench_distributions.lua")

print("\n================================================================================")
print("                              SUMMARY")
print("================================================================================")
print("")
print("  Compilation inlines all operations, eliminating:")
print("    - Function call overhead (closure dispatch)")
print("    - Runtime type checking")
print("    - Table lookups for upvalues")
print("")
print("  Benefits are most pronounced for:")
print("    - Complex compositions (unions, intersections)")
print("    - High-frequency operations (containment checks)")
print("    - Large point counts (distributions)")
print("")
