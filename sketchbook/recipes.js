// These functions are both executed by the renderer and displayed in the studio.
// Keep them readable: the goal is a small composition, not minified code.
import * as C from '../js_port/curve.js';

function orbitRecipe(p, t) {
  const x = C.add(C.cosine(1, 228, p*.16), C.cosine(3, 45, p+t/24));
  const y = C.add(C.sine(1, 78, p*.16), C.sine(3, 51, p+t/24));
  const a = C.sine(.08, .38, p)(t);
  const c = C.cosine(1)(a/(2*Math.PI)), s = C.sine(1)(a/(2*Math.PI));
  return [
    C.sub(C.scale(x, c), C.scale(y, s)),
    C.add(C.scale(x, s), C.scale(y, c))
  ];
}

function bloomRecipe(k, t) {
  const a = k*1.6 + t*.016;
  const r = C.offset(C.cosine(5, 56+k*19, a), 70+k*43);
  const w = C.add(r, C.sine(3, 8, k*3+t*.03));
  return [C.scale(C.mul(w, C.cosine(1, 1, a*.16)), 1.53),
          C.scale(C.mul(w, C.sine(1, 1, a*.16)), .78)];
}

function flowRecipe(sources, ripple) {
  const f = C.pow(C.ramp(1, 0, 1), 2);
  const sample = (x, y) => sources.reduce((v, s) =>
    v + f(Math.hypot(x-s.x, y-s.y)/s.radius)*s.value, 0);
  return (x, y, u) => {
    const e = .8;
    const gx = (sample(x+e, y) - sample(x-e, y))/(2*e);
    const gy = (sample(x, y+e) - sample(x, y-e))/(2*e);
    return [2.5 - gy*270, ripple(u)*.017 + gx*270];
  };
}

function resonanceRecipe(k, t) {
  const p = k*Math.PI*2, w = C.sine(.5);
  const c = C.add(C.sine(1.65, 79, p+t*.085),
                  C.sine(3.3, 31, p*.55-t*.07));
  const x = C.add(C.offset(C.linear(700), -350),
                  C.mul(C.sine(1, 16, p), w));
  return [x, C.offset(C.mul(c, w), (k-.5)*80)];
}

function convergenceRecipe(t) {
  const phase = C.offset(C.cosine(1/24, -.5), .5);
  const spread = 1 - C.easeInOut(1, 3)(phase(t));
  return ([x, y], i) => [
    x + C.noise(92, i*2.137)(t*.08)*spread,
    y + C.noise(165, i*1.719+4)(t*.06)*spread
  ];
}

export const recipes = [orbitRecipe, bloomRecipe, flowRecipe, resonanceRecipe, convergenceRecipe];
export const recipeNotes = [
  'p is a layer’s phase in radians; t is the animation time. Returns the two curves used to draw that orbit. The renderer repeats this across the layers.',
  'k is the layer index normalized to 0–1; t is the animation time. Returns two curves that trace a petal layer.',
  'sources contains the two animated field sources; ripple is each line’s curve. Returns the velocity sampler used to integrate the streamlines. Source placement and integration live in the renderer.',
  'k is the layer index normalized to 0–1; t is the animation time. Returns the two curves that draw a thread of the ribbon.',
  't is the animation time. Returns a function that moves each sampled letter point [x, y], with i as its index. Text sampling and point drawing live in the renderer.',
];
export function recipeSource(index) {
  return recipes[index].toString();
}
export function recipeStats(index) {
  const source = recipeSource(index);
  const api = new Set([...source.matchAll(/C\.(\w+)/g)].map(match => match[1]));
  return { lines: source.split('\n').length, characters: source.length, operations: api.size };
}
