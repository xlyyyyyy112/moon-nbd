///|
/// One consecutive extent from the base:allocation context.
pub(all) struct AllocationExtent {
  offset : UInt64
  length : UInt32
  flags : UInt32
}

///|
pub fn AllocationExtent::is_hole(self : AllocationExtent) -> Bool {
  (self.flags & 1U) != 0U
}

///|
pub fn AllocationExtent::is_zero(self : AllocationExtent) -> Bool {
  (self.flags & 2U) != 0U
}

///|
/// Byte and extent counts returned by an allocation scan.
///
/// `hole_bytes` and `zero_bytes` are independent flags and can overlap.
/// `other_bytes` has neither flag set; it describes only what the server
/// reported and does not assert that the bytes contain nonzero data.
pub(all) struct AllocationSummary {
  range_bytes : UInt64
  hole_bytes : UInt64
  zero_bytes : UInt64
  other_bytes : UInt64
  hole_extents : Int32
  zero_extents : Int32
  other_extents : Int32
}

///|
/// Scan allocation metadata and total bytes by the flags the server reported.
///
/// Servers may return a different number of extents for the same image, so the
/// extent limit is explicit and bounded. The report is descriptive: it does
/// not imply that a hole can be omitted from a byte-for-byte export.
pub async fn Client::allocation_summary(
  self : Client,
  offset : UInt64,
  length : UInt64,
  max_extents~ : Int32 = 16384,
) -> AllocationSummary {
  let extents = self.scan_allocation(offset, length, max_extents~)
  let mut hole_bytes = 0UL
  let mut zero_bytes = 0UL
  let mut other_bytes = 0UL
  let mut hole_count = 0
  let mut zero_count = 0
  let mut other_count = 0
  for extent in extents {
    let size = extent.length.to_uint64()
    let hole = extent.is_hole()
    let zero = extent.is_zero()
    if hole {
      hole_bytes += size
      hole_count += 1
    }
    if zero {
      zero_bytes += size
      zero_count += 1
    }
    if !hole && !zero {
      other_bytes += size
      other_count += 1
    }
  }
  {
    range_bytes: length,
    hole_bytes,
    zero_bytes,
    other_bytes,
    hole_extents: hole_count,
    zero_extents: zero_count,
    other_extents: other_count,
  }
}

///|
async fn negotiate_allocation(tcp : @socket.Tcp, name : Bytes) -> UInt32 {
  let body : Array[Byte] = []
  put32(body, name.length().reinterpret_as_uint())
  for b in name {
    body.push(b)
  }
  put32(body, 1U)
  let query = b"base:allocation"
  put32(body, query.length().reinterpret_as_uint())
  for b in query {
    body.push(b)
  }
  send_option(tcp, 10U, Bytes::from_array(body))
  let mut context : UInt32? = None
  for _ in 0..<256 {
    let hdr = tcp.read_exactly(20)
    if get64(hdr, 0) != 0x0003e889045565a9UL || get32(hdr, 8) != 10U {
      raise Protocol("invalid metadata option response")
    }
    let kind = get32(hdr, 12)
    let len = get32(hdr, 16)
    if len > 65536U {
      raise Protocol("metadata option reply too large")
    }
    let data = tcp.read_exactly(len.reinterpret_as_int())
    if (kind & 0x80000000U) != 0U {
      raise Server(kind)
    }
    if kind == 1U {
      if len != 0U {
        raise Protocol("invalid metadata acknowledgement")
      }
      return match context {
        Some(id) => id
        None => raise Protocol("base:allocation was not offered")
      }
    }
    if kind != 4U || len < 4U {
      raise Protocol("invalid metadata context")
    }
    if data[4:].to_owned() == query {
      if context is Some(_) {
        raise Protocol("duplicate allocation context")
      }
      context = Some(get32(data, 0))
    } else {
      raise Protocol("server selected an unrequested context")
    }
  }
  raise Protocol("too many metadata replies")
}

///|
/// Returns at least one extent. Servers may return less than the requested range.
pub async fn Client::block_status(
  self : Client,
  offset : UInt64,
  length : Int32,
) -> Array[AllocationExtent] {
  let context = match self.allocation_context {
    Some(id) => id
    None => raise InvalidArgument("allocation context was not negotiated")
  }
  if self.closed ||
    self.busy ||
    length <= 0 ||
    length.reinterpret_as_uint() > self.max_block ||
    offset > self.size ||
    length.to_uint64() > self.size - offset ||
    offset % self.min_block.to_uint64() != 0UL ||
    length.reinterpret_as_uint() % self.min_block != 0U {
    raise InvalidArgument("invalid block status request")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer self.close()
  @async.with_timeout(self.timeout_ms, () => {
    self.block_status_request(context, offset, length)
  })
}

///|
async fn Client::block_status_request(
  self : Client,
  context : UInt32,
  offset : UInt64,
  length : Int32,
) -> Array[AllocationExtent] {
  self.cookie += 1UL
  let req : Array[Byte] = []
  put32(req, 0x25609513U)
  put16(req, 0U)
  put16(req, 7U)
  put64(req, self.cookie)
  put64(req, offset)
  put32(req, length.reinterpret_as_uint())
  self.tcp.write(Bytes::from_array(req))
  let mut found = false
  let extents : Array[AllocationExtent] = []
  for _ in 0..<256 {
    let header = self.tcp.read_exactly(20)
    if get32(header, 0) != 0x668e33efU || get64(header, 8) != self.cookie {
      raise Protocol("invalid block status header")
    }
    let flags = get16(header, 4)
    let kind = get16(header, 6)
    let len = get32(header, 16)
    if len > 8388612U {
      raise Protocol("block status response exceeds limit")
    }
    let data = self.tcp.read_exactly(len.reinterpret_as_int())
    if (kind & 0x8000U) != 0U {
      raise Server(structured_error_code(kind, data, offset, length))
    }
    if kind == 5U {
      if found ||
        len < 12U ||
        (len - 4U) % 8U != 0U ||
        get32(data, 0) != context {
        raise Protocol("invalid allocation extent reply")
      }
      found = true
      let mut pos = offset
      let mut at = 4
      while at < data.length() {
        let count = get32(data, at)
        if count == 0U ||
          pos >= offset + length.to_uint64() ||
          count.to_uint64() > self.size - pos {
          raise Protocol("invalid allocation extent range")
        }
        extents.push({ offset: pos, length: count, flags: get32(data, at + 4), })
        pos += count.to_uint64()
        at += 8
      }
    } else if kind != 0U || len != 0U || (flags & 1U) == 0U {
      raise Protocol("unexpected block status reply")
    }
    if (flags & 1U) != 0U {
      if !found {
        raise Protocol("missing allocation extents")
      }
      return extents
    }
  }
  raise Protocol("too many block status replies")
}

///|
/// Query a complete range, continuing when the server returns only a prefix.
/// Returned extents are clipped to the requested range and capped by max_extents.
pub async fn Client::scan_allocation(
  self : Client,
  offset : UInt64,
  length : UInt64,
  max_extents~ : Int32 = 16384,
) -> Array[AllocationExtent] {
  if max_extents <= 0 ||
    max_extents > 1048576 ||
    offset > self.size ||
    length > self.size - offset ||
    offset % self.min_block.to_uint64() != 0UL ||
    length % self.min_block.to_uint64() != 0UL {
    raise InvalidArgument("invalid allocation scan range or extent limit")
  }
  let result : Array[AllocationExtent] = []
  let end = offset + length
  let mut pos = offset
  while pos < end {
    let remaining = end - pos
    let chunk = if remaining < self.max_block.to_uint64() {
      remaining.to_int()
    } else {
      self.max_block.reinterpret_as_int()
    }
    let extents = self.block_status(pos, chunk)
    for extent in extents {
      if extent.offset != pos {
        raise Protocol("allocation scan returned a gap")
      }
      let available = end - pos
      let count = if extent.length.to_uint64() > available {
        available.to_uint()
      } else {
        extent.length
      }
      if result.length() >= max_extents {
        raise InvalidArgument("allocation extent limit exceeded")
      }
      result.push({ offset: pos, length: count, flags: extent.flags, })
      pos += count.to_uint64()
    }
    if pos < end && pos % self.min_block.to_uint64() != 0UL {
      raise Protocol("server returned an unaligned partial extent")
    }
  }
  result
}
