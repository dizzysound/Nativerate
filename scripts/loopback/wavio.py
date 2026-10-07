"""Minimal WAV read/write for integer PCM (16/24/32) and float32, stdlib only."""
import struct
from array import array

def _chunks(data):
    pos = 12
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        yield cid, pos + 8, size
        pos += 8 + size + (size & 1)

def _fmt(chunk):
    tag, ch, rate = struct.unpack("<HHI", chunk[:8])
    bits = struct.unpack("<H", chunk[14:16])[0]
    if tag == 0xFFFE:  # WAVE_FORMAT_EXTENSIBLE: real format in SubFormat GUID
        tag = struct.unpack("<H", chunk[24:26])[0]
    return tag, ch, rate, bits

def header(path):
    """Return (rate, channels, bits) from the fmt chunk without loading samples."""
    with open(path, "rb") as f:
        data = f.read(65536)
    for cid, start, size in _chunks(data):
        if cid == b"fmt ":
            _, ch, rate, bits = _fmt(data[start:start + size])
            return rate, ch, bits
    raise ValueError(f"{path}: missing fmt chunk")

def read(path, channels=None):
    """Return (rate, channels, bits, frames): frames is a list of int tuples.
    channels: optional 0-based channel indexes to keep. Only those are decoded, so a
    14-channel 192 kHz recording does not need 14 channels of memory.
    The returned channel count is the file's real count. Float32 is converted to 24-bit."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a WAV file")
    fmt = body = None
    for cid, start, size in _chunks(data):
        if cid == b"fmt ":
            fmt = data[start:start + size]
        elif cid == b"data":
            # Size 0 = header never finalized (recorder killed or file not closed): use the rest.
            body = data[start:start + size] if size else data[start:]
    if fmt is None or body is None:
        raise ValueError(f"{path}: missing fmt or data chunk")
    tag, ch, rate, bits = _fmt(fmt)
    width = bits // 8
    n = len(body) // (width * ch)
    keep = list(range(ch)) if channels is None else list(channels)
    if any(c < 0 or c >= ch for c in keep):
        raise ValueError(f"{path}: has {ch} channels, asked for {[c + 1 for c in keep]}")
    body = body[:n * ch * width]
    cols = []
    if tag == 3 and bits == 32:
        allv = array("f"); allv.frombytes(body)
        cols = [[round(v * 8388608) for v in allv[c::ch]] for c in keep]
        bits = 24
    elif tag == 1 and width == 3:
        for c in keep:
            s = 3 * ch
            b0, b1, b2 = body[3 * c::s], body[3 * c + 1::s], body[3 * c + 2::s]
            cols.append([(v := a | b << 8 | d << 16) - ((v & 0x800000) << 1)
                         for a, b, d in zip(b0, b1, b2)])
    elif tag == 1 and width in (2, 4):
        allv = array("h" if width == 2 else "i"); allv.frombytes(body)
        cols = [list(allv[c::ch]) for c in keep]
    else:
        raise ValueError(f"{path}: unsupported format tag {tag}, {bits} bit")
    return rate, ch, bits, list(zip(*cols))

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
