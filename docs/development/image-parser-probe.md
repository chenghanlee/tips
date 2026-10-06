# Image parser probe

Result for [#244](https://github.com/chenghanlee/tips/issues/244): **Pillow 12.3.0
is selected,** with structure checks of our own. Run in its own OS process
under `timeout` and `prlimit`, it passes all 45 fixtures and all three enforcement experiments on linux/arm64 and
linux/amd64. [#62](https://github.com/chenghanlee/tips/issues/62) builds on the
[contract below](#contract-for-62).

The probe code in `scripts/image_parser_probe/` is disposable. #62 moves
`classify.py` into the application and deletes the rest.

## Run it

```sh
bash scripts/image_parser_probe.sh                                # host architecture
PROBE_PLATFORM=linux/amd64 bash scripts/image_parser_probe.sh    # emulated amd64
```

The script needs Docker. It records the revision and tracked-change count, builds
the probe image, writes the fixtures and their hashes to `fixtures.json`, then
classifies each fixture. Output goes to `tmp/image-parser-probe/<run-id>/`. It
exits nonzero if any fixture or experiment fails.

The probe image uses the release builder's pinned Debian bookworm base, Debian's
Python 3.11.2, and the Pillow wheel pinned by hash in
[requirements.txt](../../scripts/image_parser_probe/requirements.txt). The wheel
bundles libwebp 1.6.0, libjpeg-turbo 3.1.4.1 and zlib-ng, so it pins the native decoders.
Fixtures come from Debian's FFmpeg 5.1 and libwebp 1.2.4 tools and from a small
PNG writer in the probe.

## Recorded runs

Both runs are at `048a41e` with no tracked changes:

- arm64 `20261006T175003Z`:
  [report](image-parser-probe/arm64-20261006T175003Z-report.json),
  [fixtures](image-parser-probe/arm64-20261006T175003Z-fixtures.json).
- amd64 under Docker emulation `20261006T175047Z`:
  [report](image-parser-probe/amd64-20261006T175047Z-report.json),
  [fixtures](image-parser-probe/amd64-20261006T175047Z-fixtures.json).

Fixture bytes are stable across runs on one architecture: repeated arm64 runs gave
identical hashes for all 45 fixtures. Across architectures, the lossy encodes
differ (`static.jpg`, `spoofed-jpeg-as.png`, `truncated.jpg` and the three
lossy at-limit WebPs). Every other fixture is byte-identical. All verdicts match.

## Fixture results

`ms` is the caller's wall time and includes about 30–45 ms of Python startup.
Peak RSS is the parser process's `ru_maxrss`.

| Fixture | Bytes | Expected | Result | arm64 ms | arm64 peak RSS MiB | amd64 |
|---|---|---|---|---|---|---|
| `static.png` | 469 | accept png static | ✓ accept png static | 32 | 14 | same |
| `animated.apng` | 1,405 | accept png animated | ✓ accept png animated | 30 | 14 | same |
| `single-frame.apng` | 527 | accept png static | ✓ accept png static | 29 | 14 | same |
| `static.jpg` | 1,976 | accept jpeg static | ✓ accept jpeg static | 44 | 20 | same |
| `static.gif` | 1,650 | accept gif static | ✓ accept gif static | 45 | 19 | same |
| `animated.gif` | 3,823 | accept gif animated | ✓ accept gif animated | 44 | 19 | same |
| `static.webp` | 260 | accept webp static | ✓ accept webp static | 46 | 19 | same |
| `animated.webp` | 1,350 | accept webp animated | ✓ accept webp animated | 48 | 19 | same |
| `single-frame.webp` | 590 | accept webp static | ✓ accept webp static | 44 | 19 | same |
| `spoofed-jpeg-as.png` | 1,976 | accept jpeg static | ✓ accept jpeg static | 48 | 19 | same |
| `spoofed-text-as.gif` | 27 | reject unclassifiable | ✓ reject unclassifiable | 43 | 19 | same |
| `svg-as.png` | 64 | reject unclassifiable | ✓ reject unclassifiable | 44 | 19 | same |
| `bmp.bmp` | 9,270 | reject unclassifiable | ✓ reject unclassifiable | 44 | 19 | same |
| `tiff.tif` | 7,715 | reject unclassifiable | ✓ reject unclassifiable | 42 | 19 | same |
| `empty.png` | 0 | reject unclassifiable | ✓ reject unclassifiable | 42 | 19 | same |
| `random.bin` | 4,096 | reject unclassifiable | ✓ reject unclassifiable | 46 | 19 | same |
| `png-signature-garbage.png` | 520 | reject malformed | ✓ reject unclassifiable | 48 | 19 | same |
| `truncated.png` | 281 | reject malformed | ✓ reject malformed | 33 | 14 | same |
| `truncated.jpg` | 1,185 | reject malformed | ✓ reject malformed | 48 | 20 | same |
| `truncated.gif` | 2,293 | reject malformed | ✓ reject malformed | 47 | 19 | same |
| `truncated.webp` | 810 | reject malformed | ✓ reject malformed | 43 | 19 | same |
| `truncated.apng` | 843 | reject malformed | ✓ reject malformed | 29 | 14 | same |
| `corrupt-idat.png` | 469 | reject malformed | ✓ reject malformed | 31 | 14 | same |
| `png-crc-mismatch.png` | 469 | reject malformed | ✓ reject malformed | 29 | 14 | same |
| `png-iend-missing.png` | 457 | reject malformed | ✓ reject malformed | 29 | 14 | same |
| `gif-trailer-missing.gif` | 3,822 | reject malformed | ✓ reject malformed | 43 | 19 | same |
| `apng-actl-overcount.png` | 1,405 | reject malformed | ✓ reject malformed | 29 | 14 | same |
| `apng-actl-undercount.png` | 1,405 | reject malformed | ✓ reject malformed | 29 | 14 | same |
| `apng-frame-outside-canvas.png` | 1,405 | reject malformed | ✓ reject malformed | 29 | 14 | same |
| `webp-anim-flag-unset.webp` | 1,350 | reject malformed | ✓ reject malformed | 44 | 19 | same |
| `gif-frame-outside-canvas.gif` | 3,823 | reject malformed | ✓ reject malformed | 44 | 19 | same |
| `huge-dimensions.png` | 388,871 | reject dimensions_over_limit | ✓ reject dimensions_over_limit | 30 | 15 | same |
| `frame-pixels-over.png` | 62,290 | reject frame_pixels_over_limit | ✓ reject frame_pixels_over_limit | 30 | 14 | same |
| `at-frame-pixel-limit-rgba.png` | 155,586 | accept png static | ✓ accept png static | 385 | 167 | same |
| `at-frame-pixel-limit-rgba16.png` | 311,100 | accept png static | ✓ accept png static | 706 | 167 | same |
| `at-frame-pixel-limit-2-frames.gif` | 3,157,259 | accept gif animated | ✓ accept gif animated | 512 | 496 | same |
| `at-frame-pixel-limit-2-frames.webp` | 1,225,700 | accept webp animated | ✓ accept webp animated | 746 | 632 | same |
| `many-frames.gif` | 25,836 | reject frames_over_limit | ✓ reject frames_over_limit | 52 | 19 | same |
| `at-total-pixel-limit.gif` | 3,291,062 | accept gif animated | ✓ accept gif animated | 881 | 68 | same |
| `at-total-pixel-limit.webp` | 2,045,916 | accept webp animated | ✓ accept webp animated | 977 | 84 | same |
| `at-total-pixel-limit-4-frames.webp` | 1,722,242 | accept webp animated | ✓ accept webp animated | 933 | 426 | same |
| `total-pixels-over.gif` | 5,303,194 | reject total_pixels_over_limit | ✓ reject total_pixels_over_limit | 55 | 24 | same |
| `over-10mb.png` | 12,003,753 | reject bytes_over_limit | ✓ reject bytes_over_limit | 29 | 14 | same |

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
| `deadline_kills_parser` | `at-total-pixel-limit.gif` (about 850 ms) with a 0.2 s deadline | killed, exit 137 at 208 ms; no parser left | same, 218 ms |
| `address_space_stops_parser` | `at-frame-pixel-limit-2-frames.webp` (needs about 640 MiB) with a 512 MiB ceiling | rejected `memory_limit` | rejected `malformed` |
| `parser_stops_without_caller` | The caller exits right after starting the parser with a 0.5 s deadline | parser running at 100 ms, gone at 800 ms | same |

`timeout` kills the parser directly: `prlimit` execs Python, so the parser is
`timeout`'s only child. Pillow decodes in the same process, so no other process
can outlive the deadline. When an allocation fails, Python raises `MemoryError`,
or libwebp returns an error that Pillow raises as `OSError`. Both are rejections.

## Contract for #62

### Command

```sh
timeout --signal=KILL 5 prlimit --as=1073741824 -- <venv>/bin/python -I classify.py <path>
```

`classify.py` applies the size ceilings and the [structure checks](#structure-checks),
then decodes every frame. It prints one JSON line. An accepted file prints `verdict`, `format`
(`png`/`jpeg`/`webp`/`gif`), `animated`, `width`, `height` and `frames`. A rejected
file prints `verdict` and `reason`. Exit 137 is SIGKILL, normally from the deadline. Any
other nonzero exit, or output that is not one JSON line, is a parser failure.

### Ceilings

| Ceiling | Value | Enforced by |
|---|---|---|
| Bytes | 10,000,000 | caller before spawning, and `classify.py` |
| Width or height | 8,192 px | `classify.py`, from the header before decoding |
| Pixels per frame | 40,000,000 | same |
| Frames | 300 | same, from the declared count |
| Pixels across frames | 100,000,000 | same |
| Wall time | 5 s | `timeout --signal=KILL` |
| Address space | 1 GiB | `prlimit --as` (Linux only) |

These are #61's proposed bounds, adopted unchanged. The 40 MP frame limit rejects a
48 MP phone photo (8064×6048) even when it is under 10 MB.

The largest legitimate need measured was a two-frame 40 MP WebP: 632 MiB peak RSS
on arm64 and 644 MiB on amd64, finishing in 0.7 s. In a manual arm64 run outside the
recorded reports, an equivalent file failed under a 640 MiB ceiling and passed
under 768 MiB. The slowest was a 25-frame 100 MP WebP: about
1 s. Timings come from Docker on an Apple Silicon Mac, not the
VPS.

Each parser can use up to 1 GiB. Parse an attempt's files one at a time, and cap
concurrent parsers across the application to fit host memory.

### Failure semantics

Map the child's result to three outcomes, not to its reason strings:

| Outcome | Child result |
|---|---|
| `{:error, :too_large}` | `bytes_over_limit`, `dimensions_over_limit`, `frame_pixels_over_limit`, `frames_over_limit`, `total_pixels_over_limit` |
| `{:error, :unsupported}` | `unclassifiable`: not PNG, JPEG, WebP or GIF by content |
| `{:error, :invalid}` | `malformed`, `memory_limit`, deadline (exit 137), and any other parser failure |

An accepted file sets `is_animated` to `frames > 1` and derives the stored
extension and Content-Type from `format`, not from the client's file name.

### Platform dependencies

- **Release image:** the final stage has no Python. Add Debian's `python3` and
  `python3-venv`, then install Pillow from the hash-pinned requirements file.
  `timeout` (coreutils) and `prlimit` (util-linux) are already in Debian slim.
- **Hashes:** `requirements.txt` pins the CPython 3.11 manylinux wheels for x86_64
  and aarch64 only. CI's Python and macOS development need their own pinned wheel
  hashes.
- **macOS:** there is no `prlimit`, and macOS does not enforce `RLIMIT_AS`. On
  macOS, drop `prlimit` and run the memory-ceiling test on Linux only. CI runs on
  Linux, so the ceiling is still tested on every run. Homebrew coreutils provides
  `timeout`.

### Verification

- `bash scripts/image_parser_probe.sh` reproduces this report until #62
  replaces it.
- #62's integration tests use these fixtures. At minimum they cover one accept per
  format, an animated APNG and an animated WebP, one truncated file, one
  over-limit header, and the deadline and address-space kills.
