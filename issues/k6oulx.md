Configurable header fields on the server's own error responses

Requested for ekklesiai.org (its item hjaqm6; decided 2026-11-16 by its coordinating session with Sol, round 20261116-170706-ccb9, on the user's instruction to decide the queue with Sol): responses the library writes below the application (protocol errors 400, 414, 431, 501, 505 from `Server.Response.error`, and the 500 that replaces an invalid application response in `Server.Response.render`) carry no header fields the application chose, so ekklesiai.org's ruling that every response carries `X-Robots-Tag: noindex, nofollow` cannot hold. Give the server a configurable set of extra header fields for its own responses (validated once at startup like application headers: names and values without CR, LF or NUL), applied to every library-generated response, with tests.
Check: `./bench.sh` (the repository's verification), as a visible job.
Publishing to GitHub and moving ekklesiai.org's pin wait for the owner's go.
