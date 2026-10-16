# Validate scoped TXT coordinates with Core, without enabling restoration

The App uses the first-party NagiEngineCore product pinned to
`0db0eb5738a655a3f288c9c0a3d321be84fb37a8`, including its ADR-0006 scoped-position
contract. It does not copy NativePosition or UTF-16 storage-boundary logic into
another coordinate system. NagiEngineCoreText is not linked by this slice.

`ScopedNativePosition` pairs the existing TXTInputScope with Core NativePosition.
All new types are internal, Sendable and Equatable, not Codable. Validation takes
the current TXTIngestDocument and the caller's Book.id, without I/O or mutation.
It checks complete scope first, then unit, then node, then Core storage boundary;
failure reports scopeMismatch, unknownUnit, unknownNode or invalidStorageBoundary.
Success returns the original candidate as validCoordinate, without clamping or
caret snapping. Core's unit/node equality semantics apply; routing normalization
does not. The single TXT root is taken from current ingest, not guessed from offset.

This is deliberately not named exactNative: validity in supplied canonical text
does not establish strict decode/XML/resource-budget admission or page recovery.
Even a compatibility lossy artifact has an addressable text axis, but is not a
native-admission token. A later consumer must establish those separate facts.

Page ownership is deferred: UnitPageRanges lacks scope and layout identity, so a
future owner must bind both current input and active layout before lookup. No
page index, signature, scope, coordinate or result is persisted in this slice.

Legacy ReadingPosition, ReaderRepository, EPUBReaderModel, Book and their existing
Locator reads/writes remain unchanged. No renderer switch, Readium bridge, session
writer, disk schema/migration, UI, fork change or native pilot is delivered here.
The tests-first commit is a compilable rejecting seam, not a working validator;
the implementation commit and its actual full-suite results are separate evidence.
