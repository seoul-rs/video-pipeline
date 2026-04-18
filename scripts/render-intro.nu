#!/usr/bin/env nu
# Render the intro card: substitute placeholders in assets/intro.svg,
# rasterize with resvg, and mux the PNG with assets/intro.wav
# (or silence if the file is absent) using ffmpeg.
#
# Writes output to work/intro.mp4.
#
# Title layout: these mirror the <text> element in assets/intro.svg
# (x=960, y=500, font-size=96). Line height is 1.2em = 115.2px.
const TITLE_X = 960
const TITLE_CENTER_Y = 500
const TITLE_LINE_HEIGHT = 115.2

# Build one <tspan> per line, vertically centered around TITLE_CENTER_Y.
def title-tspans [title: string]: nothing -> string {
    let lines = ($title | split row "\n" | each { str trim } | where {|l| $l != "" })
    let n = ($lines | length)
    let top_y = $TITLE_CENTER_Y - ($n - 1) * $TITLE_LINE_HEIGHT / 2
    $lines
    | enumerate
    | each {|it|
        let y = $top_y + $it.index * $TITLE_LINE_HEIGHT
        $'<tspan x="($TITLE_X)" y="($y)">($it.item)</tspan>'
    }
    | str join "\n    "
}

def main [cue_path: string] {
    let cue = open $cue_path
    let w = ($cue.layout.resolution | get 0)
    let h = ($cue.layout.resolution | get 1)
    let fps = $cue.layout.fps

    mkdir work

    print "rendering intro card SVG"
    open --raw assets/intro.svg
    | str replace --all "{{TITLE}}" (title-tspans $cue.title)
    | str replace --all "{{SPEAKER}}" $cue.speaker
    | str replace --all "{{DATE}}" $cue.date
    | save -f work/intro.svg

    print "rasterizing with resvg"
    ^resvg -w ($w | into string) -h ($h | into string) work/intro.svg work/intro.png

    let audio_file = "assets/intro.wav"
    let audio_args = if ($audio_file | path exists) {
        print $"muxing with ($audio_file)"
        ["-i" $audio_file]
    } else {
        print "no assets/intro.wav found - using 3s of silence"
        ["-f" "lavfi" "-t" "3" "-i" "anullsrc=r=48000:cl=stereo"]
    }

    let args = [
        "-y"
        "-loop" "1" "-i" "work/intro.png"
        ...$audio_args
        "-vf" $"fps=($fps),scale=($w):($h),setsar=1,format=yuv420p"
        "-c:v" "libx264" "-tune" "stillimage" "-preset" "medium" "-crf" "20"
        "-pix_fmt" "yuv420p"
        "-c:a" "aac" "-ar" "48000" "-ac" "2" "-b:a" "192k"
        "-r" ($fps | into string)
        "-shortest"
        "-movflags" "+faststart"
        "work/intro.mp4"
    ]
    ^ffmpeg ...$args
}
