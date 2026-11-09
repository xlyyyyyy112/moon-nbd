///|
priv struct ExportInfo {
  size : UInt64
  flags : UInt32
  min_block : UInt32
  max_block : UInt32
}

///|
async fn send_option(
  tcp : @socket.Tcp,
  option : UInt32,
  payload : Bytes,
) -> Unit {
  let out : Array[Byte] = []
  put64(out, 0x49484156454f5054UL)
  put32(out, option)
  put32(out, payload.length().reinterpret_as_uint())
  for b in payload {
    out.push(b)
  }
  tcp.write(Bytes::from_array(out))
}

///|
async fn legacy_export(
  tcp : @socket.Tcp,
  name : Bytes,
  no_zeroes : Bool,
) -> ExportInfo {
  send_option(tcp, 1U, name)
  let data = tcp.read_exactly(if no_zeroes { 10 } else { 134 })
  let flags = get16(data, 8)
  if (flags & 1U) == 0U {
    raise Protocol("server did not set HAS_FLAGS")
  }
  { size: get64(data, 0), flags, min_block: 1U, max_block: 16777216U, }
}

///|
async fn negotiate_go(
  tcp : @socket.Tcp,
  name : Bytes,
  no_zeroes : Bool,
) -> ExportInfo {
  let body : Array[Byte] = []
  put32(body, name.length().reinterpret_as_uint())
  for b in name {
    body.push(b)
  }
  put16(body, 1U)
  put16(body, 3U)
  send_option(tcp, 7U, Bytes::from_array(body))
  let mut size = 0UL
  let mut flags = 0U
  let mut minimum = 1U
  let mut maximum = 16777216U
  let mut got_export = false
  let mut got_block = false
  for _ in 0..<256 {
    let header = tcp.read_exactly(20)
    if get64(header, 0) != 0x0003e889045565a9UL || get32(header, 8) != 7U {
      raise Protocol("invalid option reply header")
    }
    let kind = get32(header, 12)
    let length = get32(header, 16)
    if length > 65536U {
      raise Protocol("option reply exceeds limit")
    }
    let data = tcp.read_exactly(length.reinterpret_as_int())
    if kind == 0x80000001U {
      if got_export || got_block {
        raise Protocol("unsupported reply after export info")
      }
      return legacy_export(tcp, name, no_zeroes)
    }
    if (kind & 0x80000000U) != 0U {
      raise Server(kind)
    }
    if kind == 1U {
      if length != 0U || !got_export {
        raise Protocol("incomplete GO reply")
      }
      if size % minimum.to_uint64() != 0UL {
        raise Protocol("export size violates negotiated minimum block size")
      }
      return { size, flags, min_block: minimum, max_block: maximum, }
    }
    if kind != 3U || length < 2U {
      raise Protocol("unexpected GO response")
    }
    match get16(data, 0) {
      0U => {
        if length != 12U || got_export {
          raise Protocol("invalid export info")
        }
        size = get64(data, 2)
        flags = get16(data, 10)
        if (flags & 1U) == 0U {
          raise Protocol("server did not set HAS_FLAGS")
        }
        got_export = true
      }
      3U => {
        if length != 14U || got_block {
          raise Protocol("invalid block sizes")
        }
        let min = get32(data, 2)
        let preferred = get32(data, 6)
        let max = get32(data, 10)
        if min == 0U ||
          (min & (min - 1U)) != 0U ||
          preferred < min ||
          preferred < 512U ||
          (preferred & (preferred - 1U)) != 0U ||
          max < preferred ||
          min > 65536U {
          raise Protocol("invalid server block constraints")
        }
        minimum = min
        let capped = if max < 16777216U { max } else { 16777216U }
        maximum = capped - capped % min
        got_block = true
      }
      _ => ()
    }
  }
  raise Protocol("too many option replies")
}
