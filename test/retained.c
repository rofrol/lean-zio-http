// Test support for lsrv-test: the bytes of the allocator blocks a Lean value
// holds. Walks the object graph from a root once per object (a value shared
// within the graph counts once) and sums `mi_usable_size` of every block it
// reaches, which is the block the runtime's mimalloc gave the object (a
// constructor, array, string or byte array is one block, `lean.h`). Skips
// scalars and persistent objects (reference count 0: the closed terms made
// once at initialization, such as H1's initial machine, shared by every
// connection and not retained per connection). Only for single-threaded,
// acyclic values: thunks, tasks and references are counted as their own block
// and not entered. An external object counts its block only.
#include <lean/lean.h>

// The Lean toolchain's include/ has no stdlib.h; lean.h declares
// malloc and free. C11 7.1.4p2 permits declaring abort without its header;
// calloc and realloc refer to size_t, which it does not cover, so they rest
// on the toolchain's libc, as lean.h's own malloc and free do. lean.h also
// declares mi_usable_size (through lean/mimalloc.h, as the toolchain's
// lean/config.h defines LEAN_MIMALLOC); that the objects measured here are
// the start of their mimalloc block rests on the runtime's code, not on
// documentation
// (docs/reports/dependency-assumptions.md, point 5).
void *calloc(size_t, size_t);
void *realloc(void *, size_t);
_Noreturn void abort(void);
size_t mi_usable_size(const void *p);

typedef struct {
  lean_object **slots;
  size_t cap, count;
} seen_set;

static int seen_insert(seen_set *s, lean_object *o) {
  if (2 * (s->count + 1) > s->cap) {
    size_t cap = s->cap ? 2 * s->cap : 1024;
    lean_object **slots = calloc(cap, sizeof *slots);
    if (!slots) abort();
    for (size_t i = 0; i < s->cap; i++) {
      lean_object *p = s->slots[i];
      if (!p) continue;
      size_t j = ((size_t)p >> 3) & (cap - 1);
      while (slots[j]) j = (j + 1) & (cap - 1);
      slots[j] = p;
    }
    free(s->slots);
    s->slots = slots;
    s->cap = cap;
  }
  size_t j = ((size_t)o >> 3) & (s->cap - 1);
  while (s->slots[j]) {
    if (s->slots[j] == o) return 0;
    j = (j + 1) & (s->cap - 1);
  }
  s->slots[j] = o;
  s->count++;
  return 1;
}

LEAN_EXPORT lean_obj_res lsrv_retained_bytes(b_lean_obj_arg root) {
  seen_set seen = {0};
  size_t stack_cap = 1024, top = 0, total = 0;
  lean_object **stack = malloc(stack_cap * sizeof *stack);
  if (!stack) abort();
  stack[top++] = root;
  while (top > 0) {
    lean_object *o = stack[--top];
    if (lean_is_scalar(o) || lean_is_persistent(o) || !seen_insert(&seen, o)) continue;
    total += mi_usable_size(o);
    size_t n = 0;
    lean_object **children = NULL;
    uint8_t tag = lean_ptr_tag(o);
    if (tag <= LeanMaxCtorTag) {
      n = lean_ctor_num_objs(o);
      children = lean_ctor_obj_cptr(o);
    } else if (tag == LeanArray) {
      n = lean_array_size(o);
      children = lean_array_cptr(o);
    } else if (tag == LeanClosure) {
      n = lean_closure_num_fixed(o);
      children = lean_closure_arg_cptr(o);
    }
    if (top + n > stack_cap) {
      while (top + n > stack_cap) stack_cap *= 2;
      stack = realloc(stack, stack_cap * sizeof *stack);
      if (!stack) abort();
    }
    for (size_t i = 0; i < n; i++) stack[top++] = children[i];
  }
  free(stack);
  free(seen.slots);
  return lean_usize_to_nat(total);
}

// The capacity of a byte array (`lean_sarray_capacity`), which Lean does not
// expose: lsrv-test checks that a written response has no unused capacity.
LEAN_EXPORT lean_obj_res lsrv_byte_array_capacity(b_lean_obj_arg a) {
  return lean_usize_to_nat(lean_sarray_capacity(a));
}
