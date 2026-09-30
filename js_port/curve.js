// Port of spatula/curve.lua
// THE PRIMITIVE: Curve = f(t) → value
// No ctx/signals — JS version uses closures for state instead.

const { sin, cos, abs, floor, min, max, exp, PI } = Math;
const PI2 = PI * 2;

function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

// ── Unique IDs for stateful curves ───────────────────────────────────────────


// ── PRIMITIVES: Value sources ────────────────────────────────────────────────

export function constant(value) {
  return () => value;
}

export function linear(speed = 1) {
  return (t) => t * speed;
}

export function ramp(start, target, duration) {
  return (t) => {
    if (t >= duration) return target;
    return start + (target - start) * (t / duration);
  };
}

// ── PRIMITIVES: Oscillators ──────────────────────────────────────────────────

export function sine(freq = 1, amp = 1, phase = 0) {
  return (t) => sin(t * freq * PI2 + phase) * amp;
}

export function cosine(freq = 1, amp = 1, phase = 0) {
  return (t) => cos(t * freq * PI2 + phase) * amp;
}

export function triangle(freq = 1, amp = 1) {
  return (t) => {
    const p = (t * freq) % 1;
    const v = p < 0.5 ? (p * 4 - 1) : (3 - p * 4);
    return v * amp;
  };
}

export function saw(freq = 1, amp = 1) {
  return (t) => {
    const p = (t * freq) % 1;
    return (p * 2 - 1) * amp;
  };
}

export function square(freq = 1, amp = 1, duty = 0.5) {
  return (t) => {
    const p = (t * freq) % 1;
    return (p < duty ? 1 : -1) * amp;
  };
}

export function pulse(freq = 1, duty = 0.5) {
  return (t) => {
    const p = (t * freq) % 1;
    return p < duty ? 1 : 0;
  };
}

// ── PRIMITIVES: Easing ───────────────────────────────────────────────────────

export function easeIn(duration = 1, power = 2) {
  return (t) => clamp(t / duration, 0, 1) ** power;
}

export function easeOut(duration = 1, power = 2) {
  return (t) => 1 - (1 - clamp(t / duration, 0, 1)) ** power;
}

export function easeInOut(duration = 1, power = 2) {
  return (t) => {
    const p = clamp(t / duration, 0, 1);
    if (p < 0.5) return (2 ** (power - 1)) * (p ** power);
    return 1 - ((-2 * p + 2) ** power) / 2;
  };
}

// ── PRIMITIVES: Noise ────────────────────────────────────────────────────────

export function noise(scale = 1, seed = 0) {
  return (t) => {
    const n = sin(t * 1.0 + seed) * 0.5 +
              sin(t * 2.3 + seed * 2) * 0.3 +
              sin(t * 5.7 + seed * 3) * 0.2;
    return n * scale;
  };
}

export function perlin(scale = 1, octaves = 3) {
  return (t) => {
    let value = 0, amp = 1, freq = 1, maxVal = 0;
    for (let i = 0; i < octaves; i++) {
      const ti = t * freq;
      const t0 = floor(ti);
      const t1 = t0 + 1;
      const frac = ti - t0;
      const smooth = frac * frac * (3 - 2 * frac);
      const h0 = sin(t0 * 127.1) * 43758.5453;
      const h1 = sin(t1 * 127.1) * 43758.5453;
      const n0 = (h0 - floor(h0)) * 2 - 1;
      const n1 = (h1 - floor(h1)) * 2 - 1;
      value += (n0 + (n1 - n0) * smooth) * amp;
      maxVal += amp;
      amp *= 0.5;
      freq *= 2;
    }
    return (value / maxVal) * scale;
  };
}

// ── PRIMITIVES: Stateful ─────────────────────────────────────────────────────
// These use closure state (no ctx needed in JS).
// Call with a monotonically increasing t.

export function follow(targetFn, speed = 5) {
  let value = null, lastT = null;
  return (t) => {
    if (value === null) { value = targetFn(t); lastT = t; }
    const dt = t - lastT;
    lastT = t;
    const target = targetFn(t);
    value += (target - value) * min(1, speed * dt);
    return value;
  };
}

export function spring(targetFn, stiffness = 100, damping = 10) {
  let value = null, velocity = 0, lastT = null;
  return (t) => {
    if (value === null) { value = targetFn(t); lastT = t; }
    const dt = min(t - lastT, 0.1);
    lastT = t;
    const target = targetFn(t);
    const force = (target - value) * stiffness;
    const dampForce = velocity * damping;
    velocity += (force - dampForce) * dt;
    value += velocity * dt;
    return value;
  };
}

// ── COMBINATORS: Arithmetic ──────────────────────────────────────────────────

export function add(...curves) {
  return (t) => {
    let sum = 0;
    for (let i = 0; i < curves.length; i++) sum += curves[i](t);
    return sum;
  };
}

export function mul(...curves) {
  return (t) => {
    let product = 1;
    for (let i = 0; i < curves.length; i++) product *= curves[i](t);
    return product;
  };
}

export function sub(a, b) {
  return (t) => a(t) - b(t);
}

export function scale(curve, factor) {
  if (typeof factor === 'number') return (t) => curve(t) * factor;
  return (t) => curve(t) * factor(t);
}

export function offset(curve, amount) {
  if (typeof amount === 'number') return (t) => curve(t) + amount;
  return (t) => curve(t) + amount(t);
}

export function curvClamp(curve, lo, hi) {
  return (t) => clamp(curve(t), lo, hi);
}

export function curveAbs(curve) {
  return (t) => abs(curve(t));
}

export function neg(curve) {
  return (t) => -curve(t);
}

export function mix(curves, weights) {
  const wFns = weights.map(w => typeof w === 'number' ? () => w : w);
  return (t) => {
    let sum = 0, totalW = 0;
    for (let i = 0; i < curves.length; i++) {
      const w = wFns[i](t);
      sum += curves[i](t) * w;
      totalW += w;
    }
    return totalW === 0 ? 0 : sum / totalW;
  };
}

export function pow(curve, exponent) {
  if (typeof exponent === 'number') return (t) => curve(t) ** exponent;
  return (t) => curve(t) ** exponent(t);
}

export function curveExp(curve) {
  return (t) => exp(curve(t));
}

export function quantize(curve, steps = 8) {
  return (t) => floor(curve(t) * steps + 0.5) / steps;
}

// ── COMBINATORS: Time manipulation ───────────────────────────────────────────

export function timeScale(curve, factor) {
  if (typeof factor === 'number') return (t) => curve(t * factor);
  return (t) => curve(t * factor(t));
}

export function timeOffset(curve, off) {
  if (typeof off === 'number') return (t) => curve(t + off);
  return (t) => curve(t + off(t));
}

export function loop(curve, duration) {
  return (t) => curve(t % duration);
}

export function pingPong(curve, duration) {
  return (t) => {
    const phase = (t / duration) % 2;
    const lt = phase < 1 ? (phase * duration) : ((2 - phase) * duration);
    return curve(lt);
  };
}

export function hold(curve, duration) {
  return (t) => curve(min(t, duration));
}

export function delay(curve, d) {
  return (t) => t < d ? 0 : curve(t - d);
}

// ── COMBINATORS: Sequencing ──────────────────────────────────────────────────

export function sequence(segments) {
  let totalDuration = 0;
  for (const [, dur] of segments) totalDuration += dur;

  return (t) => {
    const elapsed = t % totalDuration;
    let accumulated = 0;
    for (const [curve, dur] of segments) {
      if (elapsed < accumulated + dur) return curve(elapsed - accumulated);
      accumulated += dur;
    }
    const [lastCurve, lastDur] = segments[segments.length - 1];
    return lastCurve(lastDur);
  };
}

// ── COMPOSITIONS ─────────────────────────────────────────────────────────────

export function gaussian(width = 1) {
  const k = -3 / (width * width);
  return (t) => exp(k * t * t);
}

// ── Keyframe interpolation ───────────────────────────────────────────────────

export function envelope(keyframes, mode = 'linear') {
  const n = keyframes.length;
  if (n === 0) return () => 0;
  if (n === 1) return () => keyframes[0][1];

  function findSegment(t) {
    if (t <= keyframes[0][0]) return [0, 0];
    if (t >= keyframes[n - 1][0]) return [n - 1, n - 1];
    let lo = 0, hi = n - 1;
    while (hi - lo > 1) {
      const mid = floor((lo + hi) / 2);
      if (keyframes[mid][0] <= t) lo = mid; else hi = mid;
    }
    return [lo, hi];
  }

  if (mode === 'step') {
    return (t) => { const [i] = findSegment(t); return keyframes[i][1]; };
  }

  if (mode === 'smooth') {
    return (t) => {
      const [i, j] = findSegment(t);
      if (i === j) return keyframes[i][1];
      const [t0, v0] = keyframes[i];
      const [t1, v1] = keyframes[j];
      const alpha = (t - t0) / (t1 - t0);
      const vm1 = i > 0 ? keyframes[i - 1][1] : v0;
      const v2 = j < n - 1 ? keyframes[j + 1][1] : v1;
      const a = alpha, a2 = a * a, a3 = a2 * a;
      return 0.5 * (
        (2 * v0) +
        (-vm1 + v1) * a +
        (2 * vm1 - 5 * v0 + 4 * v1 - v2) * a2 +
        (-vm1 + 3 * v0 - 3 * v1 + v2) * a3
      );
    };
  }

  // linear (default)
  return (t) => {
    const [i, j] = findSegment(t);
    if (i === j) return keyframes[i][1];
    const [t0, v0] = keyframes[i];
    const [t1, v1] = keyframes[j];
    return v0 + (v1 - v0) * ((t - t0) / (t1 - t0));
  };
}
