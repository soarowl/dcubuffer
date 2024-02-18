# dcubuffer

Based on [Kripth/xbuffer](https://github.com/Kripth/xbuffer.git), modified to
specifically support DCU(Delphi Compiled Unit) read and write. Mainly becuase
Delphi have different VarInt encoder/decoder, which no documented yet.

## Delphi VarInt Format

### Endian

Little Endian

### Bit Direction

76543210

### Unsigned

- 7 bits: 0-127

  76543210
  vvvvvvv0

- 14 bits: 128-16383

  76543210 76543210
  vvvvvv01 vvvvvvvv

- 21 bits: 16384-2097151

  76543210 76543210 76543210
  vvvvv011 vvvvvvvv vvvvvvvv

- 28 bits: 2097152-268435455

  76543210 76543210 76543210 76543210
  vvvv0111 vvvvvvvv vvvvvvvv vvvvvvvv

- 32 bits: 268435456-4294967295

  76543210 76543210 76543210 76543210 76543210
  01011111 vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv

- 64 bits: 4294967296-18446744073709551

  76543210 76543210 76543210 76543210 76543210 76543210 76543210 76543210 76543210
  11111111 vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv

### Signed

s donate Sign bit:

- 7 bits: -64-63

  76543210
  svvvvvv0

- 14 bits: -8192-8191

  76543210 76543210
  vvvvvv01 svvvvvvv

- 21 bits: -1048576-1048575

  76543210 76543210 76543210
  vvvvv011 vvvvvvvv svvvvvvv

- 28 bits: -134217728-134217727

  76543210 76543210 76543210 76543210
  vvvv0111 vvvvvvvv vvvvvvvv svvvvvvv

- 32 bits: -2147483648-2147483647

  76543210 76543210 76543210 76543210 76543210
  01011111 vvvvvvvv vvvvvvvv vvvvvvvv svvvvvvv

- 64 bits: -9223372036854775808-9223372036854775807

  76543210 76543210 76543210 76543210 76543210 76543210 76543210 76543210 76543210
  11111111 vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv vvvvvvvv svvvvvvv

## Usage

[document](https://github.com/Kripth/xbuffer.git)

## License

MIT

## Author

Zhuo Nengwen

## Reference

- [VarInt](https://protobuf.dev/programming-guides/encoding/#varints)
