Move the zio pin to 53ed3c3 (zio PRs 929 and 930)

The user pointed at https://github.com/lalinsky/zio/pull/930 on 2026-11-17. zio main is 2 commits past our pin 830564437b2c, both merged 2026-11-17:
- https://github.com/lalinsky/zio/pull/929 (e53caa9) documents on `Completion.callback` that a callback may re-add its own completion, or free it or reuse its memory, unless it is rearmed or has an owner. Before that, only comments inside `finishCompletion` said so. Docs and tests only.
- https://github.com/lalinsky/zio/pull/930 (53ed3c3) makes `setsockopt` return `error.InvalidArgument` on EINVAL instead of logging an unexpected error, the follow-up to our report https://github.com/lalinsky/zio/issues/926.

Work:
- Move zig/build.zig.zon, and dusty-hello's zon (grjqox keeps them equal), to 53ed3c3773179a5c34aeca6b7e61aa5817accaee with `zig fetch`, and update every comment that names 830564437b2c.
- Wherever serve.zig or pg.zig re-adds, frees or reuses a completion from its own callback (for example a connection freed in `closeCb`, a receive re-added from `recvCb`), cite the new `Completion.callback` documentation in place of reasoning from zio's implementation (policy Rule 6). Name any such reliance the documentation does not cover.
- `openListener`'s `setsockopt` and `setNoDelay` calls get the new error in their error set: check that they still handle it and that the messages still name the error.
- Run ./check.sh, ./linux-check.sh and ./bench.sh. Rerun the read-only claims of 5lkloz and qtvoaq (completion order, loop groups) against the new commit, and update their cited line numbers in serve.zig.
