Rerun HttpArena on vps.frolow.dev after the accept fix (sakmfp)?

Item 6p6tu6 found that the server accepted one connection per loop turn, so under HttpArena's 4,096 connections only about half were served during each 5 s sample. The figures 53rwgc published for the VPS count only those connections, and sakmfp marks them invalid. The user's consent to load runs on the VPS (2026-11-17) covered 53rwgc only. A rerun after sakmfp would take about 30 minutes, under the same conditions as 53rwgc: its own scope and namespaces, about 400 MB in one directory removed at the end, a health watcher that stops the run, and ekklesiai.org told before and after. The generator would still share the 2 vCPUs.
Question: May the HttpArena runs be repeated on vps.frolow.dev once sakmfp has landed, under 53rwgc's conditions?
Options: yes, rerun on the VPS after sakmfp | only local measurements (bench/arena/local.sh) for now | wait for the clean D2 run (2ltibq)
