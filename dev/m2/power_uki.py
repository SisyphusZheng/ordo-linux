"""Replace the initrd in the pinned unsigned Ordo EFI image, preserving section RVAs."""
from array import array
import struct
import subprocess
import sys


def update_uki(source, overlay):
    image = bytearray(source.read_bytes())
    pe, = struct.unpack_from("<I", image, 60)
    if image[pe:pe+4] != b"PE\0\0" or struct.unpack_from("<H", image, pe+24)[0] != 0x20b:
        raise ValueError("Expected PE32+")
    optional = pe + 24
    if any(image[optional+144:optional+152]):
        raise ValueError("Expected unsigned EFI")
    start = optional + struct.unpack_from("<H", image, pe+20)[0]
    count, = struct.unpack_from("<H", image, pe+6)
    sections = [start + i*40 for i in range(count)]
    section, = [s for s in sections if image[s:s+8].rstrip(b"\0") == b".initrd"]
    size, _, capacity, offset = struct.unpack_from("<IIII", image, section+8)
    raw = subprocess.check_output(["zstd", "-dc"], input=image[offset:offset+size])
    data = subprocess.check_output(["zstd", "-q", "-19", "-c"], input=raw + overlay)
    if len(data) > capacity:
        raise ValueError("Rebuilt initrd exceeds allocated EFI section")
    image[offset:offset+capacity] = data.ljust(capacity, b"\0")
    struct.pack_into("<I", image, section+8, len(data))
    struct.pack_into("<I", image, optional+64, 0)
    words = array("H", image)
    if sys.byteorder != "little":
        words.byteswap()
    checksum = sum(words)
    while checksum >> 16:
        checksum = (checksum & 65535) + (checksum >> 16)
    struct.pack_into("<I", image, optional+64, checksum + len(image))
    return image
