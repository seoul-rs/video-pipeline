#!/usr/bin/env nu
# Render the intro card: substitute placeholders in assets/intro.svg,
# rasterize with resvg, and mux the PNG with assets/intro.wav
# (or silence if the file is absent) using ffmpeg.
#
# Writes output to work/intro.mp4.

const TITLE_X = 960

# Per-line-count layout: font size, line height (1.2em), the vertical center
# of the title block, and the y coords for speaker and date beneath it.
# n=1/2 preserve the original look; n>=3 shrinks the title and shifts
# speaker/date down to clear the taller block.
def layout-for [n: int]: nothing -> record {
    if $n <= 2 {
        { font_size: 96, line_height: 115.2, title_center_y: 500, speaker_y: 640, date_y: 900 }
    } else if $n == 3 {
        { font_size: 78, line_height: 93.6, title_center_y: 480, speaker_y: 700, date_y: 920 }
    } else {
        { font_size: 66, line_height: 79.2, title_center_y: 460, speaker_y: 720, date_y: 930 }
    }
}

def title-lines [title: string]: nothing -> list<string> {
    $title | split row "\n" | each { str trim } | where {|l| $l != "" }
}

# Build one <tspan> per line, vertically centered around layout.title_center_y.
def title-tspans [lines: list<string>, layout: record]: nothing -> string {
    let n = ($lines | length)
    let top_y = $layout.title_center_y - ($n - 1) * $layout.line_height / 2
    $lines
    | enumerate
    | each {|it|
        let y = $top_y + $it.index * $layout.line_height
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

    let lines = (title-lines $cue.title)
    let n = ($lines | length)
    let layout = (layout-for $n)
    print $"rendering intro card SVG \(($n)-line title at ($layout.font_size)pt\)"

    open --raw assets/intro.svg
    | str replace --all "{{TITLE}}" (title-tspans $lines $layout)
    | str replace --all "{{TITLE_FONT_SIZE}}" ($layout.font_size | into string)
    | str replace --all "{{SPEAKER_Y}}" ($layout.speaker_y | into string)
    | str replace --all "{{DATE_Y}}" ($layout.date_y | into string)
    | str replace --all "{{SPEAKER}}" $cue.speaker
    | str replace --all "{{DATE}}" $cue.date
    | save -f work/intro.svg

    print "rasterizing with resvg"
    ^resvg -w ($w | into string) -h ($h | into string) work/intro.svg work/intro.png

    # We bound the video loop with `-t $dur` rather than using `-shortest`.
    # `-shortest` with `-loop 1 -i still.png` overshoots video by ~1-2s,
    # giving tracks of mismatched durations. The concat demuxer then plays
    # each track independently and the next segment's audio starts while
    # this segment's video is still on screen. Explicit `-t` keeps them even.
    let audio_plan = if ("assets/intro.wav" | path exists) {
        let dur = (^ffprobe -v error -show_entries format=duration -of csv=p=0 "assets/intro.wav"
            | complete | get stdout | str trim | into float)
        print "muxing with assets/intro.wav"
        { args: ["-i" "assets/intro.wav"], dur: $dur }
    } else {
        print "no assets/intro.wav found - using 3s of silence"
        { args: ["-f" "lavfi" "-i" "anullsrc=r=48000:cl=stereo"], dur: 3.0 }
    }

    let args = [
        "-y"
        "-loop" "1" "-t" ($audio_plan.dur | into string) "-i" "work/intro.png"
        ...$audio_plan.args
        "-vf" $"fps=($fps),scale=($w):($h),setsar=1,format=yuv420p"
        "-c:v" "libx264" "-tune" "stillimage" "-preset" "medium" "-crf" "20"
        "-pix_fmt" "yuv420p"
        "-c:a" "aac" "-ar" "48000" "-ac" "2" "-b:a" "192k"
        "-r" ($fps | into string)
        "-t" ($audio_plan.dur | into string)
        "-movflags" "+faststart"
        "work/intro.mp4"
    ]
    ^ffmpeg ...$args
}
