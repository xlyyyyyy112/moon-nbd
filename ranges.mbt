///|
/// A non-empty half-open byte range: `[offset, offset + length)`.
pub(all) struct ByteRange {
  offset : UInt64
  length : UInt64
}

///|
fn range_end(range : ByteRange) -> UInt64 raise {
  if range.length == 0UL || range.offset > 0xffffffffffffffffUL - range.length {
    raise InvalidArgument("range is empty or overflows UInt64")
  }
  range.offset + range.length
}

///|
pub fn ByteRange::end(self : ByteRange) -> UInt64 raise {
  range_end(self)
}

///|
pub fn ByteRange::contains(self : ByteRange, offset : UInt64) -> Bool {
  self.length != 0UL &&
  offset >= self.offset &&
  offset - self.offset < self.length
}

///|
pub fn ByteRange::intersects(self : ByteRange, other : ByteRange) -> Bool {
  if self.length == 0UL ||
    other.length == 0UL ||
    self.offset > 0xffffffffffffffffUL - self.length ||
    other.offset > 0xffffffffffffffffUL - other.length {
    return false
  }
  // Reject invalid caller-provided ranges before adding either end.
  self.offset < other.offset + other.length &&
  other.offset < self.offset + self.length
}

///|
/// Canonical non-overlapping, non-adjacent ranges with one alignment contract.
pub struct RangeSet {
  priv ranges : Array[ByteRange]
  priv alignment : UInt64
}

///|
fn validate_alignment(alignment : UInt64) -> Unit raise {
  if alignment == 0UL || alignment > 16777216UL {
    raise InvalidArgument("range alignment must be between 1 and 16 MiB")
  }
}

///|
/// Normalize, sort and merge a collection of aligned ranges.
pub fn RangeSet::new(
  input : Array[ByteRange],
  alignment~ : UInt64 = 1UL,
  max_ranges~ : Int32 = 65536,
) -> RangeSet raise {
  validate_alignment(alignment)
  if input.length() > max_ranges || max_ranges <= 0 || max_ranges > 1048576 {
    raise InvalidArgument("invalid range count limit")
  }
  let sorted = input.copy()
  for range in sorted {
    let end = range_end(range)
    if range.offset % alignment != 0UL ||
      range.length % alignment != 0UL ||
      end == 0UL {
      raise InvalidArgument("range violates alignment")
    }
  }
  sorted.sort_by((left, right) => left.offset.compare(right.offset))
  let normalized : Array[ByteRange] = []
  for range in sorted {
    match normalized.last() {
      None => normalized.push(range)
      Some(previous) => {
        let previous_end = range_end(previous)
        if range.offset <= previous_end {
          let range_end = range_end(range)
          if range_end > previous_end {
            ignore(normalized.pop())
            normalized.push({
              offset: previous.offset,
              length: range_end - previous.offset,
            })
          }
        } else {
          normalized.push(range)
        }
      }
    }
  }
  { ranges: normalized, alignment, }
}

///|
pub fn RangeSet::alignment(self : RangeSet) -> UInt64 {
  self.alignment
}

///|
pub fn RangeSet::ranges(self : RangeSet) -> Array[ByteRange] {
  self.ranges.copy()
}

///|
pub fn RangeSet::is_empty(self : RangeSet) -> Bool {
  self.ranges.length() == 0
}

///|
pub fn RangeSet::total_length(self : RangeSet) -> UInt64 {
  let mut total = 0UL
  for range in self.ranges {
    total += range.length
  }
  total
}

///|
pub fn RangeSet::contains(self : RangeSet, offset : UInt64) -> Bool {
  for range in self.ranges {
    if offset < range.offset {
      return false
    }
    if range.contains(offset) {
      return true
    }
  }
  false
}

///|
fn same_alignment(left : RangeSet, right : RangeSet) -> Unit raise {
  if left.alignment != right.alignment {
    raise InvalidArgument("range sets use different alignments")
  }
}

///|
/// Return the union of two range sets.
pub fn RangeSet::union(self : RangeSet, other : RangeSet) -> RangeSet raise {
  same_alignment(self, other)
  let all = self.ranges.copy()
  for range in other.ranges {
    all.push(range)
  }
  RangeSet::new(all, alignment=self.alignment)
}

///|
/// Return the overlapping portion of two range sets.
pub fn RangeSet::intersection(
  self : RangeSet,
  other : RangeSet,
) -> RangeSet raise {
  same_alignment(self, other)
  let output : Array[ByteRange] = []
  let mut left_at = 0
  let mut right_at = 0
  while left_at < self.ranges.length() && right_at < other.ranges.length() {
    let left = self.ranges[left_at]
    let right = other.ranges[right_at]
    let start = if left.offset > right.offset {
      left.offset
    } else {
      right.offset
    }
    let left_end = range_end(left)
    let right_end = range_end(right)
    let end = if left_end < right_end { left_end } else { right_end }
    if start < end {
      output.push({ offset: start, length: end - start, })
    }
    if left_end < right_end {
      left_at += 1
    } else {
      right_at += 1
    }
  }
  RangeSet::new(output, alignment=self.alignment)
}

///|
/// Return bytes in `self` that are not covered by `other`.
pub fn RangeSet::subtract(self : RangeSet, other : RangeSet) -> RangeSet raise {
  same_alignment(self, other)
  let output : Array[ByteRange] = []
  let mut other_at = 0
  for source in self.ranges {
    let source_end = range_end(source)
    let mut cursor = source.offset
    while other_at < other.ranges.length() &&
          range_end(other.ranges[other_at]) <= cursor {
      other_at += 1
    }
    let mut scan = other_at
    while scan < other.ranges.length() && other.ranges[scan].offset < source_end {
      let cut = other.ranges[scan]
      if cursor < cut.offset {
        let end = if cut.offset < source_end { cut.offset } else { source_end }
        output.push({ offset: cursor, length: end - cursor, })
      }
      let cut_end = range_end(cut)
      if cut_end > cursor {
        cursor = if cut_end < source_end { cut_end } else { source_end }
      }
      if cursor == source_end {
        break
      }
      scan += 1
    }
    if cursor < source_end {
      output.push({ offset: cursor, length: source_end - cursor, })
    }
  }
  RangeSet::new(output, alignment=self.alignment)
}

///|
/// Validate ranges for one client and normalize them with its block alignment.
pub fn Client::range_set(
  self : Client,
  input : Array[ByteRange],
) -> RangeSet raise {
  let set = RangeSet::new(input, alignment=self.min_block.to_uint64())
  for range in set.ranges {
    if range.offset > self.size || range.length > self.size - range.offset {
      raise InvalidArgument("range is outside export")
    }
  }
  set
}
