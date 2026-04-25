# Seoul Rust Video Pipeline

This repo is a set of scripts that we use to turn raw recordings into a finished video.
We use this for the [Seoul Rust meetup](https://seoul.rs/), but feel free to fork for your own needs.
The pipeline adds branded intro and outro cards, and handles switching camera configurations
(e.g., speaker-only, screen primary + speaker PiP, etc.) at cue points.

Runs headlessly from the shell on most operating systems.

## Dependencies

Install these first via your package manager of choice.

- [`just`](https://just.systems): recipe runner; like make, but fewer footguns and written in Rust
- [`nushell`](https://nushell.sh): shell scripting, with superpowers and fewer footguns; also written in Rust
- [`ffmpeg`](https://ffmpeg.org) — rendering and compositing. **On macOS, install Homebrew's `ffmpeg-full`** (`brew install ffmpeg-full`), not the regular `ffmpeg`. The pipeline needs the `zscale` (libzimg) and `tonemap` filters for HDR→SDR conversion, which are only bundled in `ffmpeg-full`. On Linux/BSD, check that your distro's ffmpeg was built with libzimg.
- [`resvg`](https://github.com/linebender/resvg): SVG rendering to PNG (intro and outro cards); also Rust

## Quick start

```sh
cp cue.sample.toml cue.toml
# edit cue.toml: title/speaker/date, source file paths, cues
just render
# → output/final.mp4
```

Individual stages:

```sh
just intro    # → work/intro.mp4
just body     # → work/body.mp4
just outro    # → work/outro.mp4
just concat   # → output/final.mp4
just clean    # wipe work/ and output/
```

## Inputs

Drop your talk recordings somewhere the cue file can point at them
(`recordings/` is gitignored and conventional):

- **Speaker video** (required). Video + audio.
- **Screen recording** (optional). If omitted with no cues, the body
  is just the rescaled speaker video. If omitted with cues present,
  every non-speaker-only cue must supply an `image` (see cue
  reference). Any audio on the screen is ignored when the speaker
  video has its own.
- **Still images** (optional). Any cue that uses the screen role may
  declare `image = "path.png"` to show a still image in place of the
  screen feed for that window. Works with or without a screen
  recording.
- **Separate audio track** (optional). Set `sources.audio` in the cue
  file to override the default audio source.

## Per-meetup branding (once)

Four files live under `assets/` and are checked into version control, so every
talk gets consistent branding:

| File               | Purpose                                   |
| ------------------ | ----------------------------------------- |
| `assets/intro.svg` | Intro card template (1920×1080). Uses `{{TITLE}}`, `{{SPEAKER}}`, `{{DATE}}`. |
| `assets/outro.svg` | Static outro card (1920×1080). No placeholders. |
| `assets/intro.wav` | Optional branding sting played over intro. If absent, 3 s of silence. |
| `assets/outro.wav` | Optional branding sting played over outro. If absent, 3 s of silence. |

When an audio file is present, the intro card is shown for the full duration.

## Cue file reference

See `cue.sample.toml` for the canonical example and documentation.

## Troubleshooting

**Screen/speaker out of sync.** Watch the current output and note
which side leads. If screen events happen *before* the speaker
describes them, set `sync.screen_offset` to a **positive** value
(magnitude = drift in seconds). If screen events happen *after* the
speaker describes them, set a **negative** value. Rerun `just body &&
just concat`. Start with the clap or cue sound you recorded at the
beginning of the talk — that's the easiest reference point.

**Intro card title overflows.** The intro SVG has no auto-wrap
(resvg does not implement SVG 2 `inline-size`). Break the title
into two lines by using a TOML triple-quoted string with an explicit
newline:

```toml
title = """
Zia: A programming language
that defines itself
"""
```

Each line renders as its own tspan, and the block is vertically
centered around the original title baseline.

**Missing fonts on Linux.** `resvg` uses system fonts. You need to have them installed.
