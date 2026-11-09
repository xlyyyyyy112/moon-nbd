///|
async fn negotiate_structured(tcp : @socket.Tcp) -> Unit {
  send_option(tcp, 8U, b"")
  let header = tcp.read_exactly(20)
  if get64(header, 0) != 0x0003e889045565a9UL || get32(header, 8) != 8U {
    raise Protocol("invalid structured negotiation reply")
  }
  let kind = get32(header, 12)
  let len = get32(header, 16)
  if len > 65536U {
    raise Protocol("option reply too large")
  }
  ignore(tcp.read_exactly(len.reinterpret_as_int()))
  if (kind & 0x80000000U) != 0U {
    raise Server(kind)
  }
  if kind != 1U || len != 0U {
    raise Protocol("invalid structured acknowledgement")
  }
}

///|
async fn structured_command(
  tcp : @socket.Tcp,
  header : Bytes,
  cookie : UInt64,
) -> Bytes {
  if get64(header, 8) != cookie {
    raise Protocol("structured cookie mismatch")
  }
  let flags = get16(header, 4)
  let kind = get16(header, 6)
  let len = get32(tcp.read_exactly(4), 0)
  if len > 4102U {
    raise Protocol("structured command payload too large")
  }
  let body = tcp.read_exactly(len.reinterpret_as_int())
  if (kind & 0x8000U) != 0U {
    if len < 6U || get32(body, 0) == 0U || get16(body, 4) > len - 6U {
      raise Protocol("invalid structured error")
    }
    raise Server(get32(body, 0))
  }
  if kind != 0U || len != 0U || (flags & 1U) == 0U {
    raise Protocol("invalid structured command reply")
  }
  b""
}

///|
/// Assemble out-of-order chunks, rejecting overlaps and incomplete replies.
async fn read_structured(
  tcp : @socket.Tcp,
  first : Bytes,
  cookie : UInt64,
  start : UInt64,
  length : Int32,
) -> Bytes {
  let output : Array[Byte] = Array::make(length, b'\x00')
  let covered : Array[Bool] = Array::make(length, false)
  let mut total = 0
  let mut header = first
  for _ in 0..<65536 {
    if get32(header, 0) != 0x668e33efU || get64(header, 8) != cookie {
      raise Protocol("invalid structured reply header or cookie")
    }
    let flags = get16(header, 4)
    let kind = get16(header, 6)
    let payload_len = get32(tcp.read_exactly(4), 0)
    if payload_len > length.reinterpret_as_uint() + 8U && payload_len > 4102U {
      raise Protocol("structured payload exceeds request")
    }
    let body = tcp.read_exactly(payload_len.reinterpret_as_int())
    if (kind & 0x8000U) != 0U {
      if payload_len < 6U ||
        get32(body, 0) == 0U ||
        get16(body, 4) > 4096U ||
        get16(body, 4) > payload_len - 6U {
        raise Protocol("invalid structured error")
      }
      raise Server(get32(body, 0))
    }
    match kind {
      0U =>
        if payload_len != 0U || (flags & 1U) == 0U {
          raise Protocol("invalid empty reply")
        }
      1U | 2U => {
        if (kind == 1U && payload_len <= 8U) ||
          (kind == 2U && payload_len != 12U) {
          raise Protocol("invalid structured data chunk")
        }
        let offset = get64(body, 0)
        let count = if kind == 1U { payload_len - 8U } else { get32(body, 8) }
        if count == 0U ||
          offset < start ||
          offset - start > length.to_uint64() ||
          count.to_uint64() > length.to_uint64() - (offset - start) {
          raise Protocol("structured chunk outside requested range")
        }
        let relative = (offset - start).to_int()
        for i in 0..<count.reinterpret_as_int() {
          let index = relative + i
          if covered[index] {
            raise Protocol("overlapping structured chunks")
          }
          covered[index] = true
          if kind == 1U {
            output[index] = body[8 + i]
          }
        }
        total += count.reinterpret_as_int()
      }
      _ => raise Protocol("unexpected structured chunk type")
    }
    if (flags & 1U) != 0U {
      if total != length {
        raise Protocol("incomplete structured read")
      }
      return Bytes::from_array(output)
    }
    header = tcp.read_exactly(16)
  }
  raise Protocol("too many structured chunks")
}
