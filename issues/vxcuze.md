Add the remaining edge-case tests of pipelined batching

hydrogen (consult round 20261119-120420-c1d1, call 9f681ce4) listed cases batchScenario (Test.lean, commit 9c774f0) does not cover:
1. consecutive batches when more complete requests remain behind the maxResponseBytes cap (order and exact capacity of the second batch);
2. an oversized (closes in startSend) or empty first response with pipelined requests behind it (Conn.batch's `first.size = 0` branch);
3. gather's defensive stops (`consumed = 0`, `consumed > buf.size`, an empty response), which H1Adapter cannot produce; they need a synthetic Adapter;
4. a full buffer answered in several batches that ends on an incomplete request (recv of inCap - tail with the head deadline).
Also (round 20261119-122005-1e00, sol, call c948e7dc): bench/check's "150 pipelined requests" case cannot show that one receive held them, so the end-to-end batch over 8,192 bytes is checked only in Lean; a Zig-level test of a send over out_cap split across a response boundary with a short write would close that.
