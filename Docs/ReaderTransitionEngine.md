# Reader Transition Engine

## CURRENT

```text
ReaderViewController
├─ live Readium content host
├─ fixed controls
├─ one horizontal UIPanGestureRecognizer
├─ immutable PageSurface overlay
└─ PageTurn renderer
   ├─ Core Animation cover renderer
   ├─ Core Image page curl rendered through Metal
   └─ opacity-only fade renderer

Readium fork
├─ adjacent surface preparation
├─ non-animated navigation with an awaitable settled result
└─ ContinuousPaginationView for cross-resource vertical scrolling
```

`PageSurface` contains the rendered document body, document background, moving book-title header, and future page number. Reader controls, the status bar, and the Home Indicator are not part of the surface.

Current and adjacent page pixels come from the same Readium WebKit snapshot path. Every surface carries point size, pixel size, image scale, and content rect; incompatible geometry is rejected instead of stretched. The committed Locator is immutable during an interactive turn. On release, the visual transition completes first and keeps the target overlay mounted; Readium then moves exactly one physical page, confirms stable paint and the resulting Locator, and only then removes the overlay.

## MIGRATION

1. Add the page-turn domain model, state machine, cache invalidation generations, and adaptive edge-tap metrics. **Implemented.**
2. Add current/adjacent surfaces with explicit geometry plus settled navigation to the Readium 3.11 fork. **Implemented; device validation pending.**
3. Implement cover turning with Core Animation and serialized navigator commit. **Implemented; 100-page device gate pending.**
4. Implement a smooth opacity-only fade on the same surface pipeline, with no geometry or shadow work during interaction. **Implemented; device validation pending.**
5. Drive Apple Core Image's public `CIPageCurlWithShadowTransition` from the same pan/state machine as the other paginated effects, render it with a Metal-backed `CIContext`, and automatically fall back to the cover renderer when the GPU/filter path cannot initialize. The old nested `UIPageViewController` gesture stack and all private transition strings are removed. **Implemented; device validation pending.**
6. Add continuous cross-resource scrolling with a bounded WebView window, generation-safe loading, queued height remeasurement, visible-anchor preservation, and Readium Locator conversion. **Implemented; device validation pending.**
7. Opt into the full iPhone ProMotion range and request 60–120 Hz settlement callbacks. Measure actual frame pacing on 60 Hz and ProMotion hardware with Instruments; interaction stability and reading-position correctness still take priority. **Configuration implemented; device validation pending.**

## Fixed interaction contract

- Edge tap width is `clamp(viewportWidth * 0.12, 44pt, 60pt)`.
- The center region only toggles reader controls.
- Horizontal drag is interactive in paginated modes and disabled in continuous scrolling.
- A turn completes above 24% progress or with a sufficiently directional fast fling; otherwise it cancels.
- Slide, curl, and fade take ownership of horizontal gestures only after the current surface and both adjacent readiness states are fully published (`ready` or a confirmed boundary). While the cache is cold, invalid, or failed, Readium keeps its built-in paginated gesture, so there is no interval where both gesture paths are disabled.
- Reduce Motion and VoiceOver use Readium's built-in navigation. Curl initialization failures fall back to the cover renderer; a missing final drawable or failed Metal command buffer cancels the prepared surface and completes through native navigation. Transient surface failures, memory pressure, and invalidated layout keep a working native/non-animated path and immediately restart prewarming.
- Every Locator transaction has a unique ID carried by the active surface. A cancelled or delayed commit can finish only its own transaction and cannot clear a newer page turn. External-takeover visual recovery has a finite retry budget and always releases gesture ownership after the old commit has returned.
- Continuous vertical scrolling is used for horizontal reflowable EPUB/TXT content. Fixed-layout EPUBs remain operable through paginated navigation, while vertical-writing EPUBs retain their native horizontal presentation when the scroll preference is selected.
- Rotation, safe-area changes, display-scale changes, typography changes, and theme changes cancel the active turn and invalidate all cached surfaces.

## Validation gates

- Unit-test state transitions, thresholds, direction mapping, and stale-generation rejection.
- Verify no candidate location is persisted during interaction or cancellation.
- Verify adjacent-resource and chapter-boundary turns in both LTR and RTL publications.
- Verify the title header moves with the page while controls remain fixed.
- Verify continuous scrolling preserves the visible anchor when inserting or resizing content above it.
- Verify memory-pressure fallback releases adjacent surfaces and GPU-backed curl resources.
- Treat Windows checks as static only; use GitHub Xcode builds for compilation and physical devices for frame pacing, memory, accessibility, and reading comfort.
