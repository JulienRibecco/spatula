local Spatula = require("spatula")
local C, M = Spatula.Curve, Spatula.Motion

local orbit = M.rotate(
    M.scale(M.circle(1, 0.25), C.offset(C.sin(0.75, 28), 100)),
    C.sin(0.25, 0.35)
)

return orbit
