Decide what follows from the classification of Linux pending-connection accept errnos (xihdtw)
Done by: the coordinating session

Needs a decision (item xihdtw's outcome, commit "boundary: classify Linux pending-connection accept errnos under the pinned zio"; README "Production contract", "Accept errors").

What was found:
- The pinned zio (lalinsky/zio 9bef33d, also upstream HEAD on 2026-11-16) maps ENETUNREACH, EHOSTUNREACH, EHOSTDOWN, ENONET and ENOPROTOOPT to `Unexpected` through `unexpectedError` (src/os/base.zig: "Report an errno, an NTSTATUS or an error value that a caller's switch could not map"; it logs "please file a bug report"), and EOPNOTSUPP to `OperationNotSupported` (src/os/net.zig `errnoToAcceptError`). No zio passage names them as a limitation or defines a contract for them, so under the policy (Rule 6) whether this is a zio bug is unresolved, not a documented limitation.
- The Linux sources read (v5.4, v6.1, mainline aebb727) do not return these errnos from TCP's accept, for IPv4 or IPv6, also through io_uring: `inet_accept` returns only `inet_csk_accept`'s error, which is EINVAL, EAGAIN or that of its wait. accept(2)'s "treat them like EAGAIN by retrying" note does not describe those revisions. Not read: other kernel versions, security modules' accept hooks. No Linux reproducer was run.
- So on those kernels the server's exit on these errors cannot be triggered by a pending connection or a remote peer.

Options:
(a) Close the question: keep exiting on them (today's behavior), with the README stating the kernel evidence as it does now.
(b) Ask zio upstream (an issue citing accept(2) and the kernel source) whether these errnos should get names or stay `Unexpected`; an outward action, and per Rule 6 the answer would settle bug versus limitation.
(c) Also ask man-pages to correct accept(2)'s note; outward, not this repository's concern unless the owner wants it.

Related gap in another repository: ekklesiai.org's decision record 0001 (docs/decisions/0001-lean-http-server-on-zio.md), Consequences, still calls this unresolved without the kernel evidence; the session that changes ekklesiai.org updates it once the owner decides.

Recommendation (consult round 20261116-183449-f682, sol, under the user's delegation of 2026-11-16): do not close it as settled; the kernel evidence narrows reachability but settles neither zio's contract nor security modules' hooks. Keep today's exit, keep the finding, and ask upstream only with your go.
Question: What follows from the classification?
Options: keep exiting and keep the item open as a bounded finding | ask zio upstream (b) | close it (a)

Checked 2026-11-17 with sol (consult round 20261117-011832-74e7) under the user's delegation: deferred: keep today's exit and the bounded kernel finding; asking zio upstream needs the user's go. No local workaround.

Decided 2026-11-18 by the coordinating session with sol, argon and hydrogen (consult round 20261118-181941-5f8f; calls 4a23f520, e4c9a8ea, 272fc555), under the user's delegation of 2026-11-18 to decide the remaining open questions with the models: approved (all three agree): keep today's exit on these errnos and the bounded kernel finding in README; no local workaround. Ask zio upstream with one issue on https://github.com/lalinsky/zio from the user's gh account: the mappings (src/os/base.zig unexpectedError for ENETUNREACH, EHOSTUNREACH, EHOSTDOWN, ENONET, ENOPROTOOPT; src/os/net.zig errnoToAcceptError EOPNOTSUPP -> OperationNotSupported) at the pinned commit and HEAD; accept(2)'s retry note; the Linux sources read (v5.4, v6.1, mainline aebb727: inet_accept returns only inet_csk_accept's EINVAL, EAGAIN or wait errors, also through io_uring); that there is no reproducer and other kernels and security-module hooks were not read; the question whether these should get named accept errors or stay Unexpected as documented behavior. No man-pages report. Tell ekklesiai.org's session the finding and the issue link for its decision record 0001. Track the answer in this item; a confirmed bug follows Rule 6 (fork and PR).

Blocked 2026-11-18: posting the issue (`gh issue create -R lalinsky/zio --body-file ...`) was denied by Claude Code's auto-mode classifier ("Unsanctioned Communication"). Not retried. Checked first: the mapping is unchanged at zio 53ed3c3, which is also upstream HEAD (src/os/net.zig errnoToAcceptError lines 896-913; src/os/base.zig unexpectedError line 40); no existing zio issue matches (gh search: "accept errno", ENETUNREACH, errnoToAcceptError); the accept(2) quote was checked against man7.org.

Question: Will you post the drafted zio issue below yourself, or allow this session to post it (a permission rule for `gh issue create -R lalinsky/zio`)?
Options: allow the session to post it | post it yourself (gh issue create -R lalinsky/zio --title TITLE --body-file FILE) | don't ask upstream, keep the bounded finding

Draft title: errnoToAcceptError: should Linux's pending-connection errnos (ENETUNREACH, EHOSTUNREACH, EHOSTDOWN, ENONET, ENOPROTOOPT, EOPNOTSUPP) stay Unexpected?

Draft body:

    A question about `errnoToAcceptError` on Linux, not a reported failure: we have no reproducer.
    
    At 53ed3c3 (current HEAD), `errnoToAcceptError` in `src/os/net.zig` maps these errnos on non-Windows targets:
    
    - `ENETUNREACH`, `EHOSTUNREACH`, `EHOSTDOWN`, `ENONET` and `ENOPROTOOPT` fall through to `else => unexpectedError(e)`. That returns `error.Unexpected` and logs "please file a bug report".
    - `EOPNOTSUPP` maps to `error.OperationNotSupported`.
    
    Linux's accept(2) lists all six as errors of a *pending* connection, not of the listening socket: "Linux accept() (and accept4()) passes already-pending network errors on the new socket as an error code from accept(). ... For reliable operation the application should detect the network errors defined for the protocol after accept() and treat them like EAGAIN by retrying. In the case of TCP/IP, these are ENETDOWN, EPROTO, ENOPROTOOPT, EHOSTDOWN, ENONET, EHOSTUNREACH, EOPNOTSUPP, and ENETUNREACH."
    
    A caller can't tell these apart from a broken listener. `Unexpected` and `OperationNotSupported` also cover errors of the listening socket itself. If the caller re-arms on them, a persistent listener error loops forever. If it treats them as fatal, it exits on what accept(2) calls a transient error of one peer. `ENETDOWN` and `EPROTO` already get named errors (`NetworkDown`, `ProtocolFailure`), so a caller can retry on those two.
    
    We read the TCP accept path in Linux v5.4, v6.1 and mainline aebb727. There, `inet_accept` returns only the error of `inet_csk_accept`, which fails only with `EINVAL` (not listening), `EAGAIN`, or the error of its wait for a connection. That holds for IPv4 and IPv6, and also through io_uring's accept. So on those kernels these errnos seem unreachable for TCP. We have not read other kernel versions, other protocols, or security modules' accept hooks.
    
    Question: are these six meant to stay `Unexpected` / `OperationNotSupported`? If so, could the docs say so? Or should they get a named, retryable accept error, like `NetworkDown` and `ProtocolFailure`? We'd like to rely on what zio documents rather than on our reading of the kernel.
    
    Context: our server ([lean-zio-http](https://github.com/rofrol/lean-zio-http), README "Accept errors") currently exits on these errors and documents why.
