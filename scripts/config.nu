# Shared config values referenced by spec video-pipeline.allium.

# Hold time for an intro/outro card when no audio sting is supplied.
# Spec: config.default_segment_silence.
export const DEFAULT_SEGMENT_SILENCE_SECS = 3.0

# Resting corner of the PiP when a *-primary cue omits `corner`.
# Spec: config.default_corner.
export const DEFAULT_CORNER = "bottom-right"

# Encoder/colour settings shared across every segment we render.
#
# The xfade=0 path in concat.nu uses the concat demuxer with `-c copy`,
# which silently fails (or produces a broken stitch) if any segment's
# encoder parameters drift from the others. Keeping these in one place
# makes that invariant structural rather than implicit.
#
# render-intro and render-outro additionally pass `-tune stillimage`
# (libx264 option, harmless to layer alongside `-c:v libx264`).
export const VIDEO_ENCODE_ARGS = [
    "-c:v" "libx264" "-preset" "medium" "-crf" "20"
    "-pix_fmt" "yuv420p"
    "-colorspace" "bt709" "-color_primaries" "bt709" "-color_trc" "bt709" "-color_range" "tv"
]

export const AUDIO_ENCODE_ARGS = [
    "-c:a" "aac" "-ar" "48000" "-ac" "2" "-b:a" "192k"
]
