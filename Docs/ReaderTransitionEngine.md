# Reader Transition Engine

## CURRENT

- `EPUBReaderModel` owns one Readium `EPUBNavigatorViewController`.
- Readium owns horizontal page gestures, adjacent-resource loading, page animation, and location callbacks.
- `ReaderViewController` has a passive pan recognizer whose only responsibility is hiding reader controls.
- `ReaderTransitionCoordinator` protects visual preference mutations with a temporary snapshot; it is not a page-turn state machine.
- The `scroll` preference enables vertical scrolling inside the current resource. The outer Readium pagination container still separates resources.
- Locator callbacks currently update the committed reading position immediately.

## TARGET

```text
ReaderViewController
├─ fixed controls
└─ ReaderPageContainerViewController
   ├─ live Readium content
      ├─ PageSurfaceHost
      └─ PageTurnCoordinator
      ├─ CoverTransitionRenderer
      ├─ CurlMetalTransitionRenderer
      └─ FadeTransitionRenderer

Readium fork
├─ adjacent surface preparation
├─ non-animated navigation with an awaitable settled result
└─ ContinuousPaginationView for cross-resource vertical scrolling
```

`PageSurface` contains the rendered document body, document background, moving book-title header, and future page number. Reader controls, the status bar, and the Home Indicator are not part of the surface.

Current and adjacent page pixels now come from the same Readium WebKit snapshot path. Every surface carries point size, pixel size, image scale, and content rect; incompatible geometry is rejected instead of stretched. The committed Locator is immutable during an interactive turn. On release, navigation and visual settling start together, and the overlay remains until both complete.

## MIGRATION

1. Add the page-turn domain model, state machine, cache invalidation generations, and adaptive edge-tap metrics. **Implemented.**
2. Add current/adjacent surfaces with explicit geometry plus settled navigation to the Readium 3.11 fork. **Implemented; device validation pending.**
3. Implement cover turning with Core Animation and parallel navigator commit. **Implemented; 100-page device gate pending.**
4. Implement the staggered fade renderer on the same surface pipeline. **Implemented; device validation pending.**
5. Implement the Metal curl renderer without bitmap Y scaling; fall back to a short fade on Metal failure. **Implemented; device validation pending.**
6. Add `ContinuousPaginationView` to the fork with a bounded WebView window, cached resource heights, anchor compensation, and Readium Locator conversion.
7. Measure on 60 Hz and ProMotion hardware with Instruments. High refresh rate is an optimization target; interaction stability and reading-position correctness take priority.

## Fixed interaction contract

- Edge tap width is `clamp(viewportWidth * 0.16, 52pt, 72pt)`.
- The center region only toggles reader controls.
- Horizontal drag is interactive in paginated modes and disabled in continuous scrolling.
- A turn completes above 26% progress or with a sufficiently directional fast fling; otherwise it cancels.
- Reduce Motion, VoiceOver, unavailable surfaces, memory pressure, and invalidated layout use a short fade or non-animated fallback.
- Rotation, safe-area changes, display-scale changes, typography changes, and theme changes cancel the active turn and invalidate all cached surfaces.

## Validation gates

- Unit-test state transitions, thresholds, direction mapping, and stale-generation rejection.
- Verify no candidate location is persisted during interaction or cancellation.
- Verify adjacent-resource and chapter-boundary turns in both LTR and RTL publications.
- Verify the title header moves with the page while controls remain fixed.
- Verify continuous scrolling preserves the visible anchor when inserting or resizing content above it.
- Verify memory-pressure fallback releases adjacent surfaces and Metal textures.
- Treat Windows checks as static only; use GitHub Xcode builds for compilation and physical devices for frame pacing, memory, accessibility, and reading comfort.
