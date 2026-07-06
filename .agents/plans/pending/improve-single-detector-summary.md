# Improve 1-detector score summary

When only 1 detector runs (e.g., humanize subcommand fallback), the summary shows redundant rows:
- "1/1 > 5%" — obvious
- "Combined" — same as the only detector
- "Method: median" — meaningless with 1 value

## Fix
In `lib/renderers/terminal.py`, `_render_score()` — when only 1 detector has a valid score, skip the redundant summary rows and just show the Total. When 2+ detectors, keep current format.

## Files
- `lib/renderers/terminal.py` — lines 126-137

## Verification
- `acewriter humanize file.docx` — 1 detector, clean summary
- `acewriter score file.docx` — 5 detectors, full summary
