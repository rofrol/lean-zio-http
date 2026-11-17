Prepare the upstream question for mxzlsx (Std.Http H1 reparses an unfinished field line)

The user decided on 2026-11-17 for item mxzlsx: ask upstream (leanprover/lean4). This item prepares it; the coordinating session posts it.

Do:
- Write a self-contained reproducer against Std.Http at the pinned toolchain and at upstream HEAD: feed one request whose head is a single ~8 KiB header field line to `H1.Machine` 1 byte at a time and all at once, and print the number of bytes the parser scans in each case (instrumentation outside Std, e.g. counting calls through the public API, or timing as a second signal), plus the 182 ms vs 116 ms figures from README "Fragmented requests".
- Draft the issue text in docs/upstream/std-http-incremental-field-line.md: a question (is a field line or the start line meant to be parsed incrementally across `Machine.feed` calls, or is reparsing from the line's start the intended behavior?), the doc passages quoted in mxzlsx (H1.lean `Machine.feed`/`step`, `Event.needMoreData`, Parser.lean `manyItems`), the reproducer and its output, the toolchain and HEAD commits. Follow leanprover/lean4's issue template for its kind (read .github/ISSUE_TEMPLATE at HEAD) and its contribution guide.
- Do not post anything. End with the draft's path.
