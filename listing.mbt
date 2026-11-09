///|
/// Export names and descriptions are preserved as protocol bytes.
pub(all) struct ExportEntry {
  name : Bytes
  description : Bytes
}

///|
/// Information obtained with `NBD_OPT_INFO`, without entering transmission mode.
pub(all) struct RemoteExportInfo {
  size : UInt64
  flags : UInt32
}

///|
/// Inspect an export without acquiring a transmission-mode connection.
///
/// This is useful for status commands and preflight checks. It asks only for
/// `NBD_INFO_EXPORT`; servers may send other informational replies, which are
/// ignored after their framing is validated.
pub async fn inspect_export(
  host : String,
  port : Int32,
  name : Bytes,
  timeout_ms~ : Int32 = 30000,
) -> RemoteExportInfo {
  if port <= 0 || port > 65535 || name.length() > 4096 || timeout_ms <= 0 {
    raise InvalidArgument("invalid port, export name, or timeout")
  }
  @async.with_timeout(timeout_ms, () => {
    let tcp = @socket.Tcp::connect_to_host(host, port~)
    defer tcp.close()
    ignore(client_handshake(tcp))
    let body : Array[Byte] = []
    put32(body, name.length().reinterpret_as_uint())
    for byte in name {
      body.push(byte)
    }
    put16(body, 1U)
    put16(body, 0U)
    send_option(tcp, 6U, Bytes::from_array(body))
    let mut result : RemoteExportInfo? = None
    for _ in 0..<256 {
      let header = tcp.read_exactly(20)
      if get64(header, 0) != 0x0003e889045565a9UL || get32(header, 8) != 6U {
        raise Protocol("invalid export information reply")
      }
      let kind = get32(header, 12)
      let length = get32(header, 16)
      if length > 65536U {
        raise Protocol("export information reply exceeds limit")
      }
      let data = tcp.read_exactly(length.reinterpret_as_int())
      if (kind & 0x80000000U) != 0U {
        raise Server(kind)
      }
      if kind == 1U {
        if length != 0U || result is None {
          raise Protocol("incomplete export information reply")
        }
        send_option(tcp, 2U, b"")
        return result.unwrap()
      }
      if kind != 3U || length < 2U {
        raise Protocol("unexpected export information reply")
      }
      if get16(data, 0) == 0U {
        if length != 12U || result is Some(_) {
          raise Protocol("invalid duplicate export information")
        }
        let flags = get16(data, 10)
        if (flags & 1U) == 0U {
          raise Protocol("server did not set HAS_FLAGS")
        }
        result = Some({ size: get64(data, 2), flags, })
      }
    }
    raise Protocol("too many export information replies")
  })
}

///|
/// List exports over a separate connection without entering transmission mode.
pub async fn list_exports(
  host : String,
  port : Int32,
  timeout_ms~ : Int32 = 30000,
) -> Array[ExportEntry] {
  if port <= 0 || port > 65535 || timeout_ms <= 0 {
    raise InvalidArgument("invalid port or timeout")
  }
  @async.with_timeout(timeout_ms, () => {
    let tcp = @socket.Tcp::connect_to_host(host, port~)
    defer tcp.close()
    ignore(client_handshake(tcp))
    send_option(tcp, 3U, b"")
    let exports : Array[ExportEntry] = []
    let mut total = 0U
    for _ in 0..<1025 {
      let hdr = tcp.read_exactly(20)
      if get64(hdr, 0) != 0x0003e889045565a9UL || get32(hdr, 8) != 3U {
        raise Protocol("invalid export list reply")
      }
      let kind = get32(hdr, 12)
      let len = get32(hdr, 16)
      if len > 65536U || total > 1048576U - len {
        raise Protocol("export list exceeds limit")
      }
      total += len
      let data = tcp.read_exactly(len.reinterpret_as_int())
      if (kind & 0x80000000U) != 0U {
        raise Server(kind)
      }
      if kind == 1U {
        if len != 0U {
          raise Protocol("invalid export list acknowledgement")
        }
        send_option(tcp, 2U, b"")
        return exports
      }
      if kind != 2U || len < 4U || exports.length() >= 1024 {
        raise Protocol("invalid export list entry")
      }
      let name_len = get32(data, 0)
      if name_len > 4096U || name_len > len - 4U {
        raise Protocol("invalid export name length")
      }
      let end = 4 + name_len.reinterpret_as_int()
      exports.push({
        name: data[4:end].to_owned(),
        description: data[end:].to_owned(),
      })
    }
    raise Protocol("too many export entries")
  })
}
