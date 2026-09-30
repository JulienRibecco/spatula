local Support = { passed = 0, failed = 0, skipped = 0 }

function Support.test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        Support.passed = Support.passed + 1
        print("  ✓ " .. name)
    else
        Support.failed = Support.failed + 1
        print("  ✗ " .. name .. ": " .. tostring(err))
    end
end

function Support.benchmark(name, fn)
    if os.getenv("SPATULA_BENCHMARKS") == "1" then
        Support.test(name, fn)
    else
        Support.skipped = Support.skipped + 1
        print("  SKIP benchmark: " .. name)
    end
end

function Support.finish()
    print(string.format("\n%d passed, %d failed, %d benchmarks skipped",
        Support.passed, Support.failed, Support.skipped))
    if Support.failed > 0 then os.exit(1) end
end

return Support
