function love.conf(t)
    t.title = "Spatula GPU Scheduler Test"
    t.version = "11.4"
    t.window.width = 1280
    t.window.height = 720
    t.window.vsync = 0  -- Disable vsync for accurate benchmarking
    t.console = true    -- Enable console on Windows
end
