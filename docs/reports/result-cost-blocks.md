# A query result's charged cost against the runtime's real blocks

Historical record. Measured 2026-11-20 (item gihgde) at commit 9d61052,
with the Lean toolchain `leanprover/lean4:nightly-2026-11-19` (its
`lean/config.h` defines `LEAN_MIMALLOC`) on macOS arm64, by the C probe
below linked against the toolchain's `libleanshared`. It compares the
cost `zig/src/pg.c` charges for each Lean object of a result
(`object_cost`, `string_cost`) with the size Lean asks the allocator for
and with the block mimalloc gives it (`mi_usable_size`).

## Results

- **What Lean asks for.** Under `LEAN_MIMALLOC`, `lean_alloc_small_object`
  and `lean_alloc_object` (`include/lean/lean.h:527-548`, `:607`) pass
  the object's size, rounded to 8 for constructors, to mimalloc and keep
  no word before the object; the word before it exists only in lean.h's
  non-mimalloc branch (`:542-546`). `pg.c`'s comment above `charge`
  gives that word as the reason for the `+ 8` in `object_cost`, so under
  this toolchain the model charges every object 8 bytes more than Lean
  asks for. The runtime's own size function, `lean_object_byte_size`
  (exported by `libleanshared`), equals the request for every string of
  0 to 3 MiB and array of 0 to 4,999 slots probed, and the aligned size
  for constructors (8, 16, 24, 32 bytes for 0 to 3 fields): the model is
  `align(lean_object_byte_size, 8) + 8` for every object `pg.c` builds.
- **The blocks mimalloc gives.** `mi_usable_size` rounds the request up to
  mimalloc's size classes: 8-byte steps to 64 bytes, then four classes per
  power of two. Model / real block, in bytes: a `some` (one field) 24 / 16;
  an empty array 32 / 24; a string of 0 to 7 bytes 48 / 40; an array of
  15 slots 152 / 160; of 30 slots 272 / 320. Over strings of 0 to 3 MiB
  (every length to 5,000, then every 13th to 100,000, then every 4,093rd),
  the model is above the real block for 236 lengths and below it for
  12,615 (equal for the rest); the largest shortfall is 24.9% of the model, at a
  string of 32,742 bytes (model 32,784, block 40,960).
  `mi_good_size(aligned request)` equals the block up to about 512 KiB;
  above it the block is larger (a string of 525,676 bytes: block 589,824,
  `mi_good_size` 540,672).

So the model is neither an upper nor a lower bound of the real blocks,
and no closed form that `pg.c` owns, the current model or one built on
`mi_good_size`, equals them for every object the 1 MiB bound admits. The
contract of `Query.maxResultBytes` (`Server/Query.lean`) counts "each
object's header and rounding" with "the allocator's overhead" on top,
which the size Lean asks for (plus the 8-byte word) meets and the real
blocks exceed by up to about a quarter.

## Probe

```c
#include <lean/lean.h>
#include <stdio.h>
void lean_initialize_runtime_module(void);
static size_t model(size_t req) { return (req + 15) / 8 * 8; } /* object_cost */
int main(void) {
    lean_initialize_runtime_module();
    size_t over = 0, under = 0, notgood = 0, notsize = 0;
    for (size_t n = 0; n < (size_t)3 << 20; n += n < 5000 ? 1 : n < 100000 ? 13 : 4093) {
        size_t req = sizeof(lean_string_object) + n + 1;
        lean_object *s = lean_alloc_string(n + 1, n + 1, n);
        size_t real = mi_usable_size(s), m = model(req);
        over += m > real; under += m < real;
        notgood += real != mi_good_size(lean_align(req, 8));
        notsize += lean_object_byte_size(s) != req;
        lean_dec(s);
    }
    for (size_t k = 0; k < 5000; k++) {
        lean_object *a = lean_alloc_array(0, k);
        notsize += lean_object_byte_size(a) != sizeof(lean_array_object) + 8 * k;
        lean_dec(a);
    }
    printf("model > block %zu, model < block %zu, block != mi_good_size %zu, "
           "byte_size != request %zu\n", over, under, notgood, notsize);
}
```

Built with `cc -I$T/include probe.c -L$T/lib/lean -lleanshared
-Wl,-rpath,$T/lib/lean`, `$T` the toolchain's directory.

## Follow-up: the oracle chosen (2026-11-20, item avvieu)

Decided by the models under the owner's delegation of 2026-11-20 to decide
the queue (consult round 20261120-164926-87db, sol and hydrogen agreeing):
`Query.maxResultBytes` keeps its contract (headers and rounding counted,
the allocator's overhead on top), and the independent oracle of `pg.c`'s
charge is the runtime's `lean_object_byte_size`, not `mi_usable_size`.
`zig/src/pg_glue_test.c` (`cost_shapes`, `built_cost`) checks that the
cost `rows_take` charges equals the sum, over every object of the built
result, of its `lean_object_byte_size` rounded up to 8 plus 8, for results with no
columns, no rows, one row, 1,000 rows, NULL and empty fields, and text of
up to 1,000,000 bytes, in chunks of 1 and 16 rows and whole. `pg.c`'s
comment now gives the `+ 8` as a margin, not a header. The measurement
above stays as written.
