Decide when a pipelined request's head budget starts

Seen in ytzycm (commits ff2f547, f5e3909): the head deadline of a later
request on a keep-alive connection starts when the connection starts reading
it, which for a pipelined request is when the previous response has been
sent whole (`Server/Conn.lean`, `continues`/`stamp`: a response's end starts
a new generation), not when its first byte arrived. The settled design (consult
round 20261117-090011-f37f) said "from when reading starts for later ones";
README "Deadlines" states the consequence. A peer that pipelines a partial
head behind a slow-to-read response therefore gets the write budget plus the
head budget for that head.

Question: which start should the head budget of a pipelined request have?
- (a) Keep the current one (reading starts after the previous response); no
  change, the README already says so.
- (b) Start it at the first byte of that request, which needs the loop to
  report the time bytes arrived (or Lean to carry a "head started" mark
  across the write phase) and a second deadline alive during writing.
