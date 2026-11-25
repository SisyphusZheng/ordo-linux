"""Produce the branded stage 2 from a supported M2 boot bundle."""
import argparse
import hashlib
from pathlib import Path

from boot_art import m1n1_logo

# In this verified distribution bundle the m1n1 executable is followed by
# concatenated device trees and compressed U-Boot. m1n1 reads its custom
# logo only when it is the first payload, immediately before those trees.
SOURCE_SHA = "f4ce681bdb07cc897eb997a37858712b1ffc48ae1b4770e4d05b982ecffb1f23"
PAYLOAD_OFFSET = 0x3A0000


def brand_stage1(original):
    # The signed boot policy is set separately in the paired recoveryOS.
    digest = "7563dfc822aeda8ddc62225de93ac379b2e3d0fd1ebcca11a06923015ec9f3be"
    if hashlib.sha256(original).hexdigest() != digest:
        raise ValueError("Unexpected stage 1 or chainload target for this Mac")
    offset = original.index(b"STACKBOTchosen.asahi,efi-system-partition=") + len(b"STACKBOT")
    return original[:offset] + m1n1_logo() + original[offset:]


def brand(original):
    if hashlib.sha256(original).hexdigest() != SOURCE_SHA:
        raise ValueError("Unknown m1n1 bundle, expected the original M2 stage 2")
    if original[PAYLOAD_OFFSET:PAYLOAD_OFFSET+4] != bytes.fromhex("d00dfeed"):
        raise ValueError("Expected the first flattened device tree")
    return original[:PAYLOAD_OFFSET] + m1n1_logo() + original[PAYLOAD_OFFSET:]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--stage1", action="store_true")
    args = parser.parse_args()
    branded = (brand_stage1 if args.stage1 else brand)(args.original.read_bytes())
    with args.output.open("xb") as output:
        output.write(branded)
