# Image parser probe

Result for [#244](https://github.com/chenghanlee/tips/issues/244): **Pillow 12.3.0
is selected.** Run in its own OS process under `timeout` and `prlimit`, it passes
all 40 fixtures and all three enforcement experiments on linux/arm64 and
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

Both runs are at `f6c221f` with no tracked changes:

- arm64 `20261006T173737Z`:
  [report](image-parser-probe/arm64-20261006T173737Z-report.json),
  [fixtures](image-parser-probe/arm64-20261006T173737Z-fixtures.json).
- amd64 under Docker emulation `20261006T173820Z`:
  [report](image-parser-probe/amd64-20261006T173820Z-report.json),
  [fixtures](image-parser-probe/amd64-20261006T173820Z-fixtures.json).

Fixture bytes are stable across runs on one architecture: repeated arm64 runs gave
identical hashes for all 40 fixtures. Across architectures, the lossy encodes
differ (`static.jpg`, `spoofed-jpeg-as.png`, `truncated.jpg` and the three
lossy at-limit WebPs). Every other fixture is byte-identical. All verdicts match.

## Fixture results

`ms` is the caller's wall time and includes about 30–45 ms of Python startup.
Peak RSS is the parser process's `ru_maxrss`.

| Fixture | Bytes | Expected | Result | arm64 ms | arm64 peak RSS MiB | amd64 |
|---|---|---|---|---|---|---|
| `static.png` | 469 | accept png static | ✓ accept png static | 30 | 14 | same |
| `animated.apng` | 1,405 | accept png animated | ✓ accept png animated | 31 | 14 | same |
| `single-frame.apng` | 469 | accept png static | ✓ accept png static | 30 | 14 | same |
| `static.jpg` | 1,976 | accept jpeg static | ✓ accept jpeg static | 43 | 19 | same |
| `static.gif` | 1,650 | accept gif static | ✓ accept gif static | 45 | 19 | same |
| `animated.gif` | 3,823 | accept gif animated | ✓ accept gif animated | 47 | 19 | same |
| `static.webp` | 260 | accept webp static | ✓ accept webp static | 44 | 19 | same |
| `animated.webp` | 1,350 | accept webp animated | ✓ accept webp animated | 45 | 19 | same |
| `single-frame.webp` | 590 | accept webp static | ✓ accept webp static | 43 | 19 | same |
| `spoofed-jpeg-as.png` | 1,976 | accept jpeg static | ✓ accept jpeg static | 42 | 19 | same |
| `spoofed-text-as.gif` | 27 | reject unclassifiable | ✓ reject unclassifiable | 43 | 19 | same |
| `svg-as.png` | 64 | reject unclassifiable | ✓ reject unclassifiable | 46 | 19 | same |
| `bmp.bmp` | 9,270 | reject unclassifiable | ✓ reject unclassifiable | 47 | 19 | same |
| `tiff.tif` | 7,715 | reject unclassifiable | ✓ reject unclassifiable | 45 | 19 | same |
| `empty.png` | 0 | reject unclassifiable | ✓ reject unclassifiable | 47 | 19 | same |
| `random.bin` | 4,096 | reject unclassifiable | ✓ reject unclassifiable | 49 | 19 | same |
| `png-signature-garbage.png` | 520 | reject malformed | ✓ reject unclassifiable | 49 | 19 | same |
| `truncated.png` | 281 | reject malformed | ✓ reject malformed | 33 | 14 | same |
| `truncated.jpg` | 1,185 | reject malformed | ✓ reject malformed | 51 | 19 | same |
| `truncated.gif` | 2,293 | reject malformed | ✓ reject malformed | 51 | 19 | same |
| `truncated.webp` | 810 | reject malformed | ✓ reject malformed | 49 | 19 | same |
| `truncated.apng` | 843 | reject malformed | ✓ reject malformed | 33 | 14 | same |
| `corrupt-idat.png` | 469 | reject malformed | ✓ reject malformed | 32 | 14 | same |
| `apng-actl-overcount.png` | 1,405 | reject malformed | ✓ reject malformed | 32 | 14 | same |
| `apng-actl-undercount.png` | 1,405 | reject malformed or accept png static | ✓ accept png static | 30 | 14 | same |
| `apng-frame-outside-canvas.png` | 1,405 | reject malformed | ✓ reject malformed | 29 | 14 | same |
| `webp-anim-flag-unset.webp` | 1,350 | reject malformed or accept webp animated | ✓ reject malformed | 43 | 19 | same |
| `gif-trailer-missing.gif` | 3,822 | reject malformed or accept gif animated | ✓ accept gif animated | 43 | 19 | same |
| `huge-dimensions.png` | 388,871 | reject dimensions_over_limit | ✓ reject dimensions_over_limit | 28 | 14 | same |
| `frame-pixels-over.png` | 62,290 | reject frame_pixels_over_limit | ✓ reject frame_pixels_over_limit | 28 | 14 | same |
| `at-frame-pixel-limit-rgba.png` | 155,586 | accept png static | ✓ accept png static | 388 | 167 | same |
| `at-frame-pixel-limit-rgba16.png` | 311,100 | accept png static | ✓ accept png static | 713 | 167 | same |
| `at-frame-pixel-limit-2-frames.gif` | 3,157,259 | accept gif animated | ✓ accept gif animated | 518 | 496 | same |
| `at-frame-pixel-limit-2-frames.webp` | 1,225,700 | accept webp animated | ✓ accept webp animated | 734 | 631 | same |
| `many-frames.gif` | 25,836 | reject frames_over_limit | ✓ reject frames_over_limit | 50 | 19 | same |
| `at-total-pixel-limit.gif` | 3,291,062 | accept gif animated | ✓ accept gif animated | 866 | 68 | same |
| `at-total-pixel-limit.webp` | 2,045,916 | accept webp animated | ✓ accept webp animated | 974 | 82 | same |
| `at-total-pixel-limit-4-frames.webp` | 1,722,242 | accept webp animated | ✓ accept webp animated | 930 | 426 | same |
| `total-pixels-over.gif` | 5,303,194 | reject total_pixels_over_limit | ✓ reject total_pixels_over_limit | 50 | 19 | same |
| `over-10mb.png` | 12,003,753 | reject bytes_over_limit | ✓ reject bytes_over_limit | 28 | 13 | same |

#61 failed these with Vix 0.41.0/libvips 8.18.3: `animated.apng` (read as static),
`truncated.gif` and `truncated.apng` (accepted). ffprobe 8.1 also failed
`animated.webp`, `truncated.jpg` and `huge-dimensions.png`. Pillow passes all of
them. No handwritten APNG or GIF parsing is needed.

Three fixtures have two acceptable outcomes. The rule: a static result must match
what a browser shows.

- `apng-actl-undercount.png`: `acTL` declares 1 frame but the file holds 5.
  Pillow reads it as static. Chrome 154's `ImageDecoder` also reports one static
  frame. Firefox and Safari were not tested.
- `gif-trailer-missing.gif`: a complete 5-frame GIF without its final `;` byte.
  Pillow and Chrome both read 5 frames.
- `webp-anim-flag-unset.webp`: Pillow rejects it. Chrome cannot read it either.

## Enforcement experiments

Each experiment lowers one ceiling below what a legitimate at-limit fixture needs,
so only the ceiling can stop the work.

| Experiment | Setup | arm64 | amd64 |
|---|---|---|---|
| `deadline_kills_parser` | `at-total-pixel-limit.gif` (about 850 ms) with a 0.2 s deadline | killed, exit 137 at 206 ms; no parser left | same, 217 ms |
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

It prints one JSON line. An accepted file prints `verdict`, `format`
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

The largest legitimate need measured was a two-frame 40 MP WebP: 631 MiB peak RSS
on arm64 and 643 MiB on amd64, finishing in 0.7 s. In a manual arm64 run outside the
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
