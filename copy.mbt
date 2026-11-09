///|
/// Copy the complete export to an empty regular file in bounded chunks.
/// A failed operation may leave a partial output file; the caller owns it.
pub async fn Client::copy_to_file(self : Client, file : @fs.File) -> UInt64 {
  if file.kind() != Regular || file.size() != 0L {
    raise InvalidArgument("copy target must be an empty regular file")
  }
  if self.size > 0x7fffffffffffffffUL ||
    self.size % self.min_block.to_uint64() != 0UL {
    raise InvalidArgument(
      "export size cannot be copied with current block constraints",
    )
  }
  let mut offset = 0UL
  while offset < self.size {
    let remaining = self.size - offset
    let n = if remaining < self.max_block.to_uint64() {
      remaining.to_int()
    } else {
      self.max_block.reinterpret_as_int()
    }
    let data = self.read_at(offset, n)
    file.write_at(data[:], position=offset.reinterpret_as_int64())
    offset += data.length().to_uint64()
  }
  file.sync()
  offset
}

///|
/// Result of copying an explicit set of source ranges to an existing image.
pub(all) struct RangeCopyStats {
  ranges : Int32
  bytes : UInt64
}

///|
/// Copy selected ranges into an existing same-size regular file.
///
/// Unlike `copy_to_file`, this operation intentionally preserves every byte
/// outside `ranges`; it is suitable for updating a previously created image.
/// The caller must ensure that the destination represents the desired baseline
/// and that the remote export is stable throughout the copy.
pub async fn Client::copy_ranges_to_file(
  self : Client,
  file : @fs.File,
  ranges : RangeSet,
) -> RangeCopyStats {
  if file.kind() != Regular ||
    file.size() < 0L ||
    file.size().reinterpret_as_uint64() != self.size {
    raise InvalidArgument("range copy target must be a same-size regular file")
  }
  if ranges.alignment() != self.min_block.to_uint64() {
    raise InvalidArgument("range copy alignment differs from export block size")
  }
  let mut copied = 0UL
  let source_ranges = ranges.ranges()
  for range in source_ranges {
    if range.offset > self.size || range.length > self.size - range.offset {
      raise InvalidArgument("range copy is outside export")
    }
    let end = range.offset + range.length
    let mut offset = range.offset
    while offset < end {
      let remaining = end - offset
      let length = if remaining < self.max_block.to_uint64() {
        remaining.to_int()
      } else {
        self.max_block.reinterpret_as_int()
      }
      let data = self.read_at(offset, length)
      file.write_at(data[:], position=offset.reinterpret_as_int64())
      copied += data.length().to_uint64()
      offset += data.length().to_uint64()
    }
  }
  file.sync()
  { ranges: source_ranges.length(), bytes: copied, }
}

///|
/// Compare two stable NBD exports and update only differing bytes in a local
/// same-size image. `source` supplies replacement data while `baseline` is
/// read only for comparison; all three artefacts must remain stable during the
/// operation.
pub async fn copy_differences_to_file(
  source : Client,
  baseline : Client,
  file : @fs.File,
  offset : UInt64,
  length : UInt64,
  max_ranges~ : Int32 = 16384,
) -> RangeCopyStats {
  let differences = compare_ranges(
    source,
    baseline,
    offset,
    length,
    max_ranges~,
  )
  let requested : Array[ByteRange] = []
  for difference in differences {
    requested.push({ offset: difference.offset, length: difference.length, })
  }
  let ranges = source.range_set(requested)
  source.copy_ranges_to_file(file, ranges)
}

///|
/// Summary of a completed sparse export.
///
/// `data_bytes` is the number of bytes read from the server and written to the
/// target. `zero_bytes` was omitted only when the server explicitly described
/// it as reading as zero; a hole alone is deliberately not enough to omit it.
pub(all) struct SparseCopyStats {
  logical_bytes : UInt64
  data_bytes : UInt64
  zero_bytes : UInt64
  extents : Int32
}

///|
async fn Client::copy_sparse_extent(
  self : Client,
  file : @fs.File,
  extent : AllocationExtent,
) -> UInt64 {
  let block = self.min_block.to_uint64()
  let extent_end = extent.offset + extent.length.to_uint64()
  let mut read_offset = extent.offset - extent.offset % block
  let remainder = extent_end % block
  let read_end = if remainder == 0UL {
    extent_end
  } else {
    extent_end + block - remainder
  }
  let mut copied = 0UL
  while read_offset < read_end {
    let remaining = read_end - read_offset
    let request = if remaining < self.max_block.to_uint64() {
      remaining.to_int()
    } else {
      self.max_block.reinterpret_as_int()
    }
    let data = self.read_at(read_offset, request)
    let chunk_end = read_offset + data.length().to_uint64()
    let write_from = if read_offset > extent.offset {
      read_offset
    } else {
      extent.offset
    }
    let write_until = if chunk_end < extent_end {
      chunk_end
    } else {
      extent_end
    }
    if write_from < write_until {
      let begin = (write_from - read_offset).to_int()
      let end = (write_until - read_offset).to_int()
      file.write_at(data[begin:end], position=write_from.reinterpret_as_int64())
      copied += write_until - write_from
    }
    read_offset = chunk_end
  }
  copied
}

///|
/// Copy an export using the negotiated `base:allocation` context.
///
/// The destination must be a new empty regular file. It is first extended to
/// the logical export size, then only extents not explicitly marked ZERO are
/// written. This preserves byte-for-byte contents while allowing sparse-file
/// aware filesystems to avoid allocating known-zero regions. The remote export
/// must not change during the operation. A failed operation leaves a partial
/// target and the caller owns that target.
pub async fn Client::copy_sparse_to_file(
  self : Client,
  file : @fs.File,
  max_extents~ : Int32 = 16384,
) -> SparseCopyStats {
  if file.kind() != Regular || file.size() != 0L {
    raise InvalidArgument("sparse copy target must be an empty regular file")
  }
  if self.allocation_context is None {
    raise InvalidArgument(
      "sparse copy requires a negotiated allocation context",
    )
  }
  if self.size > 0x7fffffffffffffffUL ||
    self.size % self.min_block.to_uint64() != 0UL {
    raise InvalidArgument(
      "export size cannot be copied with current block constraints",
    )
  }
  if self.size == 0UL {
    return { logical_bytes: 0UL, data_bytes: 0UL, zero_bytes: 0UL, extents: 0, }
  }
  // Extending with one zero byte gives skipped extents defined zero contents.
  // It does not rely on the host filesystem actually storing that byte sparsely.
  file.write_at(b"\x00", position=(self.size - 1UL).reinterpret_as_int64())
  let extents = self.scan_allocation(0UL, self.size, max_extents~)
  let mut written = 0UL
  let mut zeroes = 0UL
  for extent in extents {
    if extent.is_zero() {
      zeroes += extent.length.to_uint64()
    } else {
      written += self.copy_sparse_extent(file, extent)
    }
  }
  file.sync()
  {
    logical_bytes: self.size,
    data_bytes: written,
    zero_bytes: zeroes,
    extents: extents.length(),
  }
}
