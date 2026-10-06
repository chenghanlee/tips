# Image parser probe

Result for [#244](https://github.com/chenghanlee/tips/issues/244): **Pillow 12.3.0
is selected,** with structure checks of our own. Run in its own OS process
under `timeout` and `prlimit`, it passes all 45 fixtures and all three enforcement experiments on linux/arm64 and
linux/amd64.

The application runs the probe's `classify.py` from `priv/image_parser/`; see
`Tips.Content.Media.ImageParser` and [Image/GIF upload integration](../design/backend-design.md#imagegif-upload-integration)
for the ceilings and outcomes. #62 removed the probe harness; it is at
[`c37b2a7`](https://github.com/chenghanlee/tips/tree/c37b2a7606f90ead2ceb7511aad64887f935e12f/scripts/image_parser_probe).
It ran in Docker on the release builder's Debian bookworm base with Debian's
Python 3.11.2 and the hash-pinned Pillow wheel, which bundles libwebp 1.6.0,
libjpeg-turbo 3.1.4.1 and zlib-ng. Fixtures came from Debian's FFmpeg 5.1 and
libwebp 1.2.4 tools and from a small PNG writer in the probe.

## Recorded runs

Both runs are at `261e8bf` with no tracked changes:

- arm64 `20261006T175819Z`:
  [report](image-parser-probe/arm64-20261006T175819Z-report.json),
  [fixtures](image-parser-probe/arm64-20261006T175819Z-fixtures.json).
- amd64 under Docker emulation `20261006T175902Z`:
  [report](image-parser-probe/amd64-20261006T175902Z-report.json),
  [fixtures](image-parser-probe/amd64-20261006T175902Z-fixtures.json).

Fixture bytes are stable across runs on one architecture: repeated arm64 runs gave
identical hashes for all 45 fixtures. Across architectures, the lossy encodes
differ (`static.jpg`, `spoofed-jpeg-as.png`, `truncated.jpg` and the three
lossy at-limit WebPs). Every other fixture is byte-identical. All verdicts match.

## Fixture results

`ms` is the caller's wall time and includes about 30–45 ms of Python startup.
Peak RSS is the parser process's `ru_maxrss`.

| Fixture | Bytes | Expected | Result | arm64 ms | arm64 peak RSS MiB | amd64 |
|---|---|---|---|---|---|---|
| `static.png` | 469 | accept png static | ✓ accept png static | 31 | 15 | same |
| `animated.apng` | 1,405 | accept png animated | ✓ accept png animated | 32 | 15 | same |
| `single-frame.apng` | 527 | accept png static | ✓ accept png static | 31 | 15 | same |
| `static.jpg` | 1,976 | accept jpeg static | ✓ accept jpeg static | 45 | 20 | same |
| `static.gif` | 1,650 | accept gif static | ✓ accept gif static | 44 | 19 | same |
| `animated.gif` | 3,823 | accept gif animated | ✓ accept gif animated | 48 | 19 | same |
| `static.webp` | 260 | accept webp static | ✓ accept webp static | 47 | 19 | same |
| `animated.webp` | 1,350 | accept webp animated | ✓ accept webp animated | 44 | 19 | same |
| `single-frame.webp` | 590 | accept webp static | ✓ accept webp static | 44 | 19 | same |
| `spoofed-jpeg-as.png` | 1,976 | accept jpeg static | ✓ accept jpeg static | 44 | 19 | same |
| `spoofed-text-as.gif` | 27 | reject unclassifiable | ✓ reject unclassifiable | 43 | 19 | same |
| `svg-as.png` | 64 | reject unclassifiable | ✓ reject unclassifiable | 44 | 19 | same |
| `bmp.bmp` | 9,270 | reject unclassifiable | ✓ reject unclassifiable | 47 | 19 | same |
| `tiff.tif` | 7,715 | reject unclassifiable | ✓ reject unclassifiable | 44 | 19 | same |
| `empty.png` | 0 | reject unclassifiable | ✓ reject unclassifiable | 43 | 19 | same |
| `random.bin` | 4,096 | reject unclassifiable | ✓ reject unclassifiable | 45 | 19 | same |
| `png-signature-garbage.png` | 520 | reject malformed | ✓ reject unclassifiable | 47 | 19 | same |
| `truncated.png` | 281 | reject malformed | ✓ reject malformed | 30 | 14 | same |
| `truncated.jpg` | 1,185 | reject malformed | ✓ reject malformed | 45 | 20 | same |
| `truncated.gif` | 2,293 | reject malformed | ✓ reject malformed | 44 | 19 | same |
| `truncated.webp` | 810 | reject malformed | ✓ reject malformed | 44 | 19 | same |
| `truncated.apng` | 843 | reject malformed | ✓ reject malformed | 29 | 14 | same |
| `corrupt-idat.png` | 469 | reject malformed | ✓ reject malformed | 32 | 15 | same |
| `png-crc-mismatch.png` | 469 | reject malformed | ✓ reject malformed | 31 | 14 | same |
| `png-iend-missing.png` | 457 | reject malformed | ✓ reject malformed | 30 | 14 | same |
| `gif-trailer-missing.gif` | 3,822 | reject malformed | ✓ reject malformed | 44 | 19 | same |
| `apng-actl-overcount.png` | 1,405 | reject malformed | ✓ reject malformed | 30 | 14 | same |
| `apng-actl-undercount.png` | 1,405 | reject malformed | ✓ reject malformed | 30 | 14 | same |
| `apng-actl-duplicate.png` | 1,425 | reject malformed | ✓ reject malformed | 30 | 14 | same |
| `apng-actl-after-idat.png` | 1,405 | reject malformed | ✓ reject malformed | 30 | 14 | same |
| `apng-frame-outside-canvas.png` | 1,405 | reject malformed | ✓ reject malformed | 29 | 15 | same |
| `webp-anim-flag-unset.webp` | 1,350 | reject malformed | ✓ reject malformed | 44 | 19 | same |
| `gif-frame-outside-canvas.gif` | 3,823 | reject malformed | ✓ reject malformed | 45 | 19 | same |
| `huge-dimensions.png` | 388,871 | reject dimensions_over_limit | ✓ reject dimensions_over_limit | 30 | 15 | same |
| `frame-pixels-over.png` | 62,290 | reject frame_pixels_over_limit | ✓ reject frame_pixels_over_limit | 29 | 15 | same |
| `at-frame-pixel-limit-rgba.png` | 155,586 | accept png static | ✓ accept png static | 385 | 167 | same |
| `at-frame-pixel-limit-rgba16.png` | 311,100 | accept png static | ✓ accept png static | 706 | 167 | same |
| `at-frame-pixel-limit-2-frames.gif` | 3,157,259 | accept gif animated | ✓ accept gif animated | 509 | 496 | same |
| `at-frame-pixel-limit-2-frames.webp` | 1,225,700 | accept webp animated | ✓ accept webp animated | 719 | 632 | same |
| `many-frames.gif` | 25,836 | reject frames_over_limit | ✓ reject frames_over_limit | 50 | 19 | same |
| `at-total-pixel-limit.gif` | 3,291,062 | accept gif animated | ✓ accept gif animated | 832 | 68 | same |
| `at-total-pixel-limit.webp` | 2,045,916 | accept webp animated | ✓ accept webp animated | 974 | 84 | same |
| `at-total-pixel-limit-4-frames.webp` | 1,722,242 | accept webp animated | ✓ accept webp animated | 938 | 426 | same |
| `total-pixels-over.gif` | 5,303,194 | reject total_pixels_over_limit | ✓ reject total_pixels_over_limit | 52 | 24 | same |
| `over-10mb.png` | 12,003,753 | reject bytes_over_limit | ✓ reject bytes_over_limit | 27 | 13 | same |

#61 failed these with Vix 0.41.0/libvips 8.18.3: `animated.apng` (read as static),
`truncated.gif` and `truncated.apng` (accepted). ffprobe 8.1 also failed
`animated.webp`, `truncated.jpg` and `huge-dimensions.png`. Pillow passes all of
them.

## Structure checks

Pillow alone accepts seven malformed files that decode cleanly:

- `png-crc-mismatch.png`: Pillow does not check chunk CRCs.
- `png-iend-missing.png`: Pillow does not require IEND.
- `apng-actl-undercount.png`: Pillow trusts the `acTL` frame count, so a file that
  declares 1 frame but holds 5 reads as static.
- `apng-actl-duplicate.png` and `apng-actl-after-idat.png`: Pillow falls back to
  the static default image with an "Invalid APNG" warning.
- `gif-trailer-missing.gif`: Pillow does not require the GIF trailer.
- `gif-frame-outside-canvas.gif`: Pillow grows a 64×48 canvas to 9064×9043 for a
  frame placed far outside it. Decoding that frame peaked at 723 MiB.

`classify.py` adds these checks to reject them:

1. For PNG, it walks every chunk on the raw bytes: length, CRC and a final IEND.
2. For APNG, it checks the chunk rules:
   - at most one `acTL`, before the first IDAT, declaring at least one frame;
   - `fcTL` and `fdAT` only after `acTL`, numbered 0, 1, 2 and so on;
   - exactly as many `fcTL` as `acTL` declares.
3. Pillow's "Invalid APNG" warning is raised as an error, in case a rule the walk
   misses triggers the static fallback.
4. For GIF, the file must end with the trailer byte.
5. After each `seek`, the canvas size must be unchanged. Pillow grows the canvas
   on `seek` but allocates it on `load`, so this check runs before the memory is
   used.

`corrupt-idat.png` has a valid CRC, so it tests the decoder rather than the chunk
walk: zlib rejects its damaged data (`OSError`).

Design assessment: these checks only validate structure. They never decode pixels
or decide motion; Pillow still decodes every frame, and its frame count still
decides `animated`. The PNG walk reads a file that is at most 10 MB, using lengths
it checks against the file size, under the same deadline and memory ceiling. JPEG
and WebP need no extra check: Pillow, libjpeg-turbo and libwebp reject every
malformed JPEG and WebP fixture. JPEG is not required to end with its EOI marker,
because some phones append data after it.

## Enforcement experiments

Each experiment lowers one ceiling below what a legitimate at-limit fixture needs,
so only the ceiling can stop the work.

| Experiment | Setup | arm64 | amd64 |
|---|---|---|---|
| `deadline_kills_parser` | `at-total-pixel-limit.gif` (about 850 ms) with a 0.2 s deadline | killed, exit 137 at 213 ms; no parser left | same, 217 ms |
| `address_space_stops_parser` | `at-frame-pixel-limit-2-frames.webp` (needs about 640 MiB) with a 512 MiB ceiling | rejected `memory_limit` | rejected `malformed` |
| `parser_stops_without_caller` | The caller exits right after starting the parser with a 0.5 s deadline | parser running at 100 ms, gone at 800 ms | same |

`timeout` kills the parser directly: `prlimit` execs Python, so the parser is
`timeout`'s only child. Pillow decodes in the same process, so no other process
can outlive the deadline. When an allocation fails, Python raises `MemoryError`,
or libwebp returns an error that Pillow raises as `OSError`. Both are rejections.

## Measured needs

The largest legitimate need measured was a two-frame 40 MP WebP: 632 MiB peak RSS
on arm64 and 644 MiB on amd64, finishing in 0.7 s. In a manual arm64 run outside the
recorded reports, an equivalent file failed under a 640 MiB ceiling and passed
under 768 MiB. The slowest was a 25-frame 100 MP WebP: about
1 s. Timings come from Docker on an Apple Silicon Mac, not the
VPS.
