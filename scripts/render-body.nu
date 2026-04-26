#!/usr/bin/env nu
# Render the body segment. Three paths:
#   - screen + cues present   -> PiP composite driven by cues (real screen
#                                input 0; image cues overlay onto [scr])
#   - no screen + cues present -> PiP composite with synthetic black base
#                                 (lavfi color=black as input 0; every
#                                 non-speaker-only cue must have an image)
#   - no screen + no cues      -> speaker video rescaled/re-encoded
#
# Audio source precedence: sources.audio override > speaker track >
# screen track > synthesized silence (keeps concat stream-count stable).

use ./filter-complex.nu *

def has-audio-stream [path: string]: nothing -> bool {
    let r = (^ffprobe -v error -select_streams a
        -show_entries stream=codec_type -of csv=p=0 $path | complete)
    not ($r.stdout | str trim | is-empty)
}

def probe-duration [path: string]: nothing -> float {
    ^ffprobe -v error -show_entries format=duration -of csv=p=0 $path
    | complete
    | get stdout
    | str trim
    | into float
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
    let cues = ($cue.cues? | default [])
    let offset = (($cue.sync?.screen_offset? | default 0) | into float)

    # Spec invariant SyncOffsetRequiresScreen: offset is only meaningful
    # when sources.screen is set. Enforce before path branching so the
    # rescaled-speaker fast path rejects it too.
    if $screen == null and $offset != 0.0 {
        error make { msg: "sync.screen_offset is only meaningful when sources.screen is set" }
    }

    mkdir work

    # Simple path: no screen, no cues -> just rescale the speaker.
    if $screen == null and ($cues | is-empty) {
        print "no screen recording, no cues: body = rescaled speaker video"

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
            "-vf" $"fps=($fps),($NORMALIZE_YUV),scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1"
            "-map" "0:v"
            "-map" $audio.map
            "-c:v" "libx264" "-preset" "medium" "-crf" "20"
            "-pix_fmt" "yuv420p"
            "-colorspace" "bt709" "-color_primaries" "bt709" "-color_trc" "bt709" "-color_range" "tv"
            "-c:a" "aac" "-ar" "48000" "-ac" "2" "-b:a" "192k"
            "-r" $fps_s
            "-shortest"
            "-movflags" "+faststart"
            "work/body.mp4"
        ]
        ^ffmpeg ...$args
        return
    }

    # Composite path. Input 0 is either the real screen recording or a
    # black `color=` lavfi stand-in when the talk has no screen but uses
    # image cues.
    let screen_synthetic = ($screen == null)

    if $screen_synthetic {
        print "no screen recording: body = speaker + image cues over synthetic base"
        # Every non-speaker-only cue must supply its own image, since the
        # lavfi base is just black.
        for it in ($cues | enumerate) {
            let c = $it.item
            if $c.mode != "speaker-only" and ($c.image? | is-empty) {
                error make { msg: $"cue ($it.index) \(mode=($c.mode)): sources.screen is not set, so this cue requires an `image`" }
            }
        }
    } else {
        print "screen + speaker both set: PiP composite"
        if ($cues | is-empty) {
            error make { msg: "screen is set but [[cues]] is empty - add at least one cue" }
        }
    }

    # Trim the head of whichever stream started first so both open at the
    # same real-world moment. -ss before -i seeks the input (audio + video
    # together), so audio stays in sync with its source video. -itsoffset
    # would be cancelled by the setpts=PTS-STARTPTS in the filter graph.
    # Neither offset applies when there's no real screen.
    let screen_pre = if (not $screen_synthetic) and $offset < 0.0 { ["-ss" (($offset * -1.0) | into string)] } else { [] }
    let speaker_pre = if (not $screen_synthetic) and $offset > 0.0 { ["-ss" ($offset | into string)] } else { [] }

    # Speaker duration after any head-trim. `until = "end"` resolves to this.
    let speaker_dur = if (not $screen_synthetic) and $offset > 0.0 {
        (probe-duration $speaker) - $offset
    } else {
        (probe-duration $speaker)
    }
    let speaker_dur_s = ($speaker_dur | into string)

    let normalized = (normalize-cues $cues $speaker_dur)

    # Image cues feed the graph as additional inputs. Input layout:
    #   non-synthetic: [0]=screen, [1]=speaker, [2..]=images
    #   synthetic:     [0]=speaker, [1..]=images   (lavfi black is gone —
    #                  the concat'd image track in filter-complex is the
    #                  full-body canvas in synthetic mode)
    # Within filter-complex, contiguous same-routing image cues xfade
    # into each other as a single concat segment. xfade consumes
    # `transition` seconds from the front of every clip after the first
    # in a run, so those clips need their input duration bumped by
    # `transition` to keep the run's timeline math intact. The lead_in
    # test below MUST stay aligned with the one in filter-complex.nu's
    # image_entries — they together drive the xfade offset arithmetic.
    let transition = ($layout.transition_duration | into float)
    let route_of = { |mode|
        if $mode in ["screen-primary" "screen-only"] { "full" } else if $mode == "speaker-primary" { "pip" } else { null }
    }
    let image_cues = ($normalized | where { ($in.image? | default null) != null })
    let m = ($image_cues | length)
    let image_inputs = ($normalized | enumerate | each { |it|
        let c = $it.item
        if ($c.image? | default null) == null {
            []
        } else {
            let routing = (do $route_of $c.mode)
            let lead_in = if $it.index > 0 {
                let p = ($normalized | get ($it.index - 1))
                let p_image = ($p.image? | default null)
                let p_routing = (do $route_of $p.mode)
                ($p_image != null) and ($p_routing == $routing) and ($p.to == $c.from)
            } else { false }
            let cue_dur = ($c.to - $c.from)
            let dur = $cue_dur + (if $lead_in { $transition } else { 0.0 })
            ["-loop" "1" "-framerate" $fps_s "-t" ($dur | into string) "-i" $c.image]
        }
    } | flatten)

    let g = (build-graph $normalized $layout $speaker_dur $screen_synthetic)

    let screen_input_args = if $screen_synthetic { [] } else { [...$screen_pre "-i" $screen] }
    let speaker_idx = (if $screen_synthetic { 0 } else { 1 })
    let audio_base = ((if $screen_synthetic { 1 } else { 2 }) + $m)

    let audio_plan = if $audio_override != null {
        { kind: "file", path: $audio_override }
    } else if (has-audio-stream $speaker) {
        { kind: "stream", map: $"($speaker_idx):a:0" }
    } else if (not $screen_synthetic) and (has-audio-stream $screen) {
        print "speaker has no audio; falling back to screen audio"
        { kind: "stream", map: "0:a:0" }
    } else {
        print "no audio available; using silence"
        { kind: "silence" }
    }
    let audio = (build-audio $audio_plan $audio_base)

    let args = [
        "-y"
        ...$screen_input_args
        ...$speaker_pre
        "-i" $speaker
        ...$image_inputs
        ...$audio.inputs
        "-filter_complex" $g.graph
        "-map" $"[($g.out_label)]"
        "-map" $audio.map
        "-c:v" "libx264" "-preset" "medium" "-crf" "20"
        "-pix_fmt" "yuv420p"
        "-colorspace" "bt709" "-color_primaries" "bt709" "-color_trc" "bt709" "-color_range" "tv"
        "-c:a" "aac" "-ar" "48000" "-ac" "2" "-b:a" "192k"
        "-r" $fps_s
        "-t" $speaker_dur_s
        "-shortest"
        "-movflags" "+faststart"
        "work/body.mp4"
    ]
    ^ffmpeg ...$args
}
