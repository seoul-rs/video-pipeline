#!/usr/bin/env nu
# Render the body segment. Two paths:
#   - screen recording present -> PiP composite driven by cues
#   - screen recording absent  -> the speaker video rescaled/re-encoded
#
# Audio source precedence: sources.audio override > speaker track >
# screen track > synthesized silence (keeps concat stream-count stable).

use ./filter-complex.nu *

def has-audio-stream [path: string]: nothing -> bool {
    let r = (^ffprobe -v error -select_streams a
        -show_entries stream=codec_type -of csv=p=0 $path | complete)
    not ($r.stdout | str trim | is-empty)
}

# ffmpeg input args + audio map given a resolved audio plan.
# plan.kind: "file" | "stream" | "silence"
# plan.path: path for file kind
# plan.map:  e.g. "0:a", "1:a"; for file/silence kinds, base_input_count
#            is appended by the caller to know the index.
def build-audio [plan: record, base_inputs: int]: nothing -> record {
    # Always pin to the first audio stream (:a:0).
    # iPhone recordings include a second APAC (spatial) track that ffmpeg cannot decode;
    # bare `:a` selects all audio streams and fails on APAC.
    match $plan.kind {
        "stream" => {
            { inputs: [], map: $plan.map }
        }
        "file" => {
            let idx = $base_inputs
            { inputs: ["-i" $plan.path], map: $"($idx):a:0" }
        }
        "silence" => {
            let idx = $base_inputs
            {
                inputs: ["-f" "lavfi" "-i" "anullsrc=r=48000:cl=stereo"]
                map: $"($idx):a:0"
            }
        }
    }
}

def main [cue_path: string] {
    let cue = open $cue_path
    let layout = $cue.layout
    let w = ($layout.resolution | get 0)
    let h = ($layout.resolution | get 1)
    let fps = $layout.fps
    let fps_s = ($fps | into string)

    let speaker = ($cue.sources.speaker | path expand)
    let screen = (if ($cue.sources.screen? | is-empty) { null } else { $cue.sources.screen | path expand })
    let audio_override = (if ($cue.sources.audio? | is-empty) { null } else { $cue.sources.audio | path expand })

    mkdir work

    if $screen == null {
        print "no screen recording set: body = rescaled speaker video"

        let audio_plan = if $audio_override != null {
            { kind: "file", path: $audio_override }
        } else if (has-audio-stream $speaker) {
            { kind: "stream", map: "0:a:0" }
        } else {
            print "speaker has no audio track; using silence"
            { kind: "silence" }
        }
        let audio = (build-audio $audio_plan 1)

        let args = [
            "-y"
            "-i" $speaker
            ...$audio.inputs
            "-vf" $"fps=($fps),scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1,format=yuv420p"
            "-map" "0:v"
            "-map" $audio.map
            "-c:v" "libx264" "-preset" "medium" "-crf" "20"
            "-pix_fmt" "yuv420p"
            "-c:a" "aac" "-ar" "48000" "-ac" "2" "-b:a" "192k"
            "-r" $fps_s
            "-shortest"
            "-movflags" "+faststart"
            "work/body.mp4"
        ]
        ^ffmpeg ...$args
        return
    }

    print "screen + speaker both set: PiP composite"

    let offset = (($cue.sync?.screen_offset? | default 0) | into float)
    let cues = ($cue.cues? | default [])
    if ($cues | is-empty) {
        error make { msg: "screen is set but [[cues]] is empty - add at least one cue" }
    }

    # Trim the head of whichever stream started first so both open at the
    # same real-world moment. -ss before -i seeks the input (audio + video
    # together), so audio stays in sync with its source video. -itsoffset
    # would be cancelled by the setpts=PTS-STARTPTS in the filter graph.
    let screen_pre = if $offset < 0.0 { ["-ss" (($offset * -1.0) | into string)] } else { [] }
    let speaker_pre = if $offset > 0.0 { ["-ss" ($offset | into string)] } else { [] }

    let g = (build-graph $cues $layout)

    let audio_plan = if $audio_override != null {
        { kind: "file", path: $audio_override }
    } else if (has-audio-stream $speaker) {
        { kind: "stream", map: "1:a:0" }
    } else if (has-audio-stream $screen) {
        print "speaker has no audio; falling back to screen audio"
        { kind: "stream", map: "0:a:0" }
    } else {
        print "no audio available; using silence"
        { kind: "silence" }
    }
    let audio = (build-audio $audio_plan 2)

    let args = [
        "-y"
        ...$screen_pre
        "-i" $screen
        ...$speaker_pre
        "-i" $speaker
        ...$audio.inputs
        "-filter_complex" $g.graph
        "-map" $"[($g.out_label)]"
        "-map" $audio.map
        "-c:v" "libx264" "-preset" "medium" "-crf" "20"
        "-pix_fmt" "yuv420p"
        "-c:a" "aac" "-ar" "48000" "-ac" "2" "-b:a" "192k"
        "-r" $fps_s
        "-shortest"
        "-movflags" "+faststart"
        "work/body.mp4"
    ]
    ^ffmpeg ...$args
}
