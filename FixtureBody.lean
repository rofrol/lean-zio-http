/-! The body of the boundary test's fixture servers (`lsrv-fixture`,
`lsrv-fixture-h1`): larger than the loop's 8192-byte send buffer and no
multiple of it, so every response takes several sends and ends with a short
one. -/

/-- 70,001 bytes: byte `i` is `a` + (i mod 26). bench/boundary expects exactly this. -/
def fixtureBody : ByteArray := Id.run do
  let mut b := ByteArray.emptyWithCapacity 70001
  for i in [0:70001] do
    b := b.push (97 + (i % 26).toUInt8)
  return b
