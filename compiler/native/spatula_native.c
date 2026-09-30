// spatula_native.c - Native SIMD batch operations for Spatula scheduler
//
// Compile (macOS):
//   gcc -O3 -shared -fPIC -o libspatula_native.dylib spatula_native.c
//
// Compile (Linux):
//   gcc -O3 -shared -fPIC -o libspatula_native.so spatula_native.c
//
// Compile with explicit SIMD (optional, gcc auto-vectorizes well):
//   gcc -O3 -march=native -shared -fPIC -o libspatula_native.dylib spatula_native.c

#include <stdint.h>

// Rotation: x' = x*cos - y*sin, y' = x*sin + y*cos
void rotate_batch(float* restrict x, float* restrict y, int count, float cosD, float sinD) {
    for (int i = 0; i < count; i++) {
        float xi = x[i];
        float yi = y[i];
        x[i] = xi * cosD - yi * sinD;
        y[i] = xi * sinD + yi * cosD;
    }
}

// Same as rotate_batch - gcc auto-vectorizes the simple loop better
void rotate_batch_simd(float* restrict x, float* restrict y, int count, float cosD, float sinD) {
    for (int i = 0; i < count; i++) {
        float xi = x[i];
        float yi = y[i];
        x[i] = xi * cosD - yi * sinD;
        y[i] = xi * sinD + yi * cosD;
    }
}

// Vector add: dst = a + b
void add_batch(float* restrict dst, const float* restrict a, const float* restrict b, int count) {
    for (int i = 0; i < count; i++) {
        dst[i] = a[i] + b[i];
    }
}

// Scalar multiply: dst = a * scalar
void mul_batch(float* restrict dst, const float* restrict a, float scalar, int count) {
    for (int i = 0; i < count; i++) {
        dst[i] = a[i] * scalar;
    }
}

// Vector subtract: dst = a - b
void sub_batch(float* restrict dst, const float* restrict a, const float* restrict b, int count) {
    for (int i = 0; i < count; i++) {
        dst[i] = a[i] - b[i];
    }
}

// Fused multiply-add: dst = a * b + c
void fma_batch(float* restrict dst, const float* restrict a, const float* restrict b, const float* restrict c, int count) {
    for (int i = 0; i < count; i++) {
        dst[i] = a[i] * b[i] + c[i];
    }
}

// Scale and offset: dst = a * scale + offset
void scale_offset_batch(float* restrict dst, const float* restrict a, float scale, float offset, int count) {
    for (int i = 0; i < count; i++) {
        dst[i] = a[i] * scale + offset;
    }
}

// Normalize 2D vectors to unit length
void normalize_batch(float* restrict x, float* restrict y, int count) {
    for (int i = 0; i < count; i++) {
        float xi = x[i];
        float yi = y[i];
        float len = xi * xi + yi * yi;
        if (len > 0.0f) {
            // Fast inverse sqrt approximation could go here
            float invLen = 1.0f / __builtin_sqrtf(len);
            x[i] = xi * invLen;
            y[i] = yi * invLen;
        }
    }
}

// Copy array
void copy_batch(float* restrict dst, const float* restrict src, int count) {
    for (int i = 0; i < count; i++) {
        dst[i] = src[i];
    }
}

// Fill array with constant
void fill_batch(float* dst, float value, int count) {
    for (int i = 0; i < count; i++) {
        dst[i] = value;
    }
}
