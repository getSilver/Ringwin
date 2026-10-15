# v5 initial checker parsing error

Reproduced command: `python .scratch/core-continuous-capacity/audit-07-final.py 07-final-v5`.

Observed exception before correction: `RuntimeError: releasesafe Owner capacity four-shard native bounds` (checker line136).

The checker searched the entire native log for `Owner capacity shard ...` and incorrectly combined separate one-shard test421 (live2/terminal2), four-shard test423 (four rows25/25), and one-shard test424 (live32/terminal16). Requiring exactly four rows in that combined collection rejected valid captured evidence. This is a checker parser error, not a native test failure; the native logs remain unchanged.

Correction: first select exactly one section by the full four-shard test name and native test header, ending at the next numbered test. Inside that section require exactly four initial population rows, unique shard IDs0..3, each25 live and25 retained terminal, totals exactly100/100. The OMS fixture uses the same exact-case section discipline. No arbitrary first-four selection or relaxed row count is used.

All original source, artifact and native log hashes remain independently checked by the audit. No actual tests were rerun for this checker correction.
