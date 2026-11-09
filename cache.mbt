///|
/// Observable counters for a `CachedClient` instance.
pub(all) struct CacheStats {
  hits : UInt64
  misses : UInt64
  evictions : UInt64
  entries : Int32
}

///|
priv struct CacheLine {
  offset : UInt64
  data : Bytes
  used_at : UInt64
}

///|
/// A bounded LRU cache around one NBD connection.
///
/// It is intended for stable exports such as snapshots and read-mostly disk
/// images. It deliberately keeps the single-request semantics of `Client`;
/// callers must not use it concurrently. Mutating methods invalidate every
/// overlapping cache line before sending a request.
pub struct CachedClient {
  priv client : Client
  priv line_size : UInt32
  priv slots : Array[CacheLine?]
  priv mut clock : UInt64
  priv mut hits : UInt64
  priv mut misses : UInt64
  priv mut evictions : UInt64
}

///|
/// Connect and allocate a bounded cache.
///
/// `cache_bytes` is a capacity budget, not an eager allocation. `line_size`
/// defaults to the server's maximum request size capped at 1 MiB. A line must
/// be a multiple of the negotiated minimum block size.
pub async fn CachedClient::connect(
  host : String,
  port : Int32,
  export_name : Bytes,
  cache_bytes : Int32,
  line_size~ : Int32 = 0,
  structured~ : Bool = false,
  timeout_ms~ : Int32 = 30000,
) -> CachedClient {
  if cache_bytes <= 0 || cache_bytes > 67108864 || line_size < 0 {
    raise InvalidArgument("invalid cache capacity or line size")
  }
  let client = Client::connect(
    host,
    port,
    export_name,
    structured~,
    timeout_ms~,
  )
  errdefer client.close()
  let preferred = if client.max_block < 1048576U {
    client.max_block
  } else {
    1048576U
  }
  let requested = if line_size == 0 {
    if preferred < cache_bytes.reinterpret_as_uint() {
      preferred
    } else {
      cache_bytes.reinterpret_as_uint()
    }
  } else {
    line_size.reinterpret_as_uint()
  }
  let minimum = client.min_block
  let actual = requested - requested % minimum
  if actual == 0U ||
    actual > client.max_block ||
    actual < minimum ||
    (line_size != 0 && actual != requested) {
    raise InvalidArgument("cache line violates server block constraints")
  }
  let lines = cache_bytes.reinterpret_as_uint() / actual
  if lines == 0U || lines > 65536U {
    raise InvalidArgument("cache capacity is too small or has too many lines")
  }
  {
    client,
    line_size: actual,
    slots: Array::make(lines.reinterpret_as_int(), None),
    clock: 0UL,
    hits: 0UL,
    misses: 0UL,
    evictions: 0UL,
  }
}

///|
pub fn CachedClient::size(self : CachedClient) -> UInt64 {
  self.client.size
}

///|
pub fn CachedClient::line_size(self : CachedClient) -> UInt32 {
  self.line_size
}

///|
pub fn CachedClient::stats(self : CachedClient) -> CacheStats {
  let mut entries = 0
  for slot in self.slots {
    if slot is Some(_) {
      entries += 1
    }
  }
  { hits: self.hits, misses: self.misses, evictions: self.evictions, entries, }
}

///|
fn CachedClient::next_tick(self : CachedClient) -> UInt64 {
  self.clock += 1UL
  // Drop old lines when the clock wraps rather than inventing an LRU order.
  if self.clock == 0UL {
    for i in 0..<self.slots.length() {
      self.slots[i] = None
    }
    self.clock = 1UL
  }
  self.clock
}

///|
fn CachedClient::find_line(self : CachedClient, offset : UInt64) -> Int32? {
  for i in 0..<self.slots.length() {
    match self.slots[i] {
      Some(line) if line.offset == offset => return Some(i)
      _ => ()
    }
  }
  None
}

///|
fn CachedClient::victim_slot(self : CachedClient) -> Int32 {
  let mut oldest = 0UL
  let mut victim = 0
  for i in 0..<self.slots.length() {
    match self.slots[i] {
      None => return i
      Some(line) =>
        if i == 0 || line.used_at < oldest {
          oldest = line.used_at
          victim = i
        }
    }
  }
  self.evictions += 1UL
  victim
}

///|
async fn CachedClient::load_line(self : CachedClient, offset : UInt64) -> Bytes {
  match self.find_line(offset) {
    Some(index) => {
      self.hits += 1UL
      let line = self.slots[index].unwrap()
      let data = line.data
      self.slots[index] = Some({ ..line, used_at: self.next_tick(), })
      data
    }
    None => {
      self.misses += 1UL
      let remaining = self.client.size - offset
      let count = if remaining < self.line_size.to_uint64() {
        remaining.to_int()
      } else {
        self.line_size.reinterpret_as_int()
      }
      let data = self.client.read_at(offset, count)
      let index = self.victim_slot()
      self.slots[index] = Some({ offset, data, used_at: self.next_tick(), })
      data
    }
  }
}

///|
/// Read a range through the cache. Range validation matches `Client::read_at`.
pub async fn CachedClient::read_at(
  self : CachedClient,
  offset : UInt64,
  length : Int32,
) -> Bytes {
  if self.client.closed ||
    self.client.busy ||
    length <= 0 ||
    length.reinterpret_as_uint() > self.client.max_block ||
    offset > self.client.size ||
    length.to_uint64() > self.client.size - offset ||
    offset % self.client.min_block.to_uint64() != 0UL ||
    length.reinterpret_as_uint() % self.client.min_block != 0U {
    raise InvalidArgument("range outside export or request limit")
  }
  let output : Array[Byte] = Array::make(length, b'\x00')
  let end = offset + length.to_uint64()
  let block = self.line_size.to_uint64()
  let mut position = offset
  while position < end {
    let line_offset = position - position % block
    let line = self.load_line(line_offset)
    let from = (position - line_offset).to_int()
    let available = line.length() - from
    let needed = (end - position).to_int()
    let count = if available < needed { available } else { needed }
    let output_at = (position - offset).to_int()
    for i in 0..<count {
      output[output_at + i] = line[from + i]
    }
    position += count.to_uint64()
  }
  Bytes::from_array(output)
}

///|
fn CachedClient::invalidate(
  self : CachedClient,
  offset : UInt64,
  length : UInt64,
) -> Unit {
  for i in 0..<self.slots.length() {
    match self.slots[i] {
      Some(line) => {
        let line_end = line.offset + line.data.length().to_uint64()
        if offset < line_end &&
          (line.offset <= offset || line.offset - offset < length) {
          self.slots[i] = None
        }
      }
      None => ()
    }
  }
}

///|
pub async fn CachedClient::write_at(
  self : CachedClient,
  offset : UInt64,
  data : Bytes,
) -> Unit {
  self.invalidate(offset, data.length().to_uint64())
  self.client.write_at(offset, data)
}

///|
pub async fn CachedClient::trim(
  self : CachedClient,
  offset : UInt64,
  length : Int32,
) -> Unit {
  if length <= 0 {
    raise InvalidArgument("trim length must be positive")
  }
  self.invalidate(offset, length.to_uint64())
  self.client.trim(offset, length)
}

///|
pub async fn CachedClient::write_zeroes(
  self : CachedClient,
  offset : UInt64,
  length : Int32,
  no_hole~ : Bool = false,
) -> Unit {
  if length <= 0 {
    raise InvalidArgument("write-zeroes length must be positive")
  }
  self.invalidate(offset, length.to_uint64())
  self.client.write_zeroes(offset, length, no_hole~)
}

///|
pub async fn CachedClient::flush(self : CachedClient) -> Unit {
  self.client.flush()
}

///|
pub async fn CachedClient::disconnect(self : CachedClient) -> Unit {
  self.client.disconnect()
}

///|
pub fn CachedClient::close(self : CachedClient) -> Unit {
  self.client.close()
}
