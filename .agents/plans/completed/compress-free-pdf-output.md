# Plan: Compress Free Tier PDF Output

## Problem

Free tier PDF reports (watermarked, rasterized) are **100MB+** because `render_pdf_as_images()` stores each page as a **lossless PNG** inside the PDF with no compression flags.

## Root Cause

In `lib/document/base.py:render_pdf_as_images()`:

```python
# Line 517 — lossless PNG, huge file
img_rgb.save(buf, format="PNG")

# Line 523 — no compression flags, PyMuPDF defaults
out.save(str(output_pdf))
```

Each A4 page rasterized at 200 DPI = ~1654×2338 px × 3 bytes = ~11MB raw. PNG is lossless and poorly suited for text/document images with watermarks. Across 10+ pages, the result balloons to 100MB+.

## Solution

Two-line change in `render_pdf_as_images()`:

| Change | Line | Effect |
|---|---|---|
| PNG → JPEG q85 | 517 | ~95% size reduction. JPEG at quality 85 is visually lossless for document pages with watermarks. |
| Add `garbage=4, deflate=True` | 523 | Removes unused PDF objects + compresses remaining streams. |

### Why JPEG q85 is safe here

- These are **rasterized preview pages** (watermarked, no selectable text) — not archival quality documents
- 200 DPI JPEG q85 is visually indistinguishable from PNG for this use case
- PyMuPDF detects JPEG data and stores it as-is in the PDF (no re-compression)

## Backward Compatibility

- **Fully backward compatible.** Output is identical in appearance (watermarks, borders, footers all unchanged).
- Only the internal storage format changes (JPEG vs PNG).
- No new dependencies, no new flags, no API changes.

## Risk Assessment

- **Very low risk.** Two lines changed, one file touched.
- JPEG uses lossy compression — imperceptible at q85 for document pages.
- Rollback: revert the two lines.

## Implementation

### Step 1: Change PNG to JPEG with quality

**File:** `lib/document/base.py`, line 517

```python
# Before:
img_rgb.save(buf, format="PNG")
# After:
img_rgb.save(buf, format="JPEG", quality=85)
```

### Step 2: Add compression flags to save

**File:** `lib/document/base.py`, line 523

```python
# Before:
out.save(str(output_pdf))
# After:
out.save(str(output_pdf), garbage=4, deflate=True)
```

## Testing

1. Generate a free tier PDF: `acewriter score sample.docx --pdf`
2. Verify file size is dramatically reduced (<5MB instead of 100MB+)
3. Verify watermark, border, and footer are visually identical
4. Verify pro tier PDFs are unaffected (no code change)
