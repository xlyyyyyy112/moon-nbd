///|
async test "byte reads round unaligned ranges to bounded server blocks" {
  let source : Array[Byte] = Array::make(65536, b'\x00')
  for i in 0..<source.length() {
    source[i] = (i % 251).to_byte()
  }
  let full = Bytes::from_array(source)
  negotiation_peer(
    tcp => {
      send_test_export(tcp)
      let block : Array[Byte] = []
      put16(block, 3U)
      put32(block, 512U)
      put32(block, 4096U)
      put32(block, 32768U)
      option_reply(tcp, 7U, 3U, Bytes::from_array(block))
      option_reply(tcp, 7U, 1U, b"")
      while true {
        let request = tcp.read_exactly(28)
        let command = get16(request, 6)
        if command == 2U {
          break
        }
        assert_eq(command, 0U)
        let offset = get64(request, 16)
        let length = get32(request, 24)
        assert_eq(offset % 512UL, 0UL)
        assert_eq(length % 512U, 0U)
        let reply : Array[Byte] = []
        put32(reply, 0x67446698U)
        put32(reply, 0U)
        put64(reply, get64(request, 8))
        let start = offset.to_int()
        let end = start + length.reinterpret_as_int()
        for index in start..<end {
          reply.push(source[index])
        }
        tcp.write(Bytes::from_array(reply))
      }
    },
    port => {
      let client = Client::connect("127.0.0.1", port, b"")
      defer client.close()
      assert_eq(client.min_block, 512U)
      assert_eq(client.read_bytes(513UL, 13), full[513:526].to_owned())
      assert_eq(client.read_bytes(1UL, 32768), full[1:32769].to_owned())
      client.disconnect()
    },
  )
}
