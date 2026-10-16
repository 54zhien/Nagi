# TXT input identity is derived from one capture and a framed manifest

The App's shared TXT ingest document retains the owned byte snapshot, the actual
decoder result and the chapter partition. SHA-256 of the captured bytes and of a
versioned manifest distinguishes source identity from display names and layout.
This adopts the input portion of the independently reviewed E5-S2 contract in
`54zhien/nagi-engine` task evidence; it does not authorize position persistence.

## Scope and compatibility

`TXTInputScope: Equatable, Sendable` contains `bookID: UUID`, `sourceDigest`,
`ingestRevision`, and `manifestDigest` (the latter three Strings). It is internal,
not Codable, not stored, and does not imply native admission or exact recovery.
The book ID is supplied by the App when binding an ingest document to a record;
the parser does not invent a record ID during import.

`TXTIngestDocument: Sendable` retains snapshot, decoding, partition, ordered units
and both lowercase 64-character hexadecimal digests. Its fixed revision is
`nagi-txt-ingest-v1`, covering current decoding, preparation, heading and identity
rules. A future rule change must change the revision. No caller chooses another
revision for the actual ingest implementation merely to label unchanged behavior.

Each unit contains `unitID`, `nodeID`, its legacy chapter and the partition's
segment/content UTF-16 ranges. IDs are `txt-unit:<zero-based decimal ordinal>`
without leading zeros and `txt-root`. They are stable only within the full scope,
never global or cross-source identities. Repeated text still produces distinct
ordered unit IDs. Title lines remain in primary text once. Display titles are
excluded from the digest, but actual title-line text in primary text is included.

Full parsing uses this artifact, without reopening the source for hashing or
decoding. Metadata remains the existing allocation-light counting path: it does
not build chapters or compute a manifest. Preparation shares the existing FEFF,
newline and trim implementation and consumes the retained decoder result once.
Compatibility lossy output remains possible with honest provenance; the artifact
alone is not a successful strict decode, XML validation or native-admission token.

## Exact manifest preimage, format 1

`U64(n)` is exactly eight unsigned bytes, most significant byte first.
`F(s) = U64(s.utf8.count) || exact UTF-8 bytes of s`.
There is no normalization, terminator, padding or implicit separator.

The complete preimage, in order, is:

1. `F("nagi.txt.manifest")` (domain).
2. `U64(1)` (format version).
3. `F(ingestRevision)`.
4. `U64(unitCount)`.
5. For each unit in reading order: `F(unitID) || F(nodeID) || F(primaryText)`.

`manifestDigest` is SHA-256 of exactly that preimage. `sourceDigest` is SHA-256
of every captured original byte, including any BOM. Book ID, file URL, fallback
display title, layout, timestamps, ranges and decoding labels are not additional
preimage fields. Source changes can therefore keep the same manifest digest but
must change input scope through sourceDigest. Scope also distinguishes record IDs.

The internal encoder accepts records/revision explicitly to express the format;
it does not turn arbitrary records into a verified ingest document. Zero records
are valid for encoding fixtures, not an accepted empty TXT input. The encoder
streams fields to a sink and the production sink updates CryptoKit SHA256, avoiding
a second whole-manifest concatenation. This does not claim bounded file/chapter
memory or impose the future native resource budget.

Golden fixtures must pin the complete emitted bytes and final digest, including
empty and non-ASCII fields. They are derived independently, not by calling the
encoder to generate its own expectations. Raw concatenation and generic Codable
JSON were rejected because their field boundaries/representation are not this
contract. Apple's CryptoKit is used rather than a custom hash or new dependency.

## Explicit non-goals

No input scope persistence/wire schema, Book changes, Readium coordinate bridge,
native positions, renderer switch, cache invalidation, source-byte edit map or
disk migration. Partition ranges name prepared/normalized text only; they are not
raw byte coordinates. Core's current publication-position contract is unchanged
and must be revised separately before tagged native restoration. SHA-256 here is
content version evidence, not authentication or proof of intended text encoding.
