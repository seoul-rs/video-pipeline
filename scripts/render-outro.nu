#!/usr/bin/env nu
# Render the outro card: rasterize assets/outro.svg
# and mux with assets/outro.wav (or silence if absent).
#
# Renders output to work/outro.mp4.

use ./config.nu *

def main [cue_path: string] {
    let cue = open $cue_path
    let w = ($cue.layout.resolution | get 0)
    let h = ($cue.layout.resolution | get 1)
    let fps = $cue.layout.fps

    mkdir work

    print "rasterizing outro card"
    ^resvg -w ($w | into string) -h ($h | into string) assets/outro.svg work/outro.png

    # See render-intro.nu for why we bound the video loop explicitly with
    # `-t $dur` rather than relying on `-shortest`: it avoids video/audio
    # track-duration mismatch that breaks A/V sync across concat boundaries.
    let audio_plan = if ("assets/outro.wav" | path exists) {
        let dur = (^ffprobe -v error -show_entries format=duration -of csv=p=0 "assets/outro.wav"
            | complete | get stdout | str trim | into float)
        print "muxing with assets/outro.wav"
        { args: ["-i" "assets/outro.wav"], dur: $dur }
    } else {
        print $"no assets/outro.wav found - using ($DEFAULT_SEGMENT_SILENCE_SECS)s of silence"
        { args: ["-f" "lavfi" "-i" "anullsrc=r=48000:cl=stereo"], dur: $DEFAULT_SEGMENT_SILENCE_SECS }
    }

    let args = [
        "-y"
        "-loop" "1" "-t" ($audio_plan.dur | into string) "-i" "work/outro.png"
        ...$audio_plan.args
        "-vf" $"fps=($fps),scale=($w):($h),setsar=1,zscale=tin=iec61966-2-1:pin=bt709:min=bt709:rin=full:t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p"
        ...$VIDEO_ENCODE_ARGS
        "-tune" "stillimage"
        ...$AUDIO_ENCODE_ARGS
        "-r" ($fps | into string)
        "-t" ($audio_plan.dur | into string)
        "-movflags" "+faststart"
        "work/outro.mp4"
    ]
    ^ffmpeg ...$args
}
