///|
pub suberror NbdError {
  Protocol(String)
  InvalidArgument(String)
  Server(UInt32)
  OutcomeUnknown(String)
  LimitExceeded(String)
}

///|
fn put16(out : Array[Byte], n : UInt32) -> Unit {
  out.push(((n >> 8) & 255U).to_byte())
  out.push((n & 255U).to_byte())
}

///|
fn put32(out : Array[Byte], n : UInt32) -> Unit {
  put16(out, n >> 16)
  put16(out, n)
}

///|
fn put64(out : Array[Byte], n : UInt64) -> Unit {
  put32(out, (n >> 32).to_uint())
  put32(out, n.to_uint())
}

///|
fn get16(b : Bytes, at : Int32) -> UInt32 {
  (b[at].to_uint() << 8) | b[at + 1].to_uint()
}

///|
fn get32(b : Bytes, at : Int32) -> UInt32 {
  (get16(b, at) << 16) | get16(b, at + 2)
}

///|
fn get64(b : Bytes, at : Int32) -> UInt64 {
  (get32(b, at).to_uint64() << 32) | get32(b, at + 4).to_uint64()
}

///|
pub struct Client {
  priv tcp : @socket.Tcp
  size : UInt64
  flags : UInt32
  /// Minimum alignment advertised by the server, in bytes.
  min_block : UInt32
  /// Maximum request payload accepted by this client.
  max_block : UInt32
  structured : Bool
  priv allocation_context : UInt32?
  priv timeout_ms : Int32
  priv mut cookie : UInt64
  priv mut busy : Bool
  priv mut closed : Bool
}

///|
pub async fn Client::connect(
  host : String,
  port : Int32,
  export_name : Bytes,
  structured~ : Bool = false,
  allocation~ : Bool = false,
  timeout_ms~ : Int32 = 30000,
) -> Client {
  if port < 1 ||
    port > 65535 ||
    export_name.length() > 4096 ||
    (allocation && !structured) ||
    timeout_ms <= 0 {
    raise InvalidArgument("invalid port or export name")
  }
  @async.with_timeout(timeout_ms, () => {
    connect_inner(host, port, export_name, structured, allocation, timeout_ms)
  })
}

///|
async fn connect_inner(
  host : String,
  port : Int32,
  export_name : Bytes,
  structured : Bool,
  allocation : Bool,
  timeout_ms : Int32,
) -> Client {
  let tcp = @socket.Tcp::connect_to_host(host, port~)
  errdefer tcp.close()
  let no_zeroes = client_handshake(tcp)
  if structured {
    negotiate_structured(tcp)
  }
  let allocation_context = if allocation {
    Some(negotiate_allocation(tcp, export_name))
  } else {
    None
  }
  let info = negotiate_go(tcp, export_name, no_zeroes)
  {
    tcp,
    size: info.size,
    flags: info.flags,
    min_block: info.min_block,
    max_block: info.max_block,
    structured,
    allocation_context,
    timeout_ms,
    cookie: 0UL,
    busy: false,
    closed: false,
  }
}

///|
async fn client_handshake(tcp : @socket.Tcp) -> Bool {
  let greeting = tcp.read_exactly(18)
  if get64(greeting, 0) != 0x4e42444d41474943UL ||
    get64(greeting, 8) != 0x49484156454f5054UL {
    raise Protocol("not a newstyle NBD server")
  }
  let handshake = get16(greeting, 16)
  if (handshake & 1U) == 0U {
    raise Protocol("fixed newstyle required")
  }
  let no_zeroes = (handshake & 2U) != 0U
  let client_flags : Array[Byte] = []
  put32(client_flags, if no_zeroes { 3U } else { 1U })
  tcp.write(Bytes::from_array(client_flags))
  no_zeroes
}

///|
pub fn Client::close(self : Client) -> Unit {
  self.closed = true
  self.tcp.close()
}

///|
pub async fn Client::disconnect(self : Client) -> Unit {
  if self.closed || self.busy {
    raise InvalidArgument("client is closed or already in use")
  }
  self.busy = true
  defer {
    self.busy = false
    self.close()
  }
  let req : Array[Byte] = []
  put32(req, 0x25609513U)
  put16(req, 0U)
  put16(req, 2U)
  put64(req, 0UL)
  put64(req, 0UL)
  put32(req, 0U)
  @async.with_timeout(self.timeout_ms, () => {
    self.tcp.write(Bytes::from_array(req))
  })
}

///|
pub async fn Client::read_at(
  self : Client,
  offset : UInt64,
  length : Int32,
) -> Bytes {
  self.request(0U, 0U, offset, length, b"")
}

///|
pub async fn Client::write_at(
  self : Client,
  offset : UInt64,
  data : Bytes,
) -> Unit {
  if (self.flags & 2U) != 0U {
    raise InvalidArgument("export is read-only")
  }
  ignore(self.request(1U, 0U, offset, data.length(), data))
}

///|
pub async fn Client::flush(self : Client) -> Unit {
  if (self.flags & 4U) == 0U {
    raise InvalidArgument("server does not support flush")
  }
  ignore(self.request(3U, 0U, 0UL, 0, b""))
}

///|
/// Inform the server that a region is no longer needed; subsequent data is unspecified.
pub async fn Client::trim(
  self : Client,
  offset : UInt64,
  length : Int32,
) -> Unit {
  if (self.flags & 2U) != 0U || (self.flags & 32U) == 0U {
    raise InvalidArgument("trim unsupported or export is read-only")
  }
  ignore(self.request(4U, 0U, offset, length, b""))
}

///|
/// Write zeroes without transferring a zero-filled payload.
pub async fn Client::write_zeroes(
  self : Client,
  offset : UInt64,
  length : Int32,
  no_hole~ : Bool = false,
) -> Unit {
  if (self.flags & 2U) != 0U || (self.flags & 64U) == 0U {
    raise InvalidArgument("write zeroes unsupported or export is read-only")
  }
  ignore(self.request(6U, if no_hole { 2U } else { 0U }, offset, length, b""))
}

///|
/// Hint that a range will be read soon.
///
/// NBD cache is advisory: a successful reply does not guarantee that data is
/// resident locally, and callers must still issue `read_at` normally.
pub async fn Client::cache(
  self : Client,
  offset : UInt64,
  length : Int32,
) -> Unit {
  if (self.flags & 1024U) == 0U {
    raise InvalidArgument("server does not support cache hints")
  }
  ignore(self.request(5U, 0U, offset, length, b""))
}

///|
async fn Client::request(
  self : Client,
  command : UInt32,
  request_flags : UInt32,
  offset : UInt64,
  length : Int32,
  payload : Bytes,
) -> Bytes {
  if self.closed || self.busy {
    raise InvalidArgument("client is closed or already in use")
  }
  if command != 3U &&
    (
      length <= 0 ||
      length.reinterpret_as_uint() > self.max_block ||
      offset > self.size ||
      length.to_uint64() > self.size - offset ||
      offset % self.min_block.to_uint64() != 0UL ||
      length.reinterpret_as_uint() % self.min_block != 0U
    ) {
    raise InvalidArgument("range outside export or request limit")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer self.close()
  @async.with_timeout(self.timeout_ms, () => {
    self.request_exchange(command, request_flags, offset, length, payload)
  }) catch {
    e => raise request_error(e, command)
  }
}

///|
async fn Client::request_exchange(
  self : Client,
  command : UInt32,
  request_flags : UInt32,
  offset : UInt64,
  length : Int32,
  payload : Bytes,
) -> Bytes {
  self.cookie += 1UL
  let req : Array[Byte] = []
  put32(req, 0x25609513U)
  put16(req, request_flags)
  put16(req, command)
  put64(req, self.cookie)
  put64(req, offset)
  put32(req, length.reinterpret_as_uint())
  self.tcp.write(Bytes::from_array(req))
  if command == 1U {
    self.tcp.write(payload)
  }
  let header = self.tcp.read_exactly(16)
  if self.structured && command == 0U {
    return read_structured(self.tcp, header, self.cookie, offset, length)
  }
  if self.structured && get32(header, 0) == 0x668e33efU {
    return structured_command(self.tcp, header, self.cookie, offset, length)
  }
  if get32(header, 0) != 0x67446698U || get64(header, 8) != self.cookie {
    if command == 1U || command == 3U || command == 4U || command == 6U {
      raise OutcomeUnknown("invalid response to modifying request")
    }
    raise Protocol("invalid reply header or cookie")
  }
  let error = get32(header, 4)
  if error != 0U {
    raise Server(error)
  }
  if command == 0U {
    self.tcp.read_exactly(length)
  } else {
    b""
  }
}

///|
fn request_error(error : Error, command : UInt32) -> Error {
  if error is Server(_) {
    return error
  }
  if command == 1U || command == 3U || command == 4U || command == 6U {
    OutcomeUnknown("connection lost after request: \{error}")
  } else {
    error
  }
}
