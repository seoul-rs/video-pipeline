# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## What this is

A render pipeline for Seoul Rust meetup talks: a TOML cue file + raw recordings →
`output/final.mp4` with branded intro/outro cards and cue-driven PiP composition.
There is no application; only nushell scripts orchestrating `ffmpeg`, `ffprobe`, and `resvg`.

## Common commands

```sh
just render          # full pipeline: intro + body + outro + concat
just intro           # work/intro.mp4 only
just body            # work/body.mp4 only
just outro           # work/outro.mp4 only
just concat          # stitch the three into output/final.mp4
just clean           # wipe work/ and output/
```

All recipes consume `cue.toml` by default (override with `cue=<path>`).
There are no tests, lints, or build steps — verification is "render and watch."

## Architecture

The four `scripts/*.nu` files map 1:1 to the just recipes. They share state only through
the cue file and the intermediate MP4s in `work/`.

- `scripts/config.nu` — shared constants. `VIDEO_ENCODE_ARGS` / `AUDIO_ENCODE_ARGS` are
  the canonical encoder settings for *every* segment. **Critical:** the xfade=0 path in
  `concat.nu` uses the concat demuxer with `-c copy`; if intro/body/outro drift in
  encoder params, the stitch silently breaks. Keep all three segments routed through
  these constants.
- `scripts/render-intro.nu` / `render-outro.nu` — substitute placeholders in
  `assets/intro.svg`, rasterize via `resvg`, mux with `assets/{intro,outro}.wav` (or
  a few seconds of silence). Both use explicit `-t $dur` rather than `-shortest` to keep audio
  and video tracks the same length — `-shortest` overshoots video by 1–2 s, which
  desyncs the next segment after concat.
- `scripts/render-body.nu` — three branches:
  1. no screen, no cues → rescale speaker only.
  2. screen + cues → PiP composite, real screen on input 0.
  3. no screen + cues → PiP composite over a synthetic black `lavfi` base; every
     non-`speaker-only` cue must supply an `image`.
- `scripts/filter-complex.nu` — builds the body's `filter_complex` graph. Holds nearly
  all the visual-composition logic.

## Spec / code alignment

`video-pipeline.allium` is an [Allium](https://juxt.github.io/allium/) specification that the scripts
implement. Comments in the nushell files reference spec rules by name (e.g.
`SyncOffsetRequiresScreen`, `LastCueCoversBody`, `CornerOnlyOnPrimaryModes`, `config.default_corner`).
When changing observable behavior, update the spec. The `allium:weed` and `allium:tend`
skills are configured for this repo.

## Cue file

`cue.toml` defines the job (gitignored; `cue.sample.toml` is the canonical example and reference doc).
It carries title/speaker/date, source-file paths, sync offset,
layout (resolution / fps / PiP / transition durations), and the `[[cues]]` array.
Make sure that you update the sample's comments when changing functionality,
as they document semantics.
The spec should be able to cross-check this.

## Intermediate files

- `recordings/` holds raw inputs by convention (not strictly enforced).
- `work/` holds intermediates (`intro.png`, `intro.svg`, `intro.mp4`, `body.mp4`, `outro.mp4`, `manifest.txt`) during a render.
- `output/final.mp4` is the result.

`just clean` resets `work/` and `output/`.
