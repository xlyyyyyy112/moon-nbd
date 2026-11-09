///|
/// An in-memory export. Its data is volatile and is lost when the process exits.
pub struct MemoryExport {
  priv data : Array[Byte]
  priv read_only : Bool
  priv name : Bytes
  priv mut busy : Bool
}

///|
pub fn MemoryExport::new(
  size : Int32,
  read_only~ : Bool = false,
  name~ : Bytes = b"",
) -> MemoryExport raise {
  if size < 0 || size > 67108864 || name.length() > 4096 {
    raise InvalidArgument("memory export size must be between 0 and 64 MiB")
  }
  { data: Array::make(size, b'\x00'), read_only, name, busy: false, }
}

///|
pub fn MemoryExport::size(self : MemoryExport) -> UInt64 {
  self.data.length().to_uint64()
}

///|
pub fn MemoryExport::snapshot(self : MemoryExport) -> Bytes {
  Bytes::from_array(self.data)
}

///|
fn MemoryExport::flags(self : MemoryExport) -> UInt32 {
  if self.read_only {
    1027U
  } else {
    1121U
  }
}

///|
async fn option_reply(
  tcp : @socket.Tcp,
  option : UInt32,
  kind : UInt32,
  data : Bytes,
) -> Unit {
  let out : Array[Byte] = []
  put64(out, 0x0003e889045565a9UL)
  put32(out, option)
  put32(out, kind)
  put32(out, data.length().reinterpret_as_uint())
  for b in data {
    out.push(b)
  }
  tcp.write(Bytes::from_array(out))
}

///|
async fn export_info(
  tcp : @socket.Tcp,
  option : UInt32,
  disk : ExportBackend,
) -> Unit {
  let info : Array[Byte] = []
  put16(info, 0U)
  put64(info, disk.size())
  put16(info, disk.flags())
  option_reply(tcp, option, 3U, Bytes::from_array(info))
  option_reply(tcp, option, 1U, b"")
}

///|
fn validate_export_option(data : Bytes, disk : ExportBackend) -> UInt32? {
  if data.length() < 6 {
    return Some(0x80000003U)
  }
  let name_len = get32(data, 0)
  if name_len > 4096U || name_len > (data.length() - 6).reinterpret_as_uint() {
    return Some(0x80000003U)
  }
  let after_name = 4 + name_len.reinterpret_as_int()
  let count = get16(data, after_name).reinterpret_as_int()
  if data.length() != after_name + 2 + count * 2 {
    return Some(0x80000003U)
  }
  if !disk.matches_name(data[4:after_name].to_owned()) {
    return Some(0x80000006U)
  }
  None
}

///|
/// Serves one connected socket until the client disconnects or an error occurs.
/// The caller retains ownership of the socket and should close it afterwards.
pub async fn MemoryExport::serve_connection(
  self : MemoryExport,
  tcp : @socket.Tcp,
) -> Unit {
  if self.busy {
    raise InvalidArgument("export already serving a connection")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  ExportBackend::serve_export(Memory(self), tcp)
}

///|
async fn ExportBackend::serve_export(
  self : ExportBackend,
  tcp : @socket.Tcp,
) -> Unit {
  let greeting : Array[Byte] = []
  put64(greeting, 0x4e42444d41474943UL)
  put64(greeting, 0x49484156454f5054UL)
  put16(greeting, 3U)
  tcp.write(Bytes::from_array(greeting))
  let client_flags = get32(tcp.read_exactly(4), 0)
  if (client_flags & 1U) == 0U || (client_flags & 0xfffffffcU) != 0U {
    raise Protocol("unsupported client handshake flags")
  }
  let mut structured = false
  let mut allocation = false
  let mut allocation_name : Bytes? = None
  // Limit negotiation payloads so an untrusted peer cannot allocate arbitrarily.
  while true {
    let header = tcp.read_exactly(16)
    if get64(header, 0) != 0x49484156454f5054UL {
      raise Protocol("invalid option magic")
    }
    let option = get32(header, 8)
    let length = get32(header, 12)
    if length > 65536U {
      raise Protocol("option payload too large")
    }
    let body = tcp.read_exactly(length.reinterpret_as_int())
    match option {
      1U => {
        if !self.matches_name(body) {
          raise Protocol("unknown export")
        }
        allocation = allocation && allocation_name == Some(body)
        let info : Array[Byte] = []
        put64(info, self.size())
        put16(info, self.flags())
        if (client_flags & 2U) == 0U {
          for _ in 0..<124 {
            info.push(b'\x00')
          }
        }
        tcp.write(Bytes::from_array(info))
        break
      }
      2U => {
        if body.length() != 0 {
          option_reply(tcp, option, 0x80000003U, b"")
          continue
        }
        option_reply(tcp, option, 1U, b"")
        return
      }
      3U =>
        if body.length() != 0 {
          option_reply(tcp, option, 0x80000003U, b"")
        } else {
          let entry : Array[Byte] = []
          let name = self.name()
          put32(entry, name.length().reinterpret_as_uint())
          for b in name {
            entry.push(b)
          }
          option_reply(tcp, option, 2U, Bytes::from_array(entry))
          option_reply(tcp, option, 1U, b"")
        }
      6U | 7U =>
        match validate_export_option(body, self) {
          Some(code) => option_reply(tcp, option, code, b"")
          None => {
            export_info(tcp, option, self)
            if option == 7U {
              let name_len = get32(body, 0).reinterpret_as_int()
              allocation = allocation &&
                allocation_name == Some(body[4:4 + name_len].to_owned())
              break
            }
          }
        }
      8U =>
        if body.length() != 0 {
          option_reply(tcp, option, 0x80000003U, b"")
        } else {
          structured = true
          option_reply(tcp, option, 1U, b"")
        }
      10U => {
        allocation = false
        allocation_name = None
        if !structured {
          option_reply(tcp, option, 0x80000003U, b"")
        } else {
          match parse_allocation_query(body, self) {
            Err(code) => option_reply(tcp, option, code, b"")
            Ok(selected_context) => {
              if selected_context {
                let selected : Array[Byte] = []
                put32(selected, 1U)
                for b in b"base:allocation" {
                  selected.push(b)
                }
                option_reply(tcp, option, 4U, Bytes::from_array(selected))
                allocation = true
                let name_len = get32(body, 0).reinterpret_as_int()
                allocation_name = Some(body[4:4 + name_len].to_owned())
              }
              option_reply(tcp, option, 1U, b"")
            }
          }
        }
      }
      _ => option_reply(tcp, option, 0x80000001U, b"")
    }
  }
  self.transmit(tcp, structured, allocation)
}

///|
async fn ExportBackend::transmit(
  self : ExportBackend,
  tcp : @socket.Tcp,
  structured : Bool,
  allocation : Bool,
) -> Unit {
  while true {
    let req = tcp.read_exactly(28)
    if get32(req, 0) != 0x25609513U {
      raise Protocol("invalid request magic")
    }
    let flags = get16(req, 4)
    let command = get16(req, 6)
    let cookie = get64(req, 8)
    let offset = get64(req, 16)
    let length = get32(req, 24)
    if command == 2U {
      return
    }
    // Consume a bounded write payload even when the request will be rejected.
    if length > 33554432U {
      raise Protocol("request payload too large")
    }
    let write_data = if command == 1U {
      tcp.read_exactly(length.reinterpret_as_int())
    } else {
      b""
    }
    let invalid_range = offset > self.size() ||
      length.to_uint64() > self.size() - offset
    let valid_flags = flags == 0U ||
      (command == 6U && flags == 2U) ||
      (command == 7U && flags == 8U)
    let modifies = command == 1U || command == 4U || command == 6U
    let supported = command == 0U ||
      command == 1U ||
      (command == 3U && (self.flags() & 4U) != 0U) ||
      (command == 4U && (self.flags() & 32U) != 0U) ||
      (command == 5U && (self.flags() & 1024U) != 0U) ||
      (command == 6U && (self.flags() & 64U) != 0U) ||
      (command == 7U && structured && allocation)
    let error = if !valid_flags ||
      invalid_range ||
      (command != 3U && length == 0U) ||
      (command == 3U && (length != 0U || offset != 0UL)) {
      22U
    } else if modifies && (self.flags() & 2U) != 0U {
      1U
    } else if !supported {
      22U
    } else {
      0U
    }
    if command == 7U && error == 0U {
      let status : Array[Byte] = []
      put32(status, 1U)
      put32(status, length)
      put32(status, 0U)
      send_structured(tcp, cookie, 5U, Bytes::from_array(status))
      continue
    }
    let result = if error != 0U {
      Err(error)
    } else {
      execute_request(
        self,
        command,
        offset,
        length.reinterpret_as_int(),
        write_data,
      )
    }
    if structured && (command == 0U || command == 7U) {
      match result {
        Ok(data) => {
          let payload : Array[Byte] = []
          put64(payload, offset)
          for b in data {
            payload.push(b)
          }
          send_structured(tcp, cookie, 1U, Bytes::from_array(payload))
        }
        Err(code) => {
          let payload : Array[Byte] = []
          put32(payload, code)
          put16(payload, 0U)
          send_structured(tcp, cookie, 0x8001U, Bytes::from_array(payload))
        }
      }
      continue
    }
    let reply : Array[Byte] = []
    put32(reply, 0x67446698U)
    put32(
      reply,
      match result {
        Ok(_) => 0U
        Err(code) => code
      },
    )
    put64(reply, cookie)
    match result {
      Ok(data) =>
        for b in data {
          reply.push(b)
        }
      Err(_) => ()
    }
    tcp.write(Bytes::from_array(reply))
  }
}
