# Nagi Reader Input

The App owns imported reader input and library-record identity. Rendering and
saved reading progress are separate from interpreting an input capture.

## Language

**TXT Ingest Document**:
An immutable interpretation of one owned TXT byte capture, including decoding
evidence and ordered chapter text. It is not a reading session or saved position.
_Avoid_: ContentShard, renderer state

**TXT Input Scope**:
The identity of a particular library record's source interpretation. Identical
text in another record is not the same scope; a new layout is not a new input.
_Avoid_: file path, book title, page generation

**TXT Ingest Manifest**:
The ordered unit identities and exact primary text produced by TXT ingestion.
It is not the generated EPUB package or the Core's lightweight DocumentManifest.
_Avoid_: OPF, derived asset, page map
