///|
pub struct FileExport {
  priv file : @fs.File
  priv export_size : UInt64
  priv read_only : Bool
  priv name : Bytes
  priv mut closed : Bool
  priv mut busy : Bool
}

///|
/// Open an existing regular file without truncation. The owner must keep it stable.
pub async fn FileExport::open(
  path : String,
  read_only~ : Bool = true,
  name~ : Bytes = b"",
) -> FileExport {
  if name.length() > 4096 {
    raise InvalidArgument("export name is too long")
  }
  let file = @fs.open(
    path[:],
    mode=if read_only { ReadOnly } else { ReadWrite },
  )
  errdefer file.close()
  if file.kind() != Regular {
    raise InvalidArgument("expected a regular file")
  }
  let size = file.size()
  if size < 0L {
    raise InvalidArgument("invalid file size")
  }
  {
    file,
    export_size: size.reinterpret_as_uint64(),
    read_only,
    name,
    closed: false,
    busy: false,
  }
}

///|
pub fn FileExport::close(self : FileExport) -> Unit {
  if !self.closed {
    self.closed = true
    self.file.close()
  }
}

///|
pub fn FileExport::size(self : FileExport) -> UInt64 {
  self.export_size
}

///|
/// Serves one connection using an existing file; caller closes both resources.
pub async fn FileExport::serve_connection(
  self : FileExport,
  tcp : @socket.Tcp,
) -> Unit {
  if self.closed || self.busy {
    raise InvalidArgument("file export is closed or busy")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  ExportBackend::serve_export(File(self), tcp)
}

///|
priv enum ExportBackend {
  Memory(MemoryExport)
  File(FileExport)
}

///|
fn ExportBackend::size(self : ExportBackend) -> UInt64 {
  match self {
    Memory(disk) => disk.size()
    File(disk) => disk.size()
  }
}

///|
fn ExportBackend::name(self : ExportBackend) -> Bytes {
  match self {
    Memory(disk) => disk.name
    File(disk) => disk.name
  }
}

///|
fn ExportBackend::matches_name(self : ExportBackend, name : Bytes) -> Bool {
  name.length() == 0 || name == self.name()
}

///|
fn ExportBackend::flags(self : ExportBackend) -> UInt32 {
  match self {
    Memory(disk) => disk.flags()
    File(disk) => if disk.read_only { 1027U } else { 1029U }
  }
}

///|
async fn execute_request(
  disk : ExportBackend,
  command : UInt32,
  offset : UInt64,
  length : Int32,
  payload : Bytes,
) -> Result[Bytes, UInt32] {
  try {
    match disk {
      Memory(memory) => {
        let start = offset.to_int()
        match command {
          0U => {
            let out : Array[Byte] = []
            for i in 0..<length {
              out.push(memory.data[start + i])
            }
            Ok(Bytes::from_array(out))
          }
          1U => {
            for i in 0..<length {
              memory.data[start + i] = payload[i]
            }
            Ok(b"")
          }
          4U | 6U => {
            for i in 0..<length {
              memory.data[start + i] = b'\x00'
            }
            Ok(b"")
          }
          5U => Ok(b"")
          _ => Err(22U)
        }
      }
      File(file) =>
        if file.closed {
          Err(5U)
        } else {
          match command {
            0U =>
              Ok(
                file.file.read_exactly_at(
                  length,
                  position=offset.reinterpret_as_int64(),
                ),
              )
            1U => {
              file.file.write_at(
                payload[:],
                position=offset.reinterpret_as_int64(),
              )
              Ok(b"")
            }
            3U => {
              file.file.sync()
              Ok(b"")
            }
            5U => Ok(b"")
            _ => Err(22U)
          }
        }
    }
  } catch {
    _ => Err(5U)
  }
}
