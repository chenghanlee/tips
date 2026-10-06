"""Classify one image file and print one JSON line. Disposable probe for issue #244.

Usage: python -I classify.py <path>

The caller runs this in its own OS process under `timeout` and `prlimit`; those
enforce the time and memory ceilings. This script enforces the byte, dimension,
frame and pixel ceilings before decoding, then decodes every frame so truncated or
corrupt data fails instead of passing on a valid header.

Pillow's decoders do not check PNG chunk CRCs, require IEND, compare the APNG frame
count with the frames present, or require the GIF trailer. check_structure does
these four checks on the bytes before Pillow decodes them.
"""

import json
import os
import resource
import sys
import zlib

from PIL import Image, ImageFile, UnidentifiedImageError

MAX_BYTES = 10_000_000
MAX_SIDE = 8192
MAX_FRAME_PIXELS = 40_000_000
MAX_FRAMES = 300
MAX_TOTAL_PIXELS = 100_000_000

# Pillow plugin name -> stored format. Pillow tries no other plugin.
FORMATS = {"PNG": "png", "JPEG": "jpeg", "WEBP": "webp", "GIF": "gif"}

ImageFile.LOAD_TRUNCATED_IMAGES = False
# The bounds below replace Pillow's decompression-bomb warning threshold.
Image.MAX_IMAGE_PIXELS = None


class Reject(Exception):
    pass


def check_structure(data, image_format):
    if image_format == "PNG":
        check_png_chunks(data)
    elif image_format == "GIF" and not data.endswith(b"\x3b"):
        raise Reject("malformed")


# Walk every chunk after the signature: each must fit the file and match its CRC,
# and IEND must be present. An APNG must hold exactly the fcTL count its acTL
# declares; Pillow trusts acTL, so a lower count would hide frames.
def check_png_chunks(data):
    pos, declared, controls, seen_idat = 8, None, 0, False
    while True:
        if pos + 12 > len(data):
            raise Reject("malformed")
        length = int.from_bytes(data[pos : pos + 4], "big")
        end = pos + 12 + length
        if end > len(data):
            raise Reject("malformed")
        body = data[pos + 4 : end - 4]
        if zlib.crc32(body) != int.from_bytes(data[end - 4 : end], "big"):
            raise Reject("malformed")
        kind = body[:4]
        if kind == b"IDAT":
            seen_idat = True
        elif kind == b"acTL" and not seen_idat:
            declared = int.from_bytes(body[4:8], "big")
        elif kind == b"fcTL":
            controls += 1
        elif kind == b"IEND":
            break
        pos = end
    if declared is not None and controls != declared:
        raise Reject("malformed")


def classify(path):
    if os.stat(path).st_size > MAX_BYTES:
        raise Reject("bytes_over_limit")

    try:
        im = Image.open(path, formats=list(FORMATS))
    except UnidentifiedImageError:
        raise Reject("unclassifiable") from None

    with im:
        with open(path, "rb") as file:
            check_structure(file.read(), im.format)

        width, height = im.size
        if width > MAX_SIDE or height > MAX_SIDE:
            raise Reject("dimensions_over_limit")
        if width * height > MAX_FRAME_PIXELS:
            raise Reject("frame_pixels_over_limit")

        # Declared count: APNG acTL, WebP ANMF chunks, GIF image descriptors.
        declared = getattr(im, "n_frames", 1)
        if declared > MAX_FRAMES:
            raise Reject("frames_over_limit")
        if width * height * declared > MAX_TOTAL_PIXELS:
            raise Reject("total_pixels_over_limit")

        # Decode every declared frame. A missing frame raises EOFError. Pillow grows
        # the canvas on seek when a GIF frame extends past it, and allocates on load.
        for index in range(declared):
            im.seek(index)
            if im.size != (width, height):
                raise Reject("malformed")
            im.load()

        return {
            "verdict": "accept",
            "format": FORMATS[im.format],
            "animated": declared > 1,
            "width": width,
            "height": height,
            "frames": declared,
        }


def main(path):
    try:
        result = classify(path)
    except Reject as reject:
        result = {"verdict": "reject", "reason": str(reject)}
    except MemoryError:
        result = {"verdict": "reject", "reason": "memory_limit"}
    except (OSError, EOFError, SyntaxError, ValueError) as error:
        result = {
            "verdict": "reject",
            "reason": "malformed",
            "detail": type(error).__name__,
        }

    # ru_maxrss is KiB on Linux.
    result["peak_rss_kib"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    print(json.dumps(result))


if __name__ == "__main__":
    main(sys.argv[1])
