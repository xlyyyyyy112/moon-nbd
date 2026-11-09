///|
test "range set sorts, merges and reports coverage" {
  let set = RangeSet::new(
    [
      { offset: 1024UL, length: 512UL, },
      { offset: 0UL, length: 512UL, },
      { offset: 512UL, length: 512UL, },
    ],
    alignment=512UL,
  )
  let merged = set.ranges()
  assert_eq(merged.length(), 1)
  assert_eq(merged[0].offset, 0UL)
  assert_eq(merged[0].length, 1536UL)
  assert_true(set.contains(1024UL))
  assert_false(set.contains(1536UL))
  assert_eq(set.total_length(), 1536UL)
}

///|
test "range set intersection and subtraction preserve alignment" {
  let left = RangeSet::new([{ offset: 0UL, length: 2048UL, }], alignment=512UL)
  let right = RangeSet::new(
    [{ offset: 512UL, length: 512UL, }, { offset: 1536UL, length: 512UL, }],
    alignment=512UL,
  )
  let common = left.intersection(right).ranges()
  assert_eq(common.length(), 2)
  assert_eq(common[0].offset, 512UL)
  assert_eq(common[1].offset, 1536UL)
  let remainder = left.subtract(right).ranges()
  assert_eq(remainder.length(), 2)
  assert_eq(remainder[0].offset, 0UL)
  assert_eq(remainder[1].offset, 1024UL)
}

///|
test "range set rejects empty, misaligned and mismatched inputs" {
  try RangeSet::new([{ offset: 0UL, length: 0UL, }]) catch {
    InvalidArgument(_) => ()
    e => raise e
  } noraise {
    _ => fail("empty range was accepted")
  }
  let bytes = RangeSet::new([{ offset: 0UL, length: 1UL, }])
  let blocks = RangeSet::new([{ offset: 0UL, length: 512UL, }], alignment=512UL)
  try bytes.union(blocks) catch {
    InvalidArgument(_) => ()
    e => raise e
  } noraise {
    _ => fail("mismatched alignments were accepted")
  }
}

///|
test "range overlap handles UInt64 boundaries without wrapping" {
  let invalid : ByteRange = { offset: 0xfffffffffffffffeUL, length: 4UL, }
  let high : ByteRange = { offset: 0xfffffffffffffffcUL, length: 2UL, }
  let low : ByteRange = { offset: 0UL, length: 4UL, }
  assert_false(invalid.intersects(high))
  assert_false(invalid.intersects(low))
  assert_true(high.intersects({ offset: 0xfffffffffffffffdUL, length: 1UL, }))
  assert_false(high.intersects({ offset: 0xfffffffffffffffeUL, length: 1UL, }))
}
