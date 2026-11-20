Decide whether bench/mdlinks keeps its own CommonMark subset parser or uses a CommonMark library

Item g4vate added bench/mdlinks (run first by check.sh), a Go program with only the standard library that checks every relative link and GitHub heading anchor in the tracked Markdown files. It parses the subset of CommonMark these documents use. Four review rounds (consult 20261119-065135-73de, 20261119-065722-7214, 20261119-070228-fc77, 20261119-071718-94d4) each found more corner cases (fences inside list items, link-in-image nesting, reference definitions, HTML comments in headings). The realistic ones are fixed and have tests. The rest are listed as known differences in bench/mdlinks/main.go's header comment: list items told apart by marker rather than content indentation, reference links not resolved, emphasis pairing in headings ignoring run lengths, and others. None occurs in today's 28 files and 74 links.

Risk: a difference can let a broken link pass (the check fails open), or reject a valid link (that shows up at once). It grows as documents use more Markdown.

Question for the owner. Options:
1. Keep the hand-written parser. Fix differences as documents hit them, each with a test. No new dependency.
2. Parse with a maintained CommonMark library (for example github.com/yuin/goldmark, MIT, no transitive dependencies). It closes the parsing differences, and only the GitHub slug rule and path resolution stay ours. It adds a module download to check.sh (bench/pgserver already downloads pgx) and a dependency to update.

Sol and hydrogen (consult round 20261119-075953-d7f4, 2026-11-19) both left this to the owner: it trades a parser-coverage risk against a new dependency.
Question: Should bench/mdlinks keep its own CommonMark subset parser or use a CommonMark library?
Options: keep the subset parser, fixing a difference when a document meets it | use goldmark (a Go dependency fetched by check.sh)
Checked: bench/mdlinks/main.go header lists the known differences; none occurs in today's documents.

Consult round 20261120-155056-df17 (2026-11-20, under the user's delegation to decide the queue): split, so it stays with the owner. sol (421584d0) chose goldmark, fewer silently passing broken links being worth one pinned dependency; hydrogen (69355b88) chose the subset parser, no document hitting a difference and no new check.sh dependency. Adding a dependency is non-trivial under Rule 6.
