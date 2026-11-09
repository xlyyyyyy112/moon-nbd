///|
async fn main {
  let disk = @nbd.MemoryExport::new(1048576)
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:11090"))
  defer server.close()
  println("serving temporary memory export on 127.0.0.1:11090")
  let (tcp, _) = server.accept()
  defer tcp.close()
  disk.serve_connection(tcp)
}
