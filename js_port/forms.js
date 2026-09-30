// Port of spatula/forms.lua — rect form only
// Faithful to the Lua original: same algorithms, same structure.
// No dependencies. Static params only (no signals/ctx).

const { abs, sqrt, min, max, random, floor } = Math;

/**
 * Create a rectangle form.
 * @param {number} cx - Center X
 * @param {number} cy - Center Y
 * @param {number} hw - Half-width
 * @param {number} hh - Half-height
 * @returns {object} Form with contains, bounds, edge, random, signedDistance
 */
export function rect(cx, cy, hw, hh) {
  return {
    contains(x, y) {
      return abs(x - cx) <= hw && abs(y - cy) <= hh;
    },

    signedDistance(x, y) {
      const dx = abs(x - cx);
      const dy = abs(y - cy);
      const px = dx - hw;
      const py = dy - hh;
      if (px <= 0 && py <= 0) {
        // Inside: positive distance to nearest edge
        return min(-px, -py);
      }
      // Outside: negative distance to rect
      return -sqrt(max(px, 0) ** 2 + max(py, 0) ** 2);
    },

    bounds() {
      return { minX: cx - hw, minY: cy - hh, maxX: cx + hw, maxY: cy + hh };
    },

    edge(count) {
      const perimeter = 2 * (hw + hh) * 2;
      const step = perimeter / count;
      const points = [];
      for (let i = 0; i < count; i++) {
        const d = i * step;
        let px, py;
        if (d < hw * 2) {
          px = cx - hw + d;
          py = cy - hh;
        } else if (d < hw * 2 + hh * 2) {
          px = cx + hw;
          py = cy - hh + (d - hw * 2);
        } else if (d < hw * 4 + hh * 2) {
          px = cx + hw - (d - hw * 2 - hh * 2);
          py = cy + hh;
        } else {
          px = cx - hw;
          py = cy + hh - (d - hw * 4 - hh * 2);
        }
        points.push({ x: px, y: py });
      }
      return points;
    },

    random() {
      return {
        x: cx + (random() * 2 - 1) * hw,
        y: cy + (random() * 2 - 1) * hh,
      };
    },
  };
}
