--- Spatula Field Native FFI Bindings
--- @module spatula.compiler.native.field_ffi
---
--- Provides native SIMD-accelerated field sampling via LuaJIT FFI.
--- Falls back gracefully if FFI or library unavailable.

local ffi = require("ffi")

ffi.cdef[[
    void field_sample_batch(
        const float* src_x,
        const float* src_y,
        const float* src_radius,
        const float* src_inv_radius,
        const float* src_value,
        const float* src_falloff,
        int src_count,
        const float* pos_x,
        const float* pos_y,
        float* out_values,
        int query_count,
        float base_value
    );

    void field_sample_batch_gradient(
        const float* src_x,
        const float* src_y,
        const float* src_radius,
        const float* src_inv_radius,
        const float* src_value,
        const float* src_falloff,
        int src_count,
        const float* pos_x,
        const float* pos_y,
        float* out_values,
        float* out_gx,
        float* out_gy,
        int query_count,
        float base_value
    );

    void field_sample_batch_fast(
        const float* src_x,
        const float* src_y,
        const float* src_radius,
        const float* src_inv_radius,
        const float* src_value,
        const float* src_falloff,
        int src_count,
        const float* pos_x,
        const float* pos_y,
        float* out_values,
        int query_count,
        float base_value
    );

    // Form containment batch functions
    void circle_contains_batch(
        float ox, float oy, float radius_sq,
        const float* xs, const float* ys,
        uint8_t* out,
        int count
    );

    void rect_contains_batch(
        float ox, float oy, float half_w, float half_h,
        const float* xs, const float* ys,
        uint8_t* out,
        int count
    );

    void ellipse_contains_batch(
        float ox, float oy, float rx, float ry,
        const float* xs, const float* ys,
        uint8_t* out,
        int count
    );

    void circle_contains_batch_fast(
        float ox, float oy, float radius_sq,
        const float* xs, const float* ys,
        uint8_t* out,
        int count
    );
]]

-- Try multiple library paths (with extensions for macOS)
local lib = nil
local sourceDir = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./"
local paths = {
    sourceDir .. "libfield_native.so",
    sourceDir .. "libfield_native.dylib",
    sourceDir .. "field_native.dll",
    "libfield_native",
    "./libfield_native",
    "./compiler/native/libfield_native",
    "../native/libfield_native",
    -- macOS requires .dylib extension
    "libfield_native.dylib",
    "./libfield_native.dylib",
    "./compiler/native/libfield_native.dylib",
    "../native/libfield_native.dylib",
    "../../compiler/native/libfield_native.dylib",
}

for _, path in ipairs(paths) do
    local ok, result = pcall(ffi.load, path)
    if ok then
        lib = result
        break
    end
end

if not lib then
    error("Could not load libfield_native library")
end

return lib
