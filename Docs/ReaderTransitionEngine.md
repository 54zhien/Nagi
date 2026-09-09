# Reader Transition Engine

## CURRENT

```text
ReaderViewController
├─ persistent UIPageViewController(.pageCurl)
│  ├─ live Readium content while idle
│  └─ immutable adjacent-page controller during a curl
├─ fixed controls
├─ PageSurfaceHost
└─ PageTurnCoordinator
   ├─ CoverTransitionRenderer
   ├─ native interactive page-curl path
   └─ FadeTransitionRenderer

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
4. Implement the staggered fade renderer on the same surface pipeline. **Implemented; device validation pending.**
5. Keep the live reader inside a public `UIPageViewController(.pageCurl)`. Its own data source and gestures drive interactive curls against complete immutable page composites; programmatic edge turns use the same controller. Do not use private Core Animation transition strings or custom Metal geometry. **Implemented; device validation pending.**
6. Add continuous cross-resource scrolling with a bounded WebView window, generation-safe loading, queued height remeasurement, visible-anchor preservation, and Readium Locator conversion. **Implemented; device validation pending.**
7. Measure on 60 Hz and ProMotion hardware with Instruments. High refresh rate is an optimization target; interaction stability and reading-position correctness take priority.

## Fixed interaction contract

- Edge tap width is `clamp(viewportWidth * 0.12, 44pt, 60pt)`.
- The center region only toggles reader controls.
- Horizontal drag is interactive in paginated modes and disabled in continuous scrolling.
- A turn completes above 24% progress or with a sufficiently directional fast fling; otherwise it cancels.
- Once the renderer is ready, slide, curl, and fade retain ownership of horizontal gestures. A turn consumes only a geometry-matched current surface and the requested adjacent direction; the opposite side may still be preparing. Readium's ordinary smooth paginated swipe does not take over while one side is warming.
- Reduce Motion and VoiceOver may use Readium's built-in navigation. Transient surface failures, memory pressure, and invalidated layout use a non-animated fallback and immediately restart prewarming.
- Continuous vertical scrolling is used for reflowable EPUB/TXT content. Fixed-layout EPUBs remain operable through paginated navigation when the scroll preference is selected.
- Rotation, safe-area changes, display-scale changes, typography changes, and theme changes cancel the active turn and invalidate all cached surfaces.

## Validation gates

- Unit-test state transitions, thresholds, direction mapping, and stale-generation rejection.
- Verify no candidate location is persisted during interaction or cancellation.
- Verify adjacent-resource and chapter-boundary turns in both LTR and RTL publications.
- Verify the title header moves with the page while controls remain fixed.
- Verify continuous scrolling preserves the visible anchor when inserting or resizing content above it.
- Verify memory-pressure fallback releases adjacent surfaces and native page-turn controllers.
- Treat Windows checks as static only; use GitHub Xcode builds for compilation and physical devices for frame pacing, memory, accessibility, and reading comfort.
