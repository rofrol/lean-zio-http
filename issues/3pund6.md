Decide what follows from the classification of Linux pending-connection accept errnos (xihdtw)

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
