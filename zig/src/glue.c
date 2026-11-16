#include <lean/lean.h>
#include <string.h>
#include <time.h>

/* Exported by libleanrt (C linkage) but not declared in lean.h of this toolchain. */
void lean_initialize_thread(void);
void lean_finalize_thread(void);

/* Exported from Lean: @[export ekk_handle] def handle (now : UInt64) (buf : ByteArray) : ByteArray; it consumes buf. */
extern lean_object *ekk_handle(uint64_t now, lean_obj_arg buf);

void ekk_thread_init(void) { lean_initialize_thread(); }
void ekk_thread_fini(void) { lean_finalize_thread(); }

/* Hands buf[0..n) to Lean and copies its result (5-byte prefix + response) into out[0..cap).
   Returns the result length, or (size_t)-1 if it does not fit. */
size_t ekk_call(const uint8_t *buf, size_t n, uint8_t *out, size_t cap) {
    lean_object *a = lean_alloc_sarray(1, n, n);
    memcpy(lean_sarray_cptr(a), buf, n);
    lean_object *r = ekk_handle((uint64_t)time(NULL), a);
    size_t m = lean_sarray_size(r);
    if (m > cap) { lean_dec(r); return (size_t)-1; }
    memcpy(out, lean_sarray_cptr(r), m);
    lean_dec(r);
    return m;
}
