Restructure README.md into a README and move investigations and measurements to docs/

Requested by the user on 2026-11-19: they asked why README.md is such a mess and whether the purpose of a README is known. README.md has grown to 1,765 lines (116 KB) because items appended their findings to it: spike measurements, the HttpArena runs on the VPS, the over-5 s tail investigation, the H1-versus-hand-parser comparison and the dusty failure at 256 connections sit next to the user-facing contract, and item ids are scattered through the text.

Goal: README.md is what a reader needs to understand and use the library: what it is and for whom, its status and limits, how to depend on it from another Lake package, a short module map with links, how to build, check and run it, and pointers to the detailed docs. Everything else moves out, unchanged in substance.

Work:
- Keep in README.md: the introduction (without item-id history), "Using it from another Lake package", a short module overview, a short "Running" (the commands and what each checks), status and known limits, and a "Documentation" list linking the files below.
- Move the detailed contracts to docs/ as reference documents, kept accurate: the module map and allowed imports (AGENTS.project.md points to it as the architecture map), the production contract, PostgreSQL, memory, fragmented requests (D1), and the detailed "Running" material (bench, linux-check, arena scripts, controls).
- Move the measurements and investigations (HttpArena on the VPS, the over-5 s tail, the H1 comparison, the dusty failure, the spike's measurements) to docs/reports/, one file per topic, each stating its date, the commit or setup measured, and that it is a historical record.
- Drop item ids from the prose of reference documents unless they are needed to find a decision; finished-item history lives in git.
- Update every link into the moved sections: AGENTS.project.md, scripts' comments and messages, issues/ items, docs/upstream, and anchors. Search for "README" and for each moved heading.
- Add to AGENTS.project.md a rule on where findings go: README.md holds only what a reader needs to use the library; contracts go to docs/, measurements and investigations to docs/reports/, decisions to decision records; an item that produces findings names the file it updates there, never README.md by default.
- Check: no content lost (diff the removed README lines against the new files, ignoring moved headings), every relative link and anchor resolves (a scripted check over the Markdown files), ./check.sh still passes.
