# Native replacement ring stability — 2026-09-13

The previous clearance search could rotate the ring through 180 degrees to bring a hidden position to an extrusion outlet. At release, the return plan changed the ring ordering again. Raw angular interpolation could also take the long way across the top seam.

Replacement preparation now reserves the outgoing module at its own outlet, using the same return plan during preparation, settlement and departure. Cancelled preparation retains that reservation until retraction finishes. Residual clearance adjustment is capped at half one module spacing. Each module maintains a continuous angle and takes the shortest circular path. Direct user-selected return gaps remain unchanged. Returning module colors now use the same supported-vacancy mapping as stationary modules.

37 strict WorkbenchTests passed, including outlet clearance at 300/431/580 points, reserved replacement position, circular order preservation and shortest travel across the angular seam. Strict formatting and whitespace checks passed.

Release build passed. Reloaded the canonical Release app and restored the user’s text-data source with an empty target. The actual mouse replacement attempt still returned `Computer Use server error -10005: noWindowsAvailable`; pointer motion and continuous replacement feel remain unverified.
