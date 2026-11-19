Make check.sh fail on a broken relative Markdown link or anchor

Item ejegth moved README.md's sections into docs/ and docs/reports/ with 74 relative links and anchors between them, verified once by a one-off script (every `[text](path#anchor)` outside code in the tracked Markdown files: the path exists, the anchor is a GitHub heading slug of the target). Nothing keeps them valid: renaming a heading or moving a file breaks them silently, and the new rule in AGENTS.project.md ("Where findings go") will add more documents.

Proposal: a small checker (a script under bench/ or a Lean/Go program already in the build) run by check.sh, failing with the file, the link and what did not resolve. Question for the owner: is the cost of one more check in check.sh worth it, or should it stay a manual step at each docs change?
