# Native drag return handoff — 2026-09-13

The hidden stationary host previously continued its own angle interpolation and recreated its glass surface only when revealed. A returning dragged module also used the old selection's role colors until the route committed. These gave the final handoff different position/appearance state from the moving module.

Hidden hosts now align directly without animations, including their first visible frame. Their native surfaces are prepared while invisible during drag/return. The moving module interpolates toward the final selection's role colors with the settlement progress; nested animations are disabled so colors cannot lag behind arrival. Visible ring neighbors retain shortest-path circular motion.

Validation: 37 strict WorkbenchTests passed during the fix; final Release build, strict formatting and whitespace checks passed. The canonical Release app was reloaded and left with the original empty selection. Real pointer return was attempted but again failed with `Computer Use server error -10005: noWindowsAvailable`. Actual frame-by-frame landing smoothness remains unverified; unit tests are not claimed as visual proof.
