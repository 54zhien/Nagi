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
- Slide, curl, and fade own horizontal gestures from selection through paginated-presentation settling. Cache readiness never hands the gesture back to Readium: a transient miss shows bounded resistance, finishes prewarming, and then runs the selected transition. This prevents an in-flight touch from being captured by the ordinary smooth pager before detached surfaces are published.
- Reduce Motion, VoiceOver, and the explicit scroll mode use Readium's built-in navigation. While a selected custom mode's paginated presentation is settling, Nagi keeps native paging disabled and waits for the custom surface pipeline. Curl initialization failures fall back to the app-owned cover renderer; transient surface misses retry through the selected app-owned transition instead of silently switching visual styles.
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
