Bound the capacity of connection buffers or qualify the memory claim

Split from byurlg on 2026-11-16 (consult round 20261116-145342-a8e2): Conn.step_inv bounds the lengths of the byte arrays, not their capacities; an array grown by appending can hold about twice its length.
Question: Should buf and out be allocated at fixed capacity and kept unshared, or should the README's memory bound be stated as about twice the lengths?
Options: qualify the claim first from verified allocation behavior | allocate at fixed capacity
Checked 2026-11-16 with sol (consult round 20261116-145342-a8e2): this choice changes a contract, failure behavior or architecture, so it stays with the user; recommendation first.
