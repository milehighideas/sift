# Sift — PDF Optimizer Design Spec

**Date:** 2026-08-03
**Status:** Approved for planning

## 1. Overview

Add PDF to the optimizer registry using `qpdf` for lossless stream
recompression. This is the first exercise of the `FileOptimizer` seam designed
in `2026-08-03-optimize-pass-design.md` §11: one registry entry, its own verify
closure, and nothing else changes.

The verify closure is **not** the one that spec anticipated. Measurement during
design showed the planned check (opens + page count matches) is insufficient by
a wide margin.

## 2. The measurement that shaped this

Tested on a real 10.9 MB, 203-page PDF (`HazelUserGuide.pdf`):

| Approach | Result | Saved | Pages | **Images** |
|---|---|---|---|---|
| `qpdf` lossless | 10,880,735 → 7,985,747 | 26% | 203 | **169** |
| `gs -dPDFSETTINGS=/printer` | → 434,628 | 96% | 203 | **0** |
| `gs -dPDFSETTINGS=/ebook` | → 425,152 | 96% | 203 | **0** |

Ghostscript's 96% "saving" is the deletion of all 169 embedded images, not
compression. Rendering page 48 at 150 dpi and diffing pixel-by-pixel:

- `qpdf` vs original: **0 differing pixels of 2,103,750**
- `gs` vs original: **15.19% differing, max delta 255** (images replaced by white)
- text-only page 100: `gs` differs by 0.00% — confirming only images are lost

**Both Ghostscript outputs would have passed a page-count verifier.** They open
correctly and have all 203 pages. Shipping the originally-specified check would
have silently stripped every image from every PDF entering the watched folders,
overwriting the originals in place.

## 3. Goals

- Losslessly shrink `.pdf` files in every watched folder, like any other format.
- Verify that page count **and embedded-image count** are preserved, so a tool
  that discards content can never pass.
- Honor `Keep OG` and the `Sift · Optimized` marker exactly as other formats do.
- Change nothing outside `Optimize.swift` and its tests.

## 4. Non-Goals

- **No lossy mode and no config knob for one.** A setting whose enabled state
  deletes images is not shippable. If a safe lossy path is found later, it needs
  the image-count check as a precondition, and that knob can be added then.
- No OCR, no linearization-for-web as a user-facing option, no password handling.
- No PDF-specific conditions in the rule engine (that is separate work).

## 5. Registry entry

```swift
FileOptimizer(
    name: "pdf", extensions: ["pdf"], toolNames: ["qpdf"],
    arguments: { input, output, _ in
        ["--linearize", "--recompress-flate", "--compression-level=9", input, output]
    },
    verify: { verifyPDF(original: $0, candidate: $1) })
```

`level` is ignored — it is the oxipng effort knob and has no qpdf analogue,
matching how jpeg and gif already ignore it.

## 6. Exit-code handling

`qpdf` exits **3 on warnings while still producing correct output**. The real
guide triggers this (`object has offset 0 — a common error handled correctly by
qpdf`). The pipeline currently treats any non-zero status as failure, so the pass
must accept 0 and 3 for this tool and let verification be the arbiter.

Rather than special-casing a tool name inside `OptimizePass`, `FileOptimizer`
gains a field:

```swift
public let successExitCodes: Set<Int32>   // default [0]
```

PDF passes `[0, 3]`. The pipeline checks membership instead of `== 0`. This keeps
the per-format seam the only place format knowledge lives.

## 7. `verifyPDF`

```swift
public func verifyPDF(original: URL, candidate: URL) -> VerifyResult
```

Using CoreGraphics (`CGPDFDocument`), already available — no new dependency:

1. Original fails to open, or has 0 pages → `.originalUnreadable` (partial
   download; skip without marking, so it retries).
2. Candidate fails to open → `.candidateInvalid`.
3. Page counts differ → `.candidateInvalid`.
4. **Embedded-image counts differ → `.candidateInvalid`.**
5. Otherwise `.ok`.

Image counting walks each page's resource dictionary for XObjects whose
`/Subtype` is `/Image`. A shared XObject referenced from several pages is
counted per reference; the check is a comparison between two documents processed
the same way, so consistency matters more than absolute accuracy.

Cost: this opens and walks both documents. For a 203-page file that is
milliseconds, and it only runs on files not already marked.

## 8. Error handling

Inherits the existing pipeline table unchanged. The PDF-specific rows:

| Condition | Behavior |
|---|---|
| `qpdf` absent | `SKIP no optimizer for pdf`, logged once, file unmarked |
| `qpdf` exits 0 or 3 | proceed to verification |
| `qpdf` exits anything else | `ERROR optimize`, no marker, retries next pass |
| Image or page count changed | `ERROR verify`, temp discarded, original untouched, no marker |
| Output not smaller | marked (cannot shrink — done, never retried) |

## 9. Testing

- `OptimizeTests`: registry contains `pdf` with extension `pdf` and tool
  `qpdf`; argument construction; `successExitCodes` is `[0, 3]` for pdf and
  `[0]` for the image formats.
- `verifyPDF`: identical documents → `.ok`; truncated candidate →
  `.candidateInvalid`; unreadable original → `.originalUnreadable`; a candidate
  with the same page count but fewer images → `.candidateInvalid` (the
  regression this whole spec exists for); a candidate with fewer pages →
  `.candidateInvalid`.
- Test fixtures are generated in-test with `CGContext(pdfURL:)` — a two-page
  document with a drawn image, and variants missing the image or a page. No
  binary fixtures committed.
- `OptimizePassTests`: a stub tool exiting 3 with valid output still succeeds
  (proves the `successExitCodes` path); a stub exiting 1 still fails.
- Integration: `XCTSkipIf(findTool(named: "qpdf", …) == nil)` — round-trip a
  generated PDF through the real tool and assert it stays valid.

## 10. Files touched

| File | Change |
|---|---|
| `Sources/SiftCore/Optimize.swift` | `successExitCodes` field, pdf registry entry, `verifyPDF` |
| `Sources/SiftCore/OptimizePass.swift` | exit-code check uses `successExitCodes` |
| `Tests/SiftCoreTests/OptimizeTests.swift` | registry + verifyPDF cases |
| `Tests/SiftCoreTests/OptimizePassTests.swift` | exit-code-3 acceptance |
| `README.md` | pdf in the optimized-formats list; `brew install qpdf` |
| `CLAUDE.md` | the image-count invariant |
