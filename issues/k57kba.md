Correct bench/parse/profile.sh's count of perf's "unwind: get_proc_name unsupported" messages

Found by item owgate (docs/reports/h1-parse-profile.md, "Anomalies met").

`bench/parse/profile.sh`'s header says perf report writes that message "one per few samples". The Linux run of 2026-11-19 (pipelined parse, 1,000,000 receives, 42 K samples) wrote 168,206 such lines to linux-report.log for its two reports, about two per sample in each. The shares were unaffected (99.99 % of the samples reach `_lean_main` in linux-children.txt), so only the comment's count is stale. Fix: state the count as measured, or as a ratio that holds for both runs, with the date.
