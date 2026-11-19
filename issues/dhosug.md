Decide whether bench/mdlinks keeps its own CommonMark subset parser or uses a CommonMark library

Item g4vate added bench/mdlinks (run first by check.sh), a Go program with only the standard library that checks every relative link and GitHub heading anchor in the tracked Markdown files. It parses the subset of CommonMark these documents use. Four review rounds (consult 20261119-065135-73de, 20261119-065722-7214, 20261119-070228-fc77, 20261119-071718-94d4) each found more corner cases (fences inside list items, link-in-image nesting, reference definitions, HTML comments in headings). The realistic ones are fixed and have tests. The rest are listed as known differences in bench/mdlinks/main.go's header comment: list items told apart by marker rather than content indentation, reference links not resolved, emphasis pairing in headings ignoring run lengths, and others. None occurs in today's 28 files and 74 links.

Risk: a difference can let a broken link pass (the check fails open), or reject a valid link (that shows up at once). It grows as documents use more Markdown.

Question for the owner. Options:
1. Keep the hand-written parser. Fix differences as documents hit them, each with a test. No new dependency.
2. Parse with a maintained CommonMark library (for example github.com/yuin/goldmark, MIT, no transitive dependencies). It closes the parsing differences, and only the GitHub slug rule and path resolution stay ours. It adds a module download to check.sh (bench/pgserver already downloads pgx) and a dependency to update.
