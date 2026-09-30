# Spatula Philosophy Guide

## For Future Claude: READ THIS FIRST

This document captures the design philosophy of Spatula v5. Before adding ANY code, read and internalize these principles.

---

## THE ONE PRIMITIVE

```
Curve = f(t, ctx) -> value
```

Everything else is composition:
- `Motion` = two curves -> (x, y)
- `Field` = curve(distance) + source bookkeeping
- `Distribution` = sample(motion, count) filtered by form

Parallel system (geometry, not curves):
- `Form` = contains(point) -> bool

Event streaming is built into Form and Field, not a separate module.

---

## THE TWO EVALUATION PATTERNS

The primitive `f(t, ctx) -> value` supports two distinct usage patterns.
Understanding this is **central** to using Spatula correctly.

### TRAJECTORY: Position derived from time

For fire-and-forget behaviors where the path is fixed at creation:

```lua
-- At spawn: bake the motion
bullet.motion = Motion.scale(Motion.ray(angle), speed)
bullet.origin = {x, y}
bullet.spawnTime = time

-- Each frame: derive position from total elapsed time
local t = time - bullet.spawnTime
local dx, dy = bullet.motion(t, {})
bullet.x = bullet.origin.x + dx
bullet.y = bullet.origin.y + dy
```

Key properties:
- Parameters (angle, speed) are **fixed at creation**
- Position is **derived**, not accumulated
- `t` is total time since spawn
- `ctx` is empty or minimal

### VELOCITY: Direction sampled each frame

For reactive behaviors that respond to changing conditions:

```lua
-- At setup: define motion with dynamic parameters via ctx
local chaseAngle = function(t, ctx)
    return Point.angleTo(ctx.self, ctx.target)
end
local chaseMotion = Motion.scale(Motion.ray(chaseAngle), speed)

-- Each frame: sample velocity with fresh ctx, accumulate position
local vx, vy = chaseMotion(dt, { self = enemy, target = player })
enemy.x = enemy.x + vx
enemy.y = enemy.y + vy
```

Key properties:
- Parameters come from **ctx at evaluation time**
- Position is **accumulated** each frame
- `t` is dt (frame delta)
- `ctx` carries current state

### THE CTX IS THE REACTIVITY MECHANISM

When you need reactive behavior, **don't add new primitives**. Use ctx.

**Wrong instinct** — adding stateful variants:
```lua
-- WRONG: we almost added these
Curve.followFrom(startValue, targetFn, speed)
Curve.springFrom(startValue, targetFn, stiffness, damping)
```

**Right approach** — pass dynamic data through ctx:
```lua
-- RIGHT: same primitives, ctx provides reactivity
local angleFromCtx = function(t, ctx) 
    return Point.angleTo(ctx.self, ctx.target) 
end
local motion = Motion.ray(angleFromCtx)

-- Fresh data each frame via ctx
motion(dt, { self = entity, target = player })
```

The existing primitives are sufficient. The ctx parameter exists precisely for this.

### CHOOSING THE PATTERN

| Pattern | Position | Time | Ctx | Use when |
|---------|----------|------|-----|----------|
| Trajectory | `origin + motion(t)` | total | empty | Path is fixed (bullets, particles) |
| Velocity | `pos += motion(dt)` | delta | fresh data | Path is reactive (enemies, steering) |

Same primitives. Same combinators. Different evaluation strategy.

---

## FIELDS FOR CONTINUOUS SPATIAL REASONING

Fields aren't just for "area effects" like damage zones or magnet pulls. They're a paradigm for **analog decision-making** that produces naturalistic behavior without explicit AI code.

### EXPLICIT TARGETING (Robotic)

```lua
-- Find nearest enemy
local nearest, nearestDist = nil, math.huge
for _, e in ipairs(enemies) do
    local d = Point.distanceSq(drone, e)
    if d < nearestDist then
        nearestDist = d
        nearest = e
    end
end

-- Beeline to target
local vx, vy = seekMotion(dt, { self = drone, target = nearest })
```

Result: Instant decisions. Straight lines. Digital switching between targets.

### FIELD GRADIENT (Organic)

```lua
-- Enemies emit threat field
enemy.fieldSource = enemyField:add(enemy.x, enemy.y, { radius = 200, value = 1 })

-- Drone follows gradient (no explicit target)
local gx, gy = enemyField:gradient(drone)
drone.x = drone.x + gx * speed * dt
drone.y = drone.y + gy * speed * dt
```

Result: Continuous influence. Curved paths. Smooth transitions.

### WHY THIS WORKS

Under the hood:
- Two nearby enemies = gradients blend = drone drifts toward midpoint before curving to closer one
- Enemy dies = field source removed = gradient shifts = drone smoothly redirects
- No enemies = field value near zero = natural fallback behavior

It's **analog vs digital** decision-making. Fields give you the in-between states for free.

### THE PATTERN

| Approach | Decision | Path | Feels |
|----------|----------|------|-------|
| Explicit query | Instant, discrete | Straight lines | Robotic |
| Field gradient | Continuous, blended | Curves | Organic |

Same underlying goal. Different emergent behavior. No AI code—just spatial math.

---

## THE CORE RULE

### COMPOSE FROM PRIMITIVES, NEVER BYPASS THEM

**Wrong - raw math bypasses primitives:**
```lua
function Motion.circle(radius, speed)
    return function(t, ctx)
        return cos(t * speed * PI2) * radius, sin(t * speed * PI2) * radius
    end
end
```

**Right - built from primitives:**
```lua
function Motion.circle(radius, speed)
    return Motion.xy(Curve.cos(speed, radius), Curve.sin(speed, radius))
end
```

Both produce the same result. The difference:
- Wrong: writes math directly, bypassing the primitive system
- Right: composes existing primitives, proving the system is complete

**Compositions ARE welcome in the library** - but they must be built from primitives and combinators, not raw math.

### Why This Matters

If you can't express something using primitives, it reveals either:
1. A missing primitive (add it)
2. A missing combinator (add it)
3. Something that doesn't belong in this library

Raw math is a code smell. It means you're working around the system instead of through it.

### 2. PRIMITIVES vs COMBINATORS vs COMPOSITIONS

**Primitives** - Irreducible building blocks:
- `Curve.const`, `Curve.sin`, `Curve.noise`, `Curve.follow`, `Curve.spring`
- `Motion.xy`
- `Field.new`, `Field:sample`, `Field:gradient`
- `Forms.circle`
- `Distribution.sample`

**Combinators** - Transform or combine primitives:
- `Curve.add`, `Curve.mul`, `Curve.scale`, `Curve.timeScale`, `Curve.sequence`
- `Motion.add`, `Motion.scale`, `Motion.rotate`, `Motion.mix`
- `Field.combine`, `Field.max`, `Field.invert`
- `Forms.union`, `Forms.intersect`, `Forms.subtract`
- `Distribution.withJitter`, `Distribution.withFilter`

**Compositions** - Built from primitives+combinators (ALLOWED, must use primitives):
- `Motion.circle(r, s)` -> `Motion.xy(Curve.cos(s, r), Curve.sin(s, r))`
- `Motion.spiral(...)` -> `Motion.scale(Motion.circle(...), Curve.offset(...))`
- `Curve.gaussian(w)` -> `Curve.exp(Curve.scale(Curve.pow(Curve.linear, 2), k))`
- `Distribution.spiral(n, t)` -> `Distribution.sample(Motion.outward(t), n)`

### 3. NO GAME-SPECIFIC CODE

These do NOT belong in Spatula:
- `damage()`, `heal()`, `kill()`
- `hp`, `health`, `mana`
- `spawn()`, `explode()`
- Any concept that assumes a specific game structure

Users define their own actions. Spatula provides signals and timing.

### 4. NO MANAGER CLASSES

**Wrong:**
```lua
Tracker.Manager = {}
function Tracker.Manager:add(tracker) ... end
function Tracker.Manager:update(entities, dt) ... end
```

**Right:**
```lua
-- User manages their own collections:
local trackers = {}
for _, t in ipairs(trackers) do
    Forms.updateTracker(t, entities, dt)
end
```

Managers are infrastructure. Users build their own.

### 5. NO ALIASES

**Wrong:**
```lua
Field.gradientAscent = Field.gradient  -- alias
Field.gradient_descent = Field.gradientDescent  -- snake_case compat
Curve.zero = Curve.const(0)  -- convenience alias
```

One name per concept. Users can create their own shortcuts.

### 6. QUESTION EVERY PARAMETER

If a function has more than 3 parameters, it's probably doing too much.

**Wrong:**
```lua
function Motion.territorial(homePos, threatField, territoryRadius, patrolRadius, chaseStrength, returnStrength)
```

**Right:**
This is a composition. User builds it from primitives.

---

## TESTING NEW ADDITIONS

Before adding a function, answer these questions:

1. **Is it built from existing primitives/combinators?**
   - Yes -> Good, proceed
   - No (uses raw math) -> Rewrite using primitives, or identify missing primitive

2. **Can it be solved with ctx instead of a new primitive?**
   - Yes -> Use the velocity pattern with ctx, don't add new code
   - No -> Continue

3. **Is it game-specific?**
   - Yes -> Don't add it
   - No -> Continue

4. **Is it an alias?**
   - Yes -> Don't add it
   - No -> Continue

5. **Does it reveal a missing primitive or combinator?**
   - Yes -> Add the primitive/combinator first, then build on it
   - No -> It should compose from existing pieces

6. **Can you explain it in one sentence without "and"?**
   - Yes -> Good sign
   - No -> It might be doing too much

7. **Does it belong in an existing module?**
   - Event streaming -> Forms.track / Field.track (not a separate module)
   - Point distributions -> Distribution (not a separate module)

---

## VALID REASONS TO ADD CODE

- New primitive (irreducible behavior that can't be composed)
- New combinator (enables new compositions)
- Composition that's commonly needed AND built from primitives
- Bug fix
- Performance optimization that doesn't change API

---

## INVALID REASONS TO ADD CODE

- "It's convenient" (if it uses raw math instead of primitives)
- Adding an alias for an existing function
- Game-specific concepts (damage, health, etc.)
- Manager/infrastructure classes
- New module for something that belongs in an existing module
- Stateful variants when ctx solves the problem (e.g. `followFrom` when velocity pattern works)

---

## THE LITMUS TEST

Look at how `Motion.circle` SHOULD be implemented:

```lua
function Motion.circle(radius, speed)
    return Motion.xy(Curve.cos(speed, radius), Curve.sin(speed, radius))
end
```

NOT like this:
```lua
function Motion.circle(radius, speed)
    return function(t, ctx)
        return cos(t * speed * PI2) * radius, sin(t * speed * PI2) * radius
    end
end
```

Both work. But the first PROVES the primitive system is complete. The second BYPASSES it.

---

## REMEMBER

The goal is a library where complex behaviors emerge from composition of simple primitives.

**Raw math in function bodies = code smell.**

If you can't express something using primitives:
1. First, try harder to compose it
2. If truly impossible, identify the missing primitive/combinator
3. Add the primitive/combinator
4. Then build your composition from it

The primitive system should be COMPLETE. Every behavior should be expressible through composition.
