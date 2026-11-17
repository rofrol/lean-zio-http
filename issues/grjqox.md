Move dusty-hello's zio pin to the server's (830564437b2c)

Seen in 2kaoxd's report (2026-11-17): dusty-hello/build.zig.zon still pins zio 9bef33d while the server pins 830564437b2c55583941364db985b4c0746b3dda (zig/build.zig.zon), so the comparison runs against two zio versions. Move it to the same commit (`zig fetch`), check the comparison still builds and runs in ./bench.sh, and say whether its numbers moved. Approved 2026-11-17 by the coordinating session under the user's delegation (small, reversible, no consult round).
