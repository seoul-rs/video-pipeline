#!/usr/bin/env nu
# Concatenate work/intro.mp4, work/body.mp4, work/outro.mp4 into output/final.mp4.
#
# Two paths based on layout.xfade_duration:
#   0 -> concat demuxer with -c copy (fast; inputs are already codec-aligned)
#   > 0 -> filter graph with xfade/acrossfade between segments (re-encodes)

use ./config.nu *

def probe-duration [path: string]: nothing -> float {
    ^ffprobe -v error -show_entries format=duration -of csv=p=0 $path
    | complete | get stdout | str trim | into float
}

def main [cue_path: string] {
    let cue = open $cue_path
    let xfade = ($cue.layout.xfade_duration? | default 0.0 | into float)

    mkdir output

    if $xfade <= 0.0 {
        let manifest = [
            "file 'intro.mp4'"
            "file 'body.mp4'"
            "file 'outro.mp4'"
        ] | str join "\n"
        $manifest | save -f work/manifest.txt

        ^ffmpeg -y -f concat -safe 0 -i work/manifest.txt -c copy output/final.mp4
        return
    }

    let intro_dur = (probe-duration "work/intro.mp4")
    let body_dur = (probe-duration "work/body.mp4")
    let outro_dur = (probe-duration "work/outro.mp4")
    let shortest = [$intro_dur $body_dur $outro_dur] | math min

    if $xfade >= $shortest {
        error make {msg: $"xfade_duration ($xfade)s must be shorter than every segment (shortest is ($shortest)s)"}
    }

    # xfade offset = timeline position in the first input where the transition starts.
    # After the first xfade the intermediate runs (intro + body - xfade) seconds,
    # so the second xfade starts xfade seconds before that end.
    let off1 = $intro_dur - $xfade
    let off2 = $intro_dur + $body_dur - 2.0 * $xfade

    let filter = [
        $"[0:v][1:v]xfade=transition=fade:duration=($xfade):offset=($off1)[v01]"
        $"[v01][2:v]xfade=transition=fade:duration=($xfade):offset=($off2)[vout]"
        $"[0:a][1:a]acrossfade=d=($xfade)[a01]"
        $"[a01][2:a]acrossfade=d=($xfade)[aout]"
    ] | str join ";"

    let args = [
        "-y"
        "-i" "work/intro.mp4"
        "-i" "work/body.mp4"
        "-i" "work/outro.mp4"
        "-filter_complex" $filter
        "-map" "[vout]" "-map" "[aout]"
        ...$VIDEO_ENCODE_ARGS
        ...$AUDIO_ENCODE_ARGS
        "-movflags" "+faststart"
        "output/final.mp4"
    ]
    ^ffmpeg ...$args
}
