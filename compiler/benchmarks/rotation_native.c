// rotation_native.c - Native rotation for benchmark comparison
// Compile: gcc -O3 -shared -fPIC -o librotation_native.dylib rotation_native.c

#include <stdint.h>

void rotate_batch(float* x, float* y, int count, float cosD, float sinD) {
    for (int i = 0; i < count; i++) {
        float xi = x[i];
        float yi = y[i];
        x[i] = xi * cosD - yi * sinD;
        y[i] = xi * sinD + yi * cosD;
    }
}

// SIMD version using compiler auto-vectorization hints
void rotate_batch_simd(float* restrict x, float* restrict y, int count, float cosD, float sinD) {
    // Process 4 at a time for SIMD
    int i = 0;
    for (; i <= count - 4; i += 4) {
        float x0 = x[i], x1 = x[i+1], x2 = x[i+2], x3 = x[i+3];
        float y0 = y[i], y1 = y[i+1], y2 = y[i+2], y3 = y[i+3];

        x[i]   = x0 * cosD - y0 * sinD;
        x[i+1] = x1 * cosD - y1 * sinD;
        x[i+2] = x2 * cosD - y2 * sinD;
        x[i+3] = x3 * cosD - y3 * sinD;

        y[i]   = x0 * sinD + y0 * cosD;
        y[i+1] = x1 * sinD + y1 * cosD;
        y[i+2] = x2 * sinD + y2 * cosD;
        y[i+3] = x3 * sinD + y3 * cosD;
    }
    // Remainder
    for (; i < count; i++) {
        float xi = x[i];
        float yi = y[i];
        x[i] = xi * cosD - yi * sinD;
        y[i] = xi * sinD + yi * cosD;
    }
}
