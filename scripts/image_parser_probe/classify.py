"""Classify one image file and print one JSON line. Disposable probe for issue #244.

Usage: python -I classify.py <path>

The caller runs this in its own OS process under `timeout` and `prlimit`; those
enforce the time and memory ceilings. This script enforces the byte, dimension,
frame and pixel ceilings before decoding, then decodes every frame so truncated or
corrupt data fails instead of passing on a valid header.
"""

import json
import os
import resource
import sys

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


def classify(path):
    if os.stat(path).st_size > MAX_BYTES:
        raise Reject("bytes_over_limit")

    try:
        im = Image.open(path, formats=list(FORMATS))
    except UnidentifiedImageError:
        raise Reject("unclassifiable") from None

    with im:
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

        # Decode every declared frame. A missing frame raises EOFError.
        for index in range(declared):
            im.seek(index)
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
