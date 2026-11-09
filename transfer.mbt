///|
/// Result of comparing a local image with a remote export.
pub(all) struct FileCompareStats {
  bytes_checked : UInt64
  differences : Array[Difference]
}

///|
/// Read an arbitrary byte range by rounding wire requests to block boundaries.
///
/// NBD servers can require aligned offsets and lengths. This helper reads the
/// surrounding blocks and returns only the requested bytes.
pub async fn Client::read_bytes(
  self : Client,
  offset : UInt64,
  length : Int32,
) -> Bytes {
  if length < 0 ||
    length.reinterpret_as_uint() > self.max_block ||
    offset > self.size ||
    length.to_uint64() > self.size - offset {
    raise InvalidArgument("byte range outside export or exceeds read limit")
  }
  if length == 0 {
    return b""
  }
  let block = self.min_block.to_uint64()
  let requested_end = offset + length.to_uint64()
  let mut cursor = offset - offset % block
  let output : Array[Byte] = Array::make(length, b'\x00')
  while cursor < requested_end {
    let remaining = requested_end - cursor
    let end_remainder = requested_end % block
    let aligned_remaining = if end_remainder == 0UL {
      remaining
    } else {
      remaining + block - end_remainder
    }
    let count = if aligned_remaining < self.max_block.to_uint64() {
      aligned_remaining.to_int()
    } else {
      self.max_block.reinterpret_as_int()
    }
    let data = self.read_at(cursor, count)
    let chunk_end = cursor + data.length().to_uint64()
    let copy_start = if cursor < offset { offset } else { cursor }
    let copy_end = if chunk_end < requested_end {
      chunk_end
    } else {
      requested_end
    }
    if copy_start >= copy_end {
      raise Protocol("aligned read did not cover requested bytes")
    }
    let source_at = (copy_start - cursor).to_int()
    let output_at = (copy_start - offset).to_int()
    let copy_length = (copy_end - copy_start).to_int()
    for i in 0..<copy_length {
      output[output_at + i] = data[source_at + i]
    }
    cursor = chunk_end
  }
  Bytes::from_array(output)
}

///|
/// Write a local regular file into the remote export.
///
/// The file must have exactly the export's logical size. On failure, earlier
/// requests may already have been applied. The file and export must remain
/// stable during the copy. If supported by the server, FLUSH is issued at the
/// end; otherwise the acknowledged writes are left in the server's cache.
pub async fn Client::copy_from_file(self : Client, file : @fs.File) -> UInt64 {
  if file.kind() != Regular ||
    file.size() < 0L ||
    file.size().reinterpret_as_uint64() != self.size {
    raise InvalidArgument("import source must be a same-size regular file")
  }
  if (self.flags & 2U) != 0U {
    raise InvalidArgument("export is read-only")
  }
  let ranges = if self.size == 0UL {
    self.range_set([])
  } else {
    self.range_set([{ offset: 0UL, length: self.size, }])
  }
  self.copy_file_ranges(file, ranges)
}

///|
/// Copy selected ranges from a same-size local image into the export.
/// All ranges are validated before the first remote write.
pub async fn Client::copy_file_ranges(
  self : Client,
  file : @fs.File,
  ranges : RangeSet,
) -> UInt64 {
  if file.kind() != Regular ||
    file.size() < 0L ||
    file.size().reinterpret_as_uint64() != self.size {
    raise InvalidArgument(
      "range import source must be a same-size regular file",
    )
  }
  if (self.flags & 2U) != 0U {
    raise InvalidArgument("export is read-only")
  }
  if ranges.alignment() != self.min_block.to_uint64() {
    raise InvalidArgument("range import alignment differs from export")
  }
  let planned = ranges.ranges()
  for range in planned {
    if range.length == 0UL ||
      range.offset % self.min_block.to_uint64() != 0UL ||
      range.length % self.min_block.to_uint64() != 0UL ||
      range.offset > self.size ||
      range.length > self.size - range.offset {
      raise InvalidArgument("invalid range import plan")
    }
  }
  let mut copied = 0UL
  for range in planned {
    let end = range.offset + range.length
    let mut position = range.offset
    while position < end {
      let remaining = end - position
      let count = if remaining < self.max_block.to_uint64() {
        remaining.to_int()
      } else {
        self.max_block.reinterpret_as_int()
      }
      let data = file.read_exactly_at(
        count,
        position=position.reinterpret_as_int64(),
      )
      self.write_at(position, data)
      position += data.length().to_uint64()
      copied += data.length().to_uint64()
    }
  }
  if (self.flags & 4U) != 0U {
    self.flush()
  }
  copied
}

///|
/// Compare a local same-size image against a range of this export.
/// Difference offsets are absolute export offsets and adjacent changed bytes
/// are coalesced. Both inputs must remain stable during the comparison.
pub async fn Client::compare_file(
  self : Client,
  file : @fs.File,
  offset : UInt64,
  length : UInt64,
  max_ranges~ : Int32 = 16384,
) -> FileCompareStats {
  if file.kind() != Regular ||
    file.size() < 0L ||
    file.size().reinterpret_as_uint64() != self.size {
    raise InvalidArgument("comparison source must be a same-size regular file")
  }
  if max_ranges <= 0 ||
    max_ranges > 1048576 ||
    offset > self.size ||
    length > self.size - offset {
    raise InvalidArgument("invalid file comparison range or result limit")
  }
  let differences : Array[Difference] = []
  let mut changed_at : UInt64? = None
  let mut position = offset
  let end = offset + length
  let chunk_limit = if self.max_block < 1048576U {
    self.max_block
  } else {
    1048576U
  }
  while position < end {
    let remaining = end - position
    let count = if remaining < chunk_limit.to_uint64() {
      remaining.to_int()
    } else {
      chunk_limit.reinterpret_as_int()
    }
    let source_chunk = file.read_exactly_at(
      count,
      position=position.reinterpret_as_int64(),
    )
    let remote = self.read_bytes(position, count)
    for i in 0..<count {
      let current = position + i.to_uint64()
      if source_chunk[i] != remote[i] {
        if changed_at is None {
          changed_at = Some(current)
        }
      } else {
        match changed_at {
          Some(start) => {
            if differences.length() >= max_ranges {
              raise LimitExceeded("file comparison range limit exceeded")
            }
            differences.push({ offset: start, length: current - start, })
            changed_at = None
          }
          None => ()
        }
      }
    }
    position += count.to_uint64()
  }
  match changed_at {
    Some(start) => {
      if differences.length() >= max_ranges {
        raise LimitExceeded("file comparison range limit exceeded")
      }
      differences.push({ offset: start, length: end - start, })
    }
    None => ()
  }
  { bytes_checked: length, differences, }
}

///|
/// Import only the changed parts of a local image into this export.
/// Changed bytes expand to the export's minimum block boundaries so each NBD
/// write remains valid. The caller must ensure both inputs remain stable.
pub async fn Client::copy_differences_from_file(
  self : Client,
  file : @fs.File,
  offset : UInt64,
  length : UInt64,
  max_ranges~ : Int32 = 16384,
) -> UInt64 {
  let comparison = self.compare_file(file, offset, length, max_ranges~)
  let aligned = aligned_differences(
    comparison.differences,
    self.min_block.to_uint64(),
  )
  let ranges = self.range_set(aligned)
  self.copy_file_ranges(file, ranges)
}
