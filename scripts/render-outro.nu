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

    let audio_file = "assets/outro.wav"
    let audio_args = if ($audio_file | path exists) {
        print $"muxing with ($audio_file)"
        ["-i" $audio_file]
    } else {
        print "no assets/outro.wav found - using 3s of silence"
        ["-f" "lavfi" "-t" "3" "-i" "anullsrc=r=48000:cl=stereo"]
    }

    let args = [
        "-y"
        "-loop" "1" "-i" "work/outro.png"
        ...$audio_args
        "-vf" $"fps=($fps),scale=($w):($h),setsar=1,format=yuv420p"
        "-c:v" "libx264" "-tune" "stillimage" "-preset" "medium" "-crf" "20"
        "-pix_fmt" "yuv420p"
        "-c:a" "aac" "-ar" "48000" "-ac" "2" "-b:a" "192k"
        "-r" ($fps | into string)
        "-shortest"
        "-movflags" "+faststart"
        "work/outro.mp4"
    ]
    ^ffmpeg ...$args
}
