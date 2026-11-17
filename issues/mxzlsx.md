Decide how to handle Std.Http H1 parsing an unfinished line again from its start: ask upstream, or approve a supported-subset contract

Needs a decision. Classified by item sy3ims (read-only, 2026-11-17): the contract is **unresolved (silent docs)**. It is neither a bug against a documented contract nor a documented limitation.

What was checked, at the pinned toolchain (nightly-2026-11-14, `src/lean/Std/Http`) and at upstream HEAD (leanprover/lean4 master 55069db87ef1cff027fd59149f022e63d6c5f1cf, 2026-11-17T06:33:38Z), where the relevant code and docstrings are the same:

- The public API of the machine, `Machine.feed` ("Feeds input bytes into the reader side of the machine.", H1.lean:918-922) and `Machine.step` ("Execute one step of the state machine.", H1.lean:1943-1946), states no cost bound and does not say whether input is consumed incrementally.
- `Event.needMoreData` (Event.lean:39-42) says only "Signals that additional input data is required to continue processing." It does not say whether the event is emitted once or on every call. Emitting it on every call that still needs data matches that wording, so the repeated event (which the adapter drops with `takeEvents`) is not a bug either.
- The private `parseWith` (H1.lean:619-657 pinned, 626-664 HEAD) has a docstring that says "On success, advances reader input." and "On EOF with open input, emits `needMoreData`." That implies the input is left where it was on EOF, but says nothing about cost. It is private, so it is not a contract for callers.
- The only upstream passage that names reparsing is the public `manyItems` (Parser.lean:67-73, the same at HEAD): "An item cut off by the end of the input fails with `.eof` instead of ending the list, so it is re-parsed once the rest arrives." This shows that reparsing from the item's start is intended behaviour, but it covers chunk extensions and trailers, not header field lines (`processNeedHeader`/`processFieldLine` → `parseWith … parseSingleHeader … (limit := none)`). It also states no cost or limitation.
- The module docs (Std/Http.lean "Sans I/O Architecture", Config.lean limits) are silent on incremental cost.
- Upstream issues and PRs were searched for "needMoreData", "Std.Http quadratic", "Http H1 reparse", "Std.Http incremental parsing" and "Std.Http slowloris": nothing was found. The nearest is https://github.com/leanprover/lean4/issues/16111 (closed by https://github.com/leanprover/lean4/pull/16362), a correctness bug with a split inside the method name, which is not about cost.

Under AGENTS.md Rule 6, silent documentation establishes nothing. The item stays blocked, and no local workaround and no fork are allowed until a quoted upstream passage, a maintainer's statement or the owner's approval of a supported subset settles it.

Measured impact (README "Fragmented requests", M1 2026-11-17): the largest head, which is almost all one 8 KiB header line, costs 182 ms of CPU with H1 against 116 ms with the hand-written parser in 1-byte receives. It drops to 3.2 ms with 64-byte receives. The cost is bounded by `maxHeadBytes`/`inCap` (Server/H1Adapter.lean:51-57). For whole requests H1 is already faster than the hand-written parser at every receive size (195 ms against 758 ms at k = 1).

Options for the owner:

1. Ask upstream (recommended). Open a question issue, not a bug report, on leanprover/lean4. It would ask whether `Machine.feed`/`step` are meant to parse a field line or start line incrementally, with a reproducer counting the bytes `parseSingleHeader` scans for one 8 KiB header line fed 1 byte at a time against fed at once, and the timing above. If a maintainer calls it a bug, follow the Rule 6 fork path: a fork from the pinned nightly, a regression test that fails before the fix, a PR. If they call it a limitation, quote their statement next to `Server/H1Adapter.lean`'s config and close the item. This is an outward action that needs the owner's go, and it needs a GitHub account choice.
2. Approve a supported-subset contract now. Write next to `Server/H1Adapter.lean`'s config: "H1 parses an unfinished line again on every feed, quadratic in the line length, bounded by maxHeadBytes; not an upstream guarantee, rechecked at each toolchain update", with references to H1.lean:619-657 and Parser.lean:67-73 at the pin. Nothing is sent upstream.
3. Accept without recording. This is not recommended, because Rule 6 leaves the item blocked while the docs are silent.

Question: Ask leanprover/lean4 whether H1 is meant to parse a field line incrementally, or approve the supported-subset contract described in option 2?
Options: ask upstream with the byte-count reproducer (needs your go and the GitHub account) | approve the supported-subset contract next to Server/H1Adapter.lean | both: the contract now, the question upstream too

Decided by the user 2026-11-17: ask upstream. lgxdi7 prepares the reproducer and the draft; this item then posts it on leanprover/lean4 from the user's gh account and waits for a maintainer's answer, which settles bug (fork path) versus limitation (quote it next to Server/H1Adapter.lean).
Done by: the coordinating session

Decided by the user 2026-11-17, while lgxdi7 ran: publish it. The coordinating session posts the draft on leanprover/lean4 from the user's gh account as soon as lgxdi7 has written it and the session has read it.
