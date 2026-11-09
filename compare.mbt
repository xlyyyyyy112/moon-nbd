///|
/// A half-open byte range containing differences between two exports.
pub(all) struct Difference {
  offset : UInt64
  length : UInt64
}

///|
/// Compare a range from two NBD clients, returning exact contiguous differing bytes.
/// Sources must remain stable throughout the comparison. This scans all requested
/// bytes and raises when the result limit is exceeded rather than silently truncating.
pub async fn compare_ranges(
  left : Client,
  right : Client,
  offset : UInt64,
  length : UInt64,
  max_ranges~ : Int32 = 16384,
) -> Array[Difference] {
  if max_ranges <= 0 ||
    max_ranges > 1048576 ||
    offset > left.size ||
    offset > right.size ||
    length > left.size - offset ||
    length > right.size - offset {
    raise InvalidArgument("invalid comparison range or range limit")
  }
  let minimum = if left.min_block > right.min_block {
    left.min_block
  } else {
    right.min_block
  }
  let maximum = if left.max_block < right.max_block {
    left.max_block
  } else {
    right.max_block
  }
  if maximum < minimum ||
    offset % minimum.to_uint64() != 0UL ||
    length % minimum.to_uint64() != 0UL {
    raise InvalidArgument("comparison range violates block alignment")
  }
  let budget = if maximum < 1048576U { maximum } else { 1048576U }
  let chunk_size = if budget < minimum {
    minimum
  } else {
    budget - budget % minimum
  }
  let end = offset + length
  let ranges : Array[Difference] = []
  let mut current : UInt64? = None
  let mut position = offset
  while position < end {
    let remaining = end - position
    let count = if remaining < chunk_size.to_uint64() {
      remaining.to_int()
    } else {
      chunk_size.reinterpret_as_int()
    }
    let a = left.read_at(position, count)
    let b = right.read_at(position, count)
    for i in 0..<count {
      let here = position + i.to_uint64()
      if a[i] != b[i] {
        if current is None {
          current = Some(here)
        }
      } else {
        match current {
          Some(start) => {
            if ranges.length() >= max_ranges {
              raise LimitExceeded("difference range limit exceeded")
            }
            ranges.push({ offset: start, length: here - start, })
            current = None
          }
          None => ()
        }
      }
    }
    position += count.to_uint64()
  }
  match current {
    Some(start) => {
      if ranges.length() >= max_ranges {
        raise LimitExceeded("difference range limit exceeded")
      }
      ranges.push({ offset: start, length: end - start, })
    }
    None => ()
  }
  ranges
}
