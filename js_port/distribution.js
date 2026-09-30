// Port of spatula/distribution.lua — perimeter and poisson only
// Faithful to the Lua original: same algorithms, same structure.
// No dependencies.

const { sqrt, floor, cos, sin, random, PI } = Math;
const PI2 = PI * 2;

/**
 * Generate a random integer in [lo, hi] inclusive.
 */
function randInt(lo, hi) {
  return lo + floor(random() * (hi - lo + 1));
}

/**
 * Distribute points around a form's perimeter.
 * Uses form.edge() if available.
 * @param {object} form - A form object (e.g. from Forms.rect)
 * @param {number} count - Number of points
 * @param {function} push - Callback receiving {x, y} for each point
 */
export function perimeter(form, count, push) {
  if (form.edge) {
    const points = form.edge(count);
    for (let i = 0; i < points.length; i++) {
      push(points[i]);
    }
  }
}

/**
 * Poisson disk sampling inside a form.
 * @param {object} form - A form object with contains(), bounds(), and optionally random()
 * @param {number} minDist - Minimum distance between points
 * @param {function} push - Callback receiving {x, y} for each point
 */
export function poisson(form, minDist, push) {
  const maxAttempts = 30;
  const minDistSq = minDist * minDist;

  const cellSize = minDist / sqrt(2);
  const invCellSize = 1 / cellSize;
  const b = form.bounds();
  const bMinX = b.minX, bMinY = b.minY, bMaxX = b.maxX, bMaxY = b.maxY;
  const cols = floor((bMaxX - bMinX) * invCellSize) + 1;
  const rows = floor((bMaxY - bMinY) * invCellSize) + 1;

  // Spatial grid: key -> point index (1-based to match Lua)
  const grid = new Map();
  const active = [];
  const pointsX = [];
  const pointsY = [];

  function addPoint(x, y) {
    const gx = floor((x - bMinX) * invCellSize);
    const gy = floor((y - bMinY) * invCellSize);
    const key = gy * cols + gx;
    const idx = pointsX.length;
    grid.set(key, idx);
    pointsX.push(x);
    pointsY.push(y);
    active.push(idx);
  }

  function tooClose(x, y) {
    const gx = floor((x - bMinX) * invCellSize);
    const gy = floor((y - bMinY) * invCellSize);

    for (let dy = -2; dy <= 2; dy++) {
      const ny = gy + dy;
      if (ny >= 0 && ny < rows) {
        const rowBase = ny * cols;
        for (let dx = -2; dx <= 2; dx++) {
          const nx = gx + dx;
          if (nx >= 0 && nx < cols) {
            const idx = grid.get(rowBase + nx);
            if (idx !== undefined) {
              const pdx = pointsX[idx] - x;
              const pdy = pointsY[idx] - y;
              if (pdx * pdx + pdy * pdy < minDistSq) {
                return true;
              }
            }
          }
        }
      }
    }
    return false;
  }

  // Seed point
  let startX, startY;
  if (form.random) {
    const sp = form.random();
    startX = sp.x;
    startY = sp.y;
  } else {
    startX = (bMinX + bMaxX) / 2;
    startY = (bMinY + bMaxY) / 2;
  }
  addPoint(startX, startY);

  while (active.length > 0) {
    const randIdx = randInt(0, active.length - 1);
    const pointIdx = active[randIdx];
    const px = pointsX[pointIdx];
    const py = pointsY[pointIdx];
    let found = false;

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const angle = random() * PI2;
      const dist = minDist + random() * minDist;
      const nx = px + cos(angle) * dist;
      const ny = py + sin(angle) * dist;

      if (nx >= bMinX && nx <= bMaxX && ny >= bMinY && ny <= bMaxY) {
        if (form.contains(nx, ny) && !tooClose(nx, ny)) {
          addPoint(nx, ny);
          found = true;
        }
      }
    }

    if (!found) {
      // Swap-and-pop: O(1) removal
      active[randIdx] = active[active.length - 1];
      active.pop();
    }
  }

  for (let i = 0; i < pointsX.length; i++) {
    push({ x: pointsX[i], y: pointsY[i] });
  }
}
