#!/usr/bin/env nu
# Render the outro card: rasterize assets/outro.svg
# and mux with assets/outro.wav (or silence if absent).
#
# Renders output to work/outro.mp4.

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
        print "no assets/outro.wav found - using 3s of silence"
        { args: ["-f" "lavfi" "-i" "anullsrc=r=48000:cl=stereo"], dur: 3.0 }
    }

    let args = [
        "-y"
        "-loop" "1" "-t" ($audio_plan.dur | into string) "-i" "work/outro.png"
        ...$audio_plan.args
        "-vf" $"fps=($fps),scale=($w):($h),setsar=1,zscale=tin=iec61966-2-1:pin=bt709:min=bt709:rin=full:t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p"
        "-c:v" "libx264" "-tune" "stillimage" "-preset" "medium" "-crf" "20"
        "-pix_fmt" "yuv420p"
        "-colorspace" "bt709" "-color_primaries" "bt709" "-color_trc" "bt709" "-color_range" "tv"
        "-c:a" "aac" "-ar" "48000" "-ac" "2" "-b:a" "192k"
        "-r" ($fps | into string)
        "-t" ($audio_plan.dur | into string)
        "-movflags" "+faststart"
        "work/outro.mp4"
    ]
    ^ffmpeg ...$args
}
