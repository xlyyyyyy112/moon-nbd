///|
fn parse_allocation_query(
  data : Bytes,
  disk : ExportBackend,
) -> Result[Bool, UInt32] {
  if data.length() < 8 {
    return Err(0x80000003U)
  }
  let name_len = get32(data, 0)
  if name_len > (data.length() - 8).reinterpret_as_uint() {
    return Err(0x80000003U)
  }
  let after_name = 4 + name_len.reinterpret_as_int()
  if !disk.matches_name(data[4:after_name].to_owned()) {
    return Err(0x80000006U)
  }
  let count = get32(data, after_name)
  if count > 1024U {
    return Err(0x80000009U)
  }
  let mut at = after_name + 4
  let mut found = false
  for _ in 0..<count.reinterpret_as_int() {
    if at > data.length() - 4 {
      return Err(0x80000003U)
    }
    let len = get32(data, at)
    at += 4
    if len > 4096U || len > (data.length() - at).reinterpret_as_uint() {
      return Err(0x80000003U)
    }
    let end = at + len.reinterpret_as_int()
    if data[at:end].to_owned() == b"base:allocation" {
      found = true
    }
    at = end
  }
  if at != data.length() {
    return Err(0x80000003U)
  }
  Ok(found)
}

///|
async fn send_structured(
  tcp : @socket.Tcp,
  cookie : UInt64,
  kind : UInt32,
  data : Bytes,
) -> Unit {
  let reply : Array[Byte] = []
  put32(reply, 0x668e33efU)
  put16(reply, 1U)
  put16(reply, kind)
  put64(reply, cookie)
  put32(reply, data.length().reinterpret_as_uint())
  for b in data {
    reply.push(b)
  }
  tcp.write(Bytes::from_array(reply))
}
