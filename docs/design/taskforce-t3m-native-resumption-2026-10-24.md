# Native agent-tree workspace

The Mac Sessions surface opens a fitted agent tree beside the selected conversation. Selecting a child changes its transcript and composer context. Child messages retain Main as their destination and include the selected task identity. Collapse opens the ordinary Main conversation; returning preserves manual framing.

## Interaction

- Whole-tree initial fit and explicit Fit tree / Command-0.
- Zoom controls, native incremental pinch, two-axis pan, and smart magnify to fit.
- Input stays within the canvas; scroll ownership persists through momentum and cancellation clears gesture state.
- Existing settings handles account recovery. The legacy launcher and its exclusive entrypoints are retired without adding a replacement window.

## Verification

- Final canvas suite: 16 tests passed, including hosted canvas bounds, transforms, native event lifecycle and cross-pane scroll ownership.
- Final native Debug build passed; local signature verification passed using existing entitlements.
- Direct native checks used real session data: child transcript/composer selection, zoom, fit, Collapse/Back and pan. Chat scrolling changed the conversation while the tree remained stationary.
- Earlier integration checks passed 124 focused Kit tests and 216 focused Mac tests. These predate final launcher retirement and are not final-head full-suite results.
- Physical trackpad pinch and double-tap were not exercised on hardware; event handling is covered by tests. Hosted launcher tests were cancelled when scope was narrowed.

## Review boundaries

No provider message or new task was submitted during real-session verification. No server migration, installer or release is included. The installed application was not replaced.

Legacy-only Add task controls are removed. Edge currently has no independent artifact preview: recognized artifact links open the current shell. This behavior needs explicit review before merging. Release surface gates and remote deployment are separate from this local implementation.
