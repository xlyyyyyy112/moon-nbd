///|
/// A portable CRC32 manifest for a stable NBD export.
///
/// CRC32 detects accidental corruption; it is not a cryptographic signature
/// and must not be used to authenticate an untrusted image.
pub(all) struct IntegrityManifest {
  export_size : UInt64
  chunk_size : UInt32
  checksums : Array[UInt32]
}

///|
/// One chunk whose observed checksum differs from a manifest.
pub(all) struct ChunkMismatch {
  offset : UInt64
  length : UInt32
  expected : UInt32
  actual : UInt32
}

///|
fn crc32(data : Bytes) -> UInt32 {
  let mut state = 0xffffffffU
  for byte in data {
    state = state ^ byte.to_uint()
    for _ in 0..<8 {
      state = if (state & 1U) != 0U {
        (state >> 1) ^ 0xedb88320U
      } else {
        state >> 1
      }
    }
  }
  state ^ 0xffffffffU
}

///|
fn checked_chunk_count(size : UInt64, chunk_size : UInt32) -> UInt64 {
  let chunk = chunk_size.to_uint64()
  let full = size / chunk
  if size % chunk == 0UL {
    full
  } else {
    full + 1UL
  }
}

///|
fn valid_manifest_shape(manifest : IntegrityManifest) -> Bool {
  manifest.chunk_size != 0U &&
  checked_chunk_count(manifest.export_size, manifest.chunk_size) ==
  manifest.checksums.length().to_uint64()
}

///|
/// Build an integrity manifest by reading every byte of a stable export.
///
/// The requested chunk size must fit in a single negotiated NBD read. The last
/// manifest chunk may be smaller than `chunk_size`.
pub async fn Client::create_integrity_manifest(
  self : Client,
  chunk_size : Int32,
  max_chunks~ : Int32 = 65536,
) -> IntegrityManifest {
  if chunk_size <= 0 ||
    chunk_size.reinterpret_as_uint() > self.max_block ||
    chunk_size.reinterpret_as_uint() % self.min_block != 0U ||
    max_chunks <= 0 ||
    max_chunks > 1048576 {
    raise InvalidArgument("invalid manifest chunk size or limit")
  }
  let count = checked_chunk_count(self.size, chunk_size.reinterpret_as_uint())
  if count > max_chunks.to_uint64() {
    raise LimitExceeded("integrity manifest chunk limit exceeded")
  }
  let checksums : Array[UInt32] = []
  let mut offset = 0UL
  while offset < self.size {
    let remaining = self.size - offset
    let length = if remaining < chunk_size.to_uint64() {
      remaining.to_int()
    } else {
      chunk_size
    }
    checksums.push(crc32(self.read_at(offset, length)))
    offset += length.to_uint64()
  }
  {
    export_size: self.size,
    chunk_size: chunk_size.reinterpret_as_uint(),
    checksums,
  }
}

///|
/// Re-read an export and return every chunk that differs from `manifest`.
///
/// The manifest does not include an identity or generation counter, so callers
/// must ensure it is checked against the intended stable export.
pub async fn Client::verify_integrity_manifest(
  self : Client,
  manifest : IntegrityManifest,
  max_mismatches~ : Int32 = 1024,
) -> Array[ChunkMismatch] {
  if !valid_manifest_shape(manifest) ||
    manifest.chunk_size > self.max_block ||
    manifest.chunk_size % self.min_block != 0U ||
    manifest.export_size != self.size ||
    max_mismatches <= 0 ||
    max_mismatches > 1048576 {
    raise InvalidArgument("manifest is incompatible with this export")
  }
  let mismatches : Array[ChunkMismatch] = []
  let mut offset = 0UL
  for expected in manifest.checksums {
    let remaining = self.size - offset
    let length = if remaining < manifest.chunk_size.to_uint64() {
      remaining.to_uint()
    } else {
      manifest.chunk_size
    }
    let actual = crc32(self.read_at(offset, length.reinterpret_as_int()))
    if actual != expected {
      if mismatches.length() >= max_mismatches {
        raise LimitExceeded("integrity mismatch limit exceeded")
      }
      mismatches.push({ offset, length, expected, actual, })
    }
    offset += length.to_uint64()
  }
  mismatches
}

///|
const MANIFEST_MAGIC : Bytes = b"MNBDCRC1"

///|
/// Encode a manifest in a small deterministic binary format.
///
/// Layout: eight-byte magic, u32 version, u64 size, u32 chunk size, u32 count,
/// then `count` big-endian u32 CRC32 values.
pub fn IntegrityManifest::encode(self : IntegrityManifest) -> Bytes raise {
  if !valid_manifest_shape(self) || self.checksums.length() > 1048576 {
    raise InvalidArgument("invalid integrity manifest")
  }
  let output : Array[Byte] = []
  for byte in MANIFEST_MAGIC {
    output.push(byte)
  }
  put32(output, 1U)
  put64(output, self.export_size)
  put32(output, self.chunk_size)
  put32(output, self.checksums.length().reinterpret_as_uint())
  for checksum in self.checksums {
    put32(output, checksum)
  }
  Bytes::from_array(output)
}

///|
/// Decode and validate an integrity manifest produced by `encode`.
pub fn IntegrityManifest::decode(data : Bytes) -> IntegrityManifest raise {
  if data.length() < 28 || data[0:8].to_owned() != MANIFEST_MAGIC {
    raise InvalidArgument("invalid integrity manifest header")
  }
  if get32(data, 8) != 1U {
    raise InvalidArgument("unsupported integrity manifest version")
  }
  let size = get64(data, 12)
  let chunk_size = get32(data, 20)
  let count = get32(data, 24)
  if count > 1048576U || data.length() != 28 + count.reinterpret_as_int() * 4 {
    raise InvalidArgument("invalid integrity manifest length")
  }
  let checksums : Array[UInt32] = []
  for i in 0..<count.reinterpret_as_int() {
    checksums.push(get32(data, 28 + i * 4))
  }
  let manifest = { export_size: size, chunk_size, checksums, }
  if !valid_manifest_shape(manifest) {
    raise InvalidArgument("invalid integrity manifest shape")
  }
  manifest
}
