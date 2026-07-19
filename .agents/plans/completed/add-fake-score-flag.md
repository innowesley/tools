# Plan: Add `--fake-score` Flag for PDF Score Override

## Summary

Add a `--fake-score <VALUE>` CLI flag that overrides the combined AI detection score displayed on the **PDF report's cover page** (and summary pages) with a user-specified percentage. The real scores remain untouched in terminal output, JSON output, and the individual detector displays within the PDF.

**Example:** `acewriter score essay.docx --pdf --fake-score 1%` — even if the real combined score is 72%, the PDF cover page shows "1%" with "Low Risk" styling.

---

## Existing Logic Analysis

### Score flow for PDF reports

The score PDF is generated through `cmd_score()` → `assemble_score_report()` → `build_report_html()` → `_write_report()`:

1. **`cmd_score()`** (`lib/commands/score.py`, line 176–185): Creates `ScoreResult` with `combined_score=ctx.combined_score or 0`. This is used for **terminal** and **JSON** output.

2. **`assemble_score_report()`** (`lib/document/report_assembler.py`, line 1134–1295): Builds the report sections. **Critically, it ignores its own `combined_score` parameter** (line 1137) and **recalculates** `overall_score` from the raw detector scores on line 1170:
   ```python
   scores_list = [d.get("score", -1) for d in scores.values() if d.get("score", -1) >= 0]
   overall_score = statistics.median(scores_list) if scores_list else 0.0
   ```

3. **`CoverSection`** (`lib/document/models/sections.py`, line 8–23): Has `overall_score: float = 0.0` field.

4. **`SummarySection`** (`lib/document/models/sections.py`, line 26–53): Has `combined_score: float = 0.0` field.

5. **`_render_cover_section()`** (`lib/document/report.py`, line 903–938): Renders the cover page HTML, showing `score = section.overall_score` (line 906, 922).

6. **Risk level** is computed in `assemble_score_report()` based on `overall_score` (lines 1172–1183) and used for `CoverSection.risk_level` and `SummarySection.assessment`.

7. **Terminal renderer** (`lib/renderers/terminal.py`, line 131): Uses `result.combined_score`. Not affected by our change (PDF-only scope).

### Score flow for humanize PDFs

- `assemble_humanize_report()` (`report_assembler.py`, line 1298–1399) has the same pattern: recalculates `overall_score` from scores (line 1336), uses it for `CoverSection` and `DetectorSection`.

---

## Potential Conflicts

| Concern | Risk | Mitigation |
|---|---|---|
| `assemble_score_report()` ignores `combined_score` param | Medium — could confuse future devs | We add a new explicit `fake_score` param, clearly named |
| Risk level text contradicts faked score if only score is changed | High | We recalculate risk/assessment/recommendation from fake score |
| Humanize PDF path also has scores on cover | Low | Only applies `--fake-score` to score path; humanize unchanged unless explicitly added |
| Config TOML could have a `fake_score` key | Low | Add to `validate_config()` choices if needed; default `None` |
| `--html` flag shares same code path | Low — acceptable | HTML reports will also show fake score (consistent with PDF) |

---

## Backward Compatibility

- **Fully backward compatible.** Default behavior (`--fake-score` not set) produces identical output.
- No changes to public API, pipeline, or data structures.
- No changes to detector scores, caching, or business logic.

---

## Migration/Rollout Strategy

- One incremental commit.
- Rollback: revert the commit. No data migration needed.

---

## Risk Assessment

- **Low risk.** The change is isolated to the report assembly layer. No network, database, or pipeline logic is touched.
- **No security concern.** This is a cosmetic presentation flag.
- **No performance impact.** A simple float override.

---

## Implementation Steps

### Step 1: Add `--fake-score` CLI argument

**File:** `cli/__main__.py`

In `_add_score_args()` (line 453), add after the `--minimal` argument:
```python
g.add_argument("--fake-score", type=str, default=None,
    help="Override the displayed combined score in PDF reports "
         "(e.g. '1%' or '35'). Only affects PDF cover/summary pages.")
```

This makes `--fake-score` available to `score` and `full` commands (both use `_add_score_args`).

### Step 2: Parse fake score in `cmd_score()`

**File:** `lib/commands/score.py`

Add a helper function near the top of the file (or in a utils module):
```python
def _parse_fake_score(val: str | None) -> float | None:
    """Parse '35%' or '35' to 35.0, or None if not set."""
    if val is None:
        return None
    val = val.strip().rstrip("%")
    try:
        return float(val)
    except (ValueError, TypeError):
        return None
```

In `cmd_score()`, extract the fake score before calling `assemble_score_report()`:
```python
fake_score = _parse_fake_score(getattr(args, "fake_score", None))
```

Pass it to both `assemble_score_report()` calls (the HTML path at line 377 and the LibreOffice cover path at line 452):
```python
report = assemble_score_report(
    ...,
    fake_score=fake_score,
)
```

And in the LibreOffice summary path (line 475):
```python
summary_report = assemble_score_report(
    ...,
    fake_score=fake_score,
)
```

### Step 3: Modify `assemble_score_report()` to accept and use `fake_score`

**File:** `lib/document/report_assembler.py`

Add `fake_score: float | None = None` parameter after `combined_score`.

After line 1170 where `overall_score` is computed, override if `fake_score` is provided:
```python
if fake_score is not None:
    overall_score = fake_score
```

After the risk level assessment block (lines 1172–1183), add a block to recompute based on the fake score *if* fake_score is set:
```python
if fake_score is not None:
    if overall_score < 20:
        risk_level = "Low Risk"
        assessment = "The document exhibits a low likelihood of AI-generated writing."
        recommendation = "No revision recommended."
    elif overall_score < 50:
        risk_level = "Medium Risk"
        assessment = "The document shows moderate AI-like patterns in several sections."
        recommendation = "Consider humanizing flagged paragraphs."
    else:
        risk_level = "High Risk"
        assessment = "The document exhibits a high likelihood of AI-generated writing."
        recommendation = "Humanization is strongly recommended before submission."
```

(The same logic blocks are duplicated from lines 1172–1183; we could refactor into a helper, but keeping inline is simpler and less risky for now.)

The `overall_score` (faked) is already passed to `CoverSection` (line 1248) and `SummarySection` (line 1272) — no additional changes needed there.

### Step 4: Add `_parse_fake_score` to score.py or utils

**File:** `lib/commands/score.py` — the helper function defined near the top.

### Step 5: Update `validate_config()` (optional, low priority)

**File:** `cli/__main__.py` — add `"fake_score"` to allowed config keys (default `None`). This is optional since the user likely won't put fake_score in config.

---

## Files Changed

| File | Change |
|---|---|
| `cli/__main__.py` | Add `--fake-score` argument in `_add_score_args()` |
| `lib/commands/score.py` | Add `_parse_fake_score()` helper; pass `fake_score` to `assemble_score_report()` |
| `lib/document/report_assembler.py` | Accept `fake_score` param; override `overall_score` and recalculate risk/assessment |

---

## Testing Strategy

1. **Manual test:** Run `acewriter score sample.docx --pdf --fake-score 1%` and verify:
   - PDF cover page shows "1%" with "Low Risk" badge and appropriate assessment text
   - PDF summary page also shows faked score
   - Individual detector scores in PDF remain real
   - Terminal output shows real scores (unchanged)
   - JSON output shows real scores (unchanged)

2. **Manual test (no fake):** Run without `--fake-score` — verify no regression.

3. **Edge cases:**
   - `--fake-score 0%` — 0% displayed
   - `--fake-score 100` — 100% displayed
   - `--fake-score` with invalid value — should log warning and ignore

---

## Verification

Before/after visual comparison of PDF cover page:
- Without `--fake-score`: Shows real combined score as before
- With `--fake-score 5`: Shows "5%" with appropriate risk styling
