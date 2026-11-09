///|
fn usage() -> Unit {
  println(
    "MoonNBD: list HOST PORT | info HOST PORT [NAME] | read HOST PORT OFFSET LENGTH OUTPUT [NAME] | export HOST PORT OUTPUT [NAME] | export-sparse HOST PORT OUTPUT [NAME] | serve FILE PORT [--write] [--name NAME]",
  )
  println("serve listens only on 127.0.0.1; --write enables changes to FILE")
}

///|
async fn run(args : Array[String]) -> Unit {
  if args.length() < 2 {
    usage()
    return
  }
  match args[1] {
    "list" if args.length() == 4 => {
      let entries = @block.list_exports(args[2], @string.parse_int(args[3][:]))
      for entry in entries {
        println("name=\{entry.name} description=\{entry.description}")
      }
    }
    "info" if args.length() == 4 || args.length() == 5 => {
      let name = if args.length() == 5 { @utf8.encode(args[4]) } else { b"" }
      let info = @block.inspect_export(
        args[2],
        @string.parse_int(args[3][:]),
        name,
      )
      println("size=\{info.size} flags=\{info.flags}")
    }
    "read" if args.length() == 7 || args.length() == 8 => {
      let port = @string.parse_int(args[3][:])
      let offset = @string.parse_uint64(args[4][:])
      let length = @string.parse_int(args[5][:])
      let name = if args.length() == 8 { @utf8.encode(args[7]) } else { b"" }
      let client = @block.Client::connect(args[2], port, name, structured=true)
      defer client.close()
      let bytes = client.read_at(offset, length)
      client.disconnect()
      @fs.write_file(args[6][:], bytes, create_mode=CreateNew)
      println("wrote \{bytes.length()} bytes")
    }
    "export" if args.length() == 5 || args.length() == 6 => {
      let name = if args.length() == 6 { @utf8.encode(args[5]) } else { b"" }
      let client = @block.Client::connect(
        args[2],
        @string.parse_int(args[3][:]),
        name,
        structured=true,
      )
      defer client.close()
      let file = @fs.open(args[4][:], mode=ReadWrite, create_mode=CreateNew)
      defer file.close()
      let count = client.copy_to_file(file)
      client.disconnect()
      println("exported \{count} bytes")
    }
    "export-sparse" if args.length() == 5 || args.length() == 6 => {
      let name = if args.length() == 6 { @utf8.encode(args[5]) } else { b"" }
      let client = @block.Client::connect(
        args[2],
        @string.parse_int(args[3][:]),
        name,
        structured=true,
        allocation=true,
      )
      defer client.close()
      let file = @fs.open(args[4][:], mode=ReadWrite, create_mode=CreateNew)
      defer file.close()
      let stats = client.copy_sparse_to_file(file)
      client.disconnect()
      println(
        "exported \{stats.logical_bytes} bytes (wrote \{stats.data_bytes}, skipped \{stats.zero_bytes} known-zero bytes)",
      )
    }
    "serve" if args.length() >= 4 => {
      let mut write = false
      let mut name = b""
      let mut i = 4
      while i < args.length() {
        if args[i] == "--write" && !write {
          write = true
          i += 1
        } else if args[i] == "--name" &&
          name.length() == 0 &&
          i + 1 < args.length() {
          name = @utf8.encode(args[i + 1])
          if name.length() == 0 {
            fail("export name must not be empty")
          }
          i += 2
        } else {
          fail("unknown or duplicate option")
        }
      }
      let port = @string.parse_int(args[3][:])
      if port <= 0 || port > 65535 {
        fail("invalid TCP port")
      }
      let disk = @block.FileExport::open(args[2], read_only=!write, name~)
      defer disk.close()
      let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:\{port}"))
      defer listener.close()
      println("serving \{disk.size()} bytes at 127.0.0.1:\{port}")
      while true {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        disk.serve_connection(tcp) catch {
          error => println("client error: \{error}")
        }
      }
    }
    _ => {
      usage()
      fail("invalid command or arguments")
    }
  }
}

///|
async fn main {
  run(@env.args())
}
