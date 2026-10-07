"""Minimal WAV read/write for integer PCM (16/24/32) and float32, stdlib only."""
import struct

def read(path):
    """Return (rate, channels, bits, frames) where frames is a list of int tuples.
    Float32 files are converted to 24-bit integers."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a WAV file")
    pos, fmt, body = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        chunk = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = chunk
        elif cid == b"data":
            body = chunk
        pos += 8 + size + (size & 1)
    if fmt is None or body is None:
        raise ValueError(f"{path}: missing fmt or data chunk")
    tag, ch, rate = struct.unpack("<HHI", fmt[:8])
    bits = struct.unpack("<H", fmt[14:16])[0]
    if tag == 0xFFFE:  # WAVE_FORMAT_EXTENSIBLE: real format in SubFormat GUID
        tag = struct.unpack("<H", fmt[24:26])[0]
    width = bits // 8
    n = len(body) // (width * ch)
    if tag == 3 and bits == 32:
        vals = struct.unpack(f"<{n * ch}f", body[:n * ch * 4])
        ints = [round(v * 8388608) for v in vals]
        bits = 24
    elif tag == 1 and width in (2, 3, 4):
        if width == 3:
            ints = [int.from_bytes(body[i:i + 3], "little", signed=True)
                    for i in range(0, n * ch * 3, 3)]
        else:
            ints = list(struct.unpack(f"<{n * ch}{'h' if width == 2 else 'i'}", body[:n * ch * width]))
    else:
        raise ValueError(f"{path}: unsupported format tag {tag}, {bits} bit")
    frames = [tuple(ints[i:i + ch]) for i in range(0, len(ints), ch)]
    return rate, ch, bits, frames

def write(path, rate, bits, frames):
    ch, width = len(frames[0]), bits // 8
    if width == 2:
        body = struct.pack(f"<{len(frames) * ch}h", *(s for fr in frames for s in fr))
    else:
        body = b"".join(s.to_bytes(3, "little", signed=True) for fr in frames for s in fr)
    fmt = struct.pack("<HHIIHH", 1, ch, rate, rate * ch * width, ch * width, bits)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(body)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt)
        f.write(b"data" + struct.pack("<I", len(body)) + body)
