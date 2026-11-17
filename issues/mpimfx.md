Decide whether to allocate a response with the capacity it needs

Seen while doing es53kx: `Server.Response.write` allocates capacity 192 + body (Server/Response.lean:123); a head longer than 192 bytes makes the body's append double the capacity it needs (`lean_sarray_ensure_capacity`, exact := false), so a response of up to 65,536 bytes may hold capacity 131,072, a 163,840-byte mimalloc block, which is most of the derived 190 KiB a connection allocates while sending (README "Memory"). Computing the head first (or its exact size) would keep the capacity at the response's size, at most an 81,920-byte block. The buffer has the same doubling while reading (at most a 40,960-byte block for 16,388 bytes); the coordinating session decided on 2026-11-17 against a fixed-capacity redesign for now.
Question: Should `Response.write` allocate the exact capacity, halving the worst-case response block?
Options: allocate the exact capacity in Response.write | keep the doubling and the stated 190 KiB
