// field_native.c - Native SIMD batch operations for Spatula
//
// Compile (macOS ARM):
//   clang -O3 -march=native -shared -fPIC -o libfield_native.dylib field_native.c
//
// Compile (macOS x86):
//   clang -O3 -msse4.1 -shared -fPIC -o libfield_native.dylib field_native.c
//
// Compile (Linux):
//   gcc -O3 -march=native -shared -fPIC -o libfield_native.so field_native.c

#include <stdint.h>
#include <math.h>

//==============================================================================
// FORM CONTAINMENT FUNCTIONS
//==============================================================================

// Batch circle containment test
// out[i] = 1 if point is inside circle, 0 otherwise
void circle_contains_batch(
    float ox, float oy, float radius_sq,
    const float* xs, const float* ys,
    uint8_t* out,
    int count
) {
    for (int i = 0; i < count; i++) {
        float dx = xs[i] - ox;
        float dy = ys[i] - oy;
        out[i] = (dx * dx + dy * dy) <= radius_sq ? 1 : 0;
    }
}

// Batch rectangle containment test
void rect_contains_batch(
    float ox, float oy, float half_w, float half_h,
    const float* xs, const float* ys,
    uint8_t* out,
    int count
) {
    for (int i = 0; i < count; i++) {
        float dx = xs[i] - ox;
        float dy = ys[i] - oy;
        // Use fabs for proper absolute value
        out[i] = (dx >= -half_w && dx <= half_w &&
                  dy >= -half_h && dy <= half_h) ? 1 : 0;
    }
}

// Batch ellipse containment test
void ellipse_contains_batch(
    float ox, float oy, float rx, float ry,
    const float* xs, const float* ys,
    uint8_t* out,
    int count
) {
    float inv_rx = 1.0f / rx;
    float inv_ry = 1.0f / ry;
    for (int i = 0; i < count; i++) {
        float dx = (xs[i] - ox) * inv_rx;
        float dy = (ys[i] - oy) * inv_ry;
        out[i] = (dx * dx + dy * dy) <= 1.0f ? 1 : 0;
    }
}

// Optimized 4-wide circle containment (better vectorization)
void circle_contains_batch_fast(
    float ox, float oy, float radius_sq,
    const float* xs, const float* ys,
    uint8_t* out,
    int count
) {
    int i4 = count & ~3;  // Round down to multiple of 4

    // Process 4 at a time
    for (int i = 0; i < i4; i += 4) {
        float dx0 = xs[i+0] - ox, dy0 = ys[i+0] - oy;
        float dx1 = xs[i+1] - ox, dy1 = ys[i+1] - oy;
        float dx2 = xs[i+2] - ox, dy2 = ys[i+2] - oy;
        float dx3 = xs[i+3] - ox, dy3 = ys[i+3] - oy;

        out[i+0] = (dx0*dx0 + dy0*dy0) <= radius_sq ? 1 : 0;
        out[i+1] = (dx1*dx1 + dy1*dy1) <= radius_sq ? 1 : 0;
        out[i+2] = (dx2*dx2 + dy2*dy2) <= radius_sq ? 1 : 0;
        out[i+3] = (dx3*dx3 + dy3*dy3) <= radius_sq ? 1 : 0;
    }

    // Remainder
    for (int i = i4; i < count; i++) {
        float dx = xs[i] - ox;
        float dy = ys[i] - oy;
        out[i] = (dx * dx + dy * dy) <= radius_sq ? 1 : 0;
    }
}

//==============================================================================
// FIELD SAMPLING FUNCTIONS
//==============================================================================

// Source data in Structure-of-Arrays layout (cache-friendly)
typedef struct {
    const float* x;         // Source X positions
    const float* y;         // Source Y positions
    const float* radius;    // Source radii
    const float* inv_radius;// 1/radius (precomputed)
    const float* value;     // Source values
    const float* falloff;   // Precomputed falloff LUT (256 entries per source)
    int count;
} FieldSources;

// Linear interpolation in falloff LUT
static inline float lut_sample(const float* lut, float t) {
    // Clamp to [0, 1]
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;

    float idx = t * 255.0f;
    int i0 = (int)idx;
    int i1 = i0 < 255 ? i0 + 1 : 255;
    float frac = idx - (float)i0;

    return lut[i0] * (1.0f - frac) + lut[i1] * frac;
}

// Batch sample field at multiple positions (add blend mode)
void field_sample_batch(
    const float* src_x,
    const float* src_y,
    const float* src_radius,
    const float* src_inv_radius,
    const float* src_value,
    const float* src_falloff,  // 256 * src_count entries
    int src_count,
    const float* pos_x,
    const float* pos_y,
    float* out_values,
    int query_count,
    float base_value
) {
    // Initialize output with base value
    for (int q = 0; q < query_count; q++) {
        out_values[q] = base_value;
    }

    // For each source, accumulate influence
    for (int s = 0; s < src_count; s++) {
        float sx = src_x[s];
        float sy = src_y[s];
        float sr = src_radius[s];
        float sr_inv = src_inv_radius[s];
        float sv = src_value[s];
        const float* lut = src_falloff + s * 256;

        // Process each query position
        for (int q = 0; q < query_count; q++) {
            float dx = pos_x[q] - sx;
            float dy = pos_y[q] - sy;
            float dist_sq = dx * dx + dy * dy;

            // Early out if outside radius
            if (dist_sq >= sr * sr) continue;

            float dist = sqrtf(dist_sq);
            float normalized = dist * sr_inv;
            float influence = lut_sample(lut, normalized) * sv;

            out_values[q] += influence;
        }
    }
}

// Batch sample with gradients
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
) {
    // Initialize outputs
    for (int q = 0; q < query_count; q++) {
        out_values[q] = base_value;
        out_gx[q] = 0.0f;
        out_gy[q] = 0.0f;
    }

    // For each source
    for (int s = 0; s < src_count; s++) {
        float sx = src_x[s];
        float sy = src_y[s];
        float sr = src_radius[s];
        float sr_inv = src_inv_radius[s];
        float sv = src_value[s];
        const float* lut = src_falloff + s * 256;

        for (int q = 0; q < query_count; q++) {
            float dx = pos_x[q] - sx;
            float dy = pos_y[q] - sy;
            float dist_sq = dx * dx + dy * dy;

            if (dist_sq >= sr * sr) continue;

            float dist = sqrtf(dist_sq);
            float normalized = dist * sr_inv;
            float influence = lut_sample(lut, normalized) * sv;

            out_values[q] += influence;

            // Gradient points away from source
            if (dist > 0.01f) {
                float inv_dist = 1.0f / dist;
                out_gx[q] += dx * inv_dist * influence;
                out_gy[q] += dy * inv_dist * influence;
            }
        }
    }
}

// Optimized version: process 4 queries per source (better cache use)
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
) {
    // Initialize output
    for (int q = 0; q < query_count; q++) {
        out_values[q] = base_value;
    }

    // Process 4 queries at a time for better vectorization
    int q4 = query_count & ~3;  // Round down to multiple of 4

    for (int s = 0; s < src_count; s++) {
        float sx = src_x[s];
        float sy = src_y[s];
        float sr = src_radius[s];
        float sr_sq = sr * sr;
        float sr_inv = src_inv_radius[s];
        float sv = src_value[s];
        const float* lut = src_falloff + s * 256;

        // Vectorizable loop (4 at a time)
        for (int q = 0; q < q4; q += 4) {
            float dx0 = pos_x[q+0] - sx;
            float dx1 = pos_x[q+1] - sx;
            float dx2 = pos_x[q+2] - sx;
            float dx3 = pos_x[q+3] - sx;

            float dy0 = pos_y[q+0] - sy;
            float dy1 = pos_y[q+1] - sy;
            float dy2 = pos_y[q+2] - sy;
            float dy3 = pos_y[q+3] - sy;

            float dsq0 = dx0*dx0 + dy0*dy0;
            float dsq1 = dx1*dx1 + dy1*dy1;
            float dsq2 = dx2*dx2 + dy2*dy2;
            float dsq3 = dx3*dx3 + dy3*dy3;

            // Process each (compiler will optimize conditionals)
            if (dsq0 < sr_sq) {
                float d = sqrtf(dsq0);
                out_values[q+0] += lut_sample(lut, d * sr_inv) * sv;
            }
            if (dsq1 < sr_sq) {
                float d = sqrtf(dsq1);
                out_values[q+1] += lut_sample(lut, d * sr_inv) * sv;
            }
            if (dsq2 < sr_sq) {
                float d = sqrtf(dsq2);
                out_values[q+2] += lut_sample(lut, d * sr_inv) * sv;
            }
            if (dsq3 < sr_sq) {
                float d = sqrtf(dsq3);
                out_values[q+3] += lut_sample(lut, d * sr_inv) * sv;
            }
        }

        // Handle remainder
        for (int q = q4; q < query_count; q++) {
            float dx = pos_x[q] - sx;
            float dy = pos_y[q] - sy;
            float dist_sq = dx * dx + dy * dy;
            if (dist_sq < sr_sq) {
                float dist = sqrtf(dist_sq);
                out_values[q] += lut_sample(lut, dist * sr_inv) * sv;
            }
        }
    }
}
