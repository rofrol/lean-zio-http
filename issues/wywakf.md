Point the issues/ items that cite README sections at the docs/ files they moved to
Done by: the coordinating session

Item ejegth split README.md into docs/ and docs/reports/ but could not change issues/ (only `rr2 issue edit` may). These items still name README sections that no longer exist there:

- issues/2ltibq.md:3, :5, :12 — README "HttpArena on the VPS" → docs/reports/httparena-vps.md
- issues/3pund6.md:3, :6, :14, :26, :52 — README "Accept errors" / "Production contract" → docs/production-contract.md, "Accept errors" (line 52 is the draft of an upstream issue: its link should become https://github.com/rofrol/lean-zio-http/blob/main/docs/production-contract.md once published)
- issues/4bngph.md:9 — README "Memory" → docs/memory.md
- issues/5f54l4.md:3, :5 — README "Not yet" → docs/production-contract.md, "Not yet"; README "Fragmented requests" → docs/fragmented-requests.md

Check: `git grep -n README -- issues/` shows only references that mean the new README.md.
