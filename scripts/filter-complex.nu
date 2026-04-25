# Helpers for generating the body-render filter_complex string.
#
# Input indexing: 0 = screen, 1 = speaker.
#
# Applied to every YUV input at graph entry so downstream stages operate
# in a single well-defined space. Linearize → primaries to BT.709 →
# Hable tonemap (no-op on SDR, rolls off HDR highlights) → BT.709 matrix
# + limited range → 8-bit yuv420p. Requires ffmpeg built with libzimg
# (zscale) and the tonemap filter — see README Prerequisites.
export const NORMALIZE_YUV = "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=limited,format=yuv420p"
# Color-space conversion for sRGB still images. `format=gbrp` forces a
# known planar RGB pix_fmt before zscale — without it, the preceding
# scale filter in a filter_complex graph can negotiate `gbr`-tagged RGB
# that zscale rejects with "no path between colorspaces". zscale then
# applies sRGB transfer → BT.709 transfer and converts to BT.709-matrix
# limited-range YUV. Caller appends `format=yuv420p` or `format=yuva420p`
# depending on whether an alpha channel is needed downstream.
export const NORMALIZE_SRGB = "format=gbrp,zscale=tin=iec61966-2-1:pin=bt709:t=bt709:p=bt709:m=bt709:r=tv"
#
# Graph shape:
#   [scr]           screen full-frame
#   [cam_pip]       speaker scaled + bordered, for sliding PiP
#   [scr_pip]       screen scaled + bordered, for sliding PiP in speaker-primary mode
#   [cam_i]         speaker full-frame, one per merged speaker-primary/only
#                   window, trimmed to that window and alpha-faded at the edges
#                   with `fade` — gives the base a crossfade instead of a cut
#
#   [scr][cam_pip]      overlay, x/y exprs covering all screen-primary corners  -> [v1]
#   [v1][cam_0]         overlay 0:0, enable gated on merged window 0            -> [vbase_0]
#   [vbase_0][cam_1]    overlay 0:0, enable gated on merged window 1            -> [vbase_1]
#   ...                                                                         -> [vbase_{N-1}]
#   [vbase_{N-1}][scr_pip] overlay for speaker-primary corners                  -> [vout]
#                          (omitted if no speaker-primary cue)
#
# Cues declare only `until` (end timestamp); `from` is implicit — 0 for the
# first cue, the previous cue's `until` for every subsequent cue. The magic
# value `until = "end"` resolves to the speaker video's duration (passed in
# from the caller). Cues may declare an optional `corner` field (default
# "bottom-right"). Valid: bottom-right, top-right, top-left, bottom-left.
# The PiP slides in horizontally from the nearest canvas edge and rests at
# the chosen corner. Only applies to `screen-primary` and `speaker-primary`
# cues.

export def parse-hms [s: string]: nothing -> float {
    let parts = ($s | split row ":" | each { into float })
    match ($parts | length) {
        3 => ($parts.0 * 3600.0 + $parts.1 * 60.0 + $parts.2)
        2 => ($parts.0 * 60.0 + $parts.1)
        1 => $parts.0
        _ => (error make { msg: $"invalid HH:MM:SS string: ($s)" })
    }
}

# Expand `[[cues]]` with `until` into the internal { mode, corner?, from, to }
# form, with `from`/`to` as floats (seconds). Resolves the implicit `from`
# (0 for cue 0, previous cue's resolved `until` thereafter) and the magic
# value `until = "end"` → `video_duration`. Enforces:
#   - monotonicity: each `until` strictly greater than the running `from`
#   - `"end"` only on the last cue
export def normalize-cues [
    cues: list<record>
    video_duration: float
]: nothing -> list<record> {
    let n = ($cues | length)
    $cues | enumerate | reduce --fold { out: [], cursor: 0.0 } { |it, acc|
        let i = $it.index
        let c = $it.item
        let is_last = ($i == ($n - 1))
        let until_raw = $c.until
        let to = if $until_raw == "end" {
            if not $is_last {
                error make { msg: $"cue ($i): `until = \"end\"` is only valid on the last cue" }
            }
            $video_duration
        } else {
            parse-hms $until_raw
        }
        if $to <= $acc.cursor {
            error make { msg: $"cue ($i): `until` \(($to)s) must be strictly greater than the cue's start \(($acc.cursor)s)" }
        }
        let image = (if ($c.image? | is-empty) { null } else { $c.image | path expand })
        if ($image != null) {
            if $c.mode == "speaker-only" {
                error make { msg: $"cue ($i): `image` is not valid on `speaker-only` cues \(the image would have nowhere to appear)" }
            }
            if not ($image | path exists) {
                error make { msg: $"cue ($i): image file not found: ($image)" }
            }
        }
        let rec = {
            mode: $c.mode
            corner: ($c.corner? | default "bottom-right")
            from: $acc.cursor
            to: $to
            image: $image
        }
        { out: ($acc.out | append $rec), cursor: $to }
    }
    | get out
}

# Sine envelope that ramps 0 -> 1 over [t1, t1+d] and 1 -> 0 over [t2-d, t2].
export def envelope [t1: float, t2: float, d: float]: nothing -> string {
    let t2md = ($t2 - $d)
    $"sin\(clip\(\(t-($t1))/($d),0,1)*PI/2)*\(1-sin\(clip\(\(t-($t2md))/($d),0,1)*PI/2))"
}

# Corner geometry in overlay coordinates (top-left of padded PiP).
#   off_x  — x where the PiP slides in from (closest horizontal edge).
#   rest_x — x at the chosen corner.
#   y      — constant y (PiP slides horizontally only).
export def corner-spec [
    corner: string
    w: int       # canvas width
    h: int       # canvas height
    pip_w: int   # inner PiP width (no border)
    pph: int     # padded PiP height
    ppw: int     # padded PiP width
    margin: int
]: nothing -> record {
    match $corner {
        "bottom-right" => { off_x: $w, rest_x: ($w - $pip_w - $margin), y: ($h - $pph - $margin) }
        "top-right"    => { off_x: $w, rest_x: ($w - $pip_w - $margin), y: $margin }
        "top-left"     => { off_x: (-1 * $ppw), rest_x: $margin, y: $margin }
        "bottom-left"  => { off_x: (-1 * $ppw), rest_x: $margin, y: ($h - $pph - $margin) }
        _ => (error make { msg: $"unknown corner: ($corner). valid: bottom-right, top-right, top-left, bottom-left" })
    }
}

# Emit `+K*(expr)` or `-|K|*(expr)`; empty string when K == 0.
def signed-term [k: int, expr: string]: nothing -> string {
    if $k == 0 {
        ""
    } else if $k > 0 {
        $"+($k)*\(($expr))"
    } else {
        let neg = ($k * -1)
        $"-($neg)*\(($expr))"
    }
}

# Build a single overlay-axis expression (x or y) covering multiple
# corner groups. Each group: { windows: list<list<float>>, off: int, rest: int }.
#
# Math (relies on cue windows being non-overlapping):
#   outside all windows     -> default_off
#   inside group c's window -> off_c + (rest_c - off_c) * envelope(t)
#
# Algebraically:
#   pos(t) = default_off
#          + Σ_c between_sum_c * (off_c - default_off)    (step to corner's off)
#          + Σ_c env_sum_c     * (rest_c - off_c)         (smooth slide to rest)
#
# between_sum_c = Σ between(t, t1, t2) over cues in corner c (stepped 0/1)
# env_sum_c     = Σ envelope(t1, t2) over cues in corner c (smooth ramp)
export def axis-expr [
    groups: list<record>
    transition: float
    default_off: int
]: nothing -> string {
    let terms = ($groups | each { |g|
        if ($g.windows | is-empty) {
            ""
        } else {
            let between_sum = ($g.windows | each { |w| $"between\(t,($w.0),($w.1))" } | str join "+")
            let env_sum = ($g.windows | each { |w| envelope $w.0 $w.1 $transition } | str join "+")
            let off_shift = ($g.off - $default_off)
            let rest_shift = ($g.rest - $g.off)
            let t_step = (signed-term $off_shift $between_sum)
            let t_slide = (signed-term $rest_shift $env_sum)
            $"($t_step)($t_slide)"
        }
    })
    let joined = ($terms | str join "")
    if ($joined | is-empty) {
        ($default_off | into string)
    } else {
        $"($default_off)($joined)"
    }
}

# Fuse exactly-adjacent windows (next.t1 == curr.t2). Input windows are
# assumed non-overlapping; adjacency comes from contiguous cues. Used to
# coalesce speaker-primary + speaker-only windows that drive the base-layer
# alpha/enable so the cam layer stays opaque across the seam rather than
# dipping to transparent.
def merge-windows [windows: list<list<float>>]: nothing -> list<list<float>> {
    $windows
    | sort-by { |w| $w.0 }
    | reduce --fold [] { |w, acc|
        if ($acc | is-empty) {
            [$w]
        } else {
            let last = ($acc | last)
            if $w.0 == $last.1 {
                ($acc | drop 1 | append [[$last.0, $w.1]])
            } else {
                ($acc | append [$w])
            }
        }
    }
}

# Build the complete filter_complex string.
# Returns a record: { graph: string, out_label: string }
#
# `screen_synthetic` signals that input 0 is a `color=black` lavfi stand-in
# (set when the talk has no real screen recording but has image cues). The
# HDR-aware `NORMALIZE_YUV` is skipped on that input — zscale expects
# color-tagged YUV and the lavfi source is neither HDR nor tagged.
export def build-graph [
    cues: list<record>
    layout: record
    body_dur: float
    screen_synthetic: bool = false
]: nothing -> record {
    let w = ($layout.resolution | get 0)
    let h = ($layout.resolution | get 1)
    let pip_w = ($layout.pip_size | get 0)
    let pip_h = ($layout.pip_size | get 1)
    let margin = $layout.pip_margin
    let transition = ($layout.transition_duration | into float)
    let fps = $layout.fps

    let border = 2
    let ppw = ($pip_w + 2 * $border)
    let pph = ($pip_h + 2 * $border)

    let valid_corners = ["bottom-right" "top-right" "top-left" "bottom-left"]
    let default_off_x = $w
    let default_y = ($h - $pph - $margin)

    let cs = ($cues | each { |c|
        let mode = $c.mode
        let corner = ($c.corner? | default "bottom-right")
        if ($mode in ["screen-primary" "speaker-primary"]) and ($corner not-in $valid_corners) {
            error make { msg: $"cue corner '($corner)' is invalid. valid: ($valid_corners | str join ', ')" }
        }
        {
            mode: $mode
            corner: $corner
            t1: $c.from
            t2: $c.to
        }
    })

    # Image cues get one ffmpeg input each, starting at input index 2 (after
    # screen=0, speaker=1). Preserve cue-order so input indices are stable.
    let image_entries = ($cues | enumerate | reduce --fold { out: [], k: 0 } { |it, acc|
        let c = $it.item
        if ($c.image? | default null) == null {
            $acc
        } else {
            let entry = {
                cue_idx: $it.index
                input_idx: (2 + $acc.k)
                mode: $c.mode
                t1: $c.from
                t2: $c.to
            }
            { out: ($acc.out | append $entry), k: ($acc.k + 1) }
        }
    } | get out)
    # screen-primary / screen-only: image fills the canvas, folded into [scr].
    # speaker-primary: image is the PiP (speaker full-frame covers the base),
    # folded into [scr_pip].
    let full_image_entries = ($image_entries | where mode in ["screen-primary" "screen-only"])
    let pip_image_entries = ($image_entries | where mode == "speaker-primary")

    # Per-mode, per-corner groups. The same windows drive both x
    # (which slides) and y (which steps between top and bottom).
    let screen_primary_x_groups = ($valid_corners | each { |c|
        let windows = ($cs | where mode == "screen-primary" and corner == $c | each { |x| [$x.t1, $x.t2] })
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.off_x, rest: $spec.rest_x }
    })
    let screen_primary_y_groups = ($valid_corners | each { |c|
        let windows = ($cs | where mode == "screen-primary" and corner == $c | each { |x| [$x.t1, $x.t2] })
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.y, rest: $spec.y }
    })
    let speaker_primary_x_groups = ($valid_corners | each { |c|
        let windows = ($cs | where mode == "speaker-primary" and corner == $c | each { |x| [$x.t1, $x.t2] })
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.off_x, rest: $spec.rest_x }
    })
    let speaker_primary_y_groups = ($valid_corners | each { |c|
        let windows = ($cs | where mode == "speaker-primary" and corner == $c | each { |x| [$x.t1, $x.t2] })
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.y, rest: $spec.y }
    })

    let screen_primary_x = (axis-expr $screen_primary_x_groups $transition $default_off_x)
    let screen_primary_y = (axis-expr $screen_primary_y_groups $transition $default_y)
    let speaker_primary_x = (axis-expr $speaker_primary_x_groups $transition $default_off_x)
    let speaker_primary_y = (axis-expr $speaker_primary_y_groups $transition $default_y)

    let speaker_primary_windows = ($cs | where mode == "speaker-primary" | each { |w| [$w.t1, $w.t2] })
    let speaker_only_windows = ($cs | where mode == "speaker-only" | each { |w| [$w.t1, $w.t2] })
    let merged_base_windows = (merge-windows ($speaker_primary_windows ++ $speaker_only_windows))
    let has_speaker_primary = (not ($speaker_primary_windows | is-empty))

    # Skip NORMALIZE_YUV on synthetic (lavfi color=black) input 0.
    let scr_in_prefix = if $screen_synthetic { "" } else { $"($NORMALIZE_YUV)," }
    # When image cues feed [scr] or [scr_pip], rename the base layer so the
    # fold chain can terminate at the canonical name.
    let scr_base_label = if ($full_image_entries | is-empty) { "scr" } else { "scr_raw" }
    let scr_pip_base_label = if ($pip_image_entries | is-empty) { "scr_pip" } else { "scr_pip_raw" }

    let nodes_common = [
        $"[0:v]setpts=PTS-STARTPTS,fps=($fps),($scr_in_prefix)scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1[($scr_base_label)]"
        $"[1:v]setpts=PTS-STARTPTS,fps=($fps),($NORMALIZE_YUV),scale=($pip_w):($pip_h),setsar=1,pad=($ppw):($pph):($border):($border):white,format=yuva420p[cam_pip]"
    ]
    let n_base = ($merged_base_windows | length)
    # Fade edges only when the window abuts another cue — i.e. crossfade
    # from/to the screen base. If nothing precedes (e.g. the first cue starts
    # at t=0) or nothing follows (e.g. the last cue ends at video end), a fade
    # would reveal the screen underneath and look wrong. Hard-cut in that case.
    let cue_froms = ($cs | each { |c| $c.t1 })
    let cue_tos = ($cs | each { |c| $c.t2 })
    # Per-merged-window cam instances: prep once, split N times, then
    # trim+fade each slice independently. `trim` bounds the frames a
    # downstream overlay will pull, `fade` shapes alpha at the edges.
    # Much cheaper than a time-varying per-pixel alpha expression, because
    # `fade` is SIMD-optimized and each slice only handles its own window.
    let nodes_cam = if $n_base == 0 { [] } else {
        let prep_common = $"[1:v]setpts=PTS-STARTPTS,fps=($fps),($NORMALIZE_YUV),scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1,format=yuva420p"
        let prep_node = if $n_base == 1 {
            $"($prep_common)[cam_src_0]"
        } else {
            let outs = (0..($n_base - 1) | each { |i| $"[cam_src_($i)]" } | str join "")
            $"($prep_common),split=($n_base)($outs)"
        }
        let fade_nodes = ($merged_base_windows | enumerate | each { |it|
            let i = $it.index
            let w_ = $it.item
            let needs_fade_in = ($w_.0 in $cue_tos)
            let needs_fade_out = ($w_.1 in $cue_froms)
            let fade_in = if $needs_fade_in { $",fade=t=in:st=($w_.0):d=($transition):alpha=1" } else { "" }
            let fade_out_st = ($w_.1 - $transition)
            let fade_out = if $needs_fade_out { $",fade=t=out:st=($fade_out_st):d=($transition):alpha=1" } else { "" }
            $"[cam_src_($i)]trim=start=($w_.0):end=($w_.1)($fade_in)($fade_out)[cam_($i)]"
        })
        [$prep_node] ++ $fade_nodes
    }
    let nodes_scr_pip = if $has_speaker_primary {
        [ $"[0:v]setpts=PTS-STARTPTS,fps=($fps),($scr_in_prefix)scale=($pip_w):($pip_h),setsar=1,pad=($ppw):($pph):($border):($border):white,format=yuva420p[($scr_pip_base_label)]" ]
    } else {
        []
    }

    # Image prep nodes: scale + color-convert + edge fades. The fade-at-
    # boundary logic mirrors nodes_cam — fade only when the image cue abuts
    # another cue, so transitions crossfade instead of hard-cutting to the
    # screen base underneath.
    let img_fade_args = { |t1: float, t2: float|
        let needs_fade_in = ($t1 in $cue_tos)
        let needs_fade_out = ($t2 in $cue_froms)
        let fade_in = if $needs_fade_in { $",fade=t=in:st=($t1):d=($transition):alpha=1" } else { "" }
        let fade_out_st = ($t2 - $transition)
        let fade_out = if $needs_fade_out { $",fade=t=out:st=($fade_out_st):d=($transition):alpha=1" } else { "" }
        $"($fade_in)($fade_out)"
    }
    # zscale runs after scale: the PNG decoder emits RGB with loose tags and
    # zscale fails with "no path between colorspaces" when it sees the raw
    # input directly. Running scale first normalizes the pipe, matching the
    # proven chain in render-intro.nu.
    #
    # tpad surrounds the (cue-window-bounded) image stream with transparent
    # frames so it spans the full body. Without this we'd either be processing
    # 30 fps × body_dur frames per image through scale+zscale (pre-fix waste)
    # or hit overlay-sync issues from a secondary input that doesn't exist
    # outside [t1, t2]. tpad's padding frames are cheap (no scale/zscale).
    let nodes_img_full = ($full_image_entries | each { |e|
        let fades = (do $img_fade_args $e.t1 $e.t2)
        let pre = $e.t1
        let post = ($body_dur - $e.t2)
        $"[($e.input_idx):v]setpts=PTS-STARTPTS,fps=($fps),scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1,($NORMALIZE_SRGB),format=yuva420p,tpad=start_duration=($pre):stop_duration=($post):color=black@0($fades)[img_full_($e.cue_idx)]"
    })
    let nodes_img_pip = ($pip_image_entries | each { |e|
        let fades = (do $img_fade_args $e.t1 $e.t2)
        let pre = $e.t1
        let post = ($body_dur - $e.t2)
        $"[($e.input_idx):v]setpts=PTS-STARTPTS,fps=($fps),scale=($pip_w):($pip_h),setsar=1,pad=($ppw):($pph):($border):($border):white,($NORMALIZE_SRGB),format=yuva420p,tpad=start_duration=($pre):stop_duration=($post):color=black@0($fades)[img_pip_($e.cue_idx)]"
    })

    # Fold image full-frames into [scr] via a gated overlay chain:
    #   [scr_raw][img_full_k0] -> [scr_step_k0]
    #   [scr_step_k0][img_full_k1] -> [scr_step_k1]
    #   ...
    #   [scr_step_k{M-2}][img_full_k{M-1}] -> [scr]
    let n_img_full = ($full_image_entries | length)
    let nodes_scr_fold = ($full_image_entries | enumerate | each { |it|
        let i = $it.index
        let e = $it.item
        let prev = if $i == 0 {
            "scr_raw"
        } else {
            let pe = ($full_image_entries | get ($i - 1))
            $"scr_step_($pe.cue_idx)"
        }
        let is_last = ($i == ($n_img_full - 1))
        let next = if $is_last { "scr" } else { $"scr_step_($e.cue_idx)" }
        $"[($prev)][img_full_($e.cue_idx)]overlay=0:0:enable='between\(t,($e.t1),($e.t2))':eof_action=pass[($next)]"
    })
    let n_img_pip = ($pip_image_entries | length)
    let nodes_scr_pip_fold = ($pip_image_entries | enumerate | each { |it|
        let i = $it.index
        let e = $it.item
        let prev = if $i == 0 {
            "scr_pip_raw"
        } else {
            let pe = ($pip_image_entries | get ($i - 1))
            $"scr_pip_step_($pe.cue_idx)"
        }
        let is_last = ($i == ($n_img_pip - 1))
        let next = if $is_last { "scr_pip" } else { $"scr_pip_step_($e.cue_idx)" }
        $"[($prev)][img_pip_($e.cue_idx)]overlay=0:0:enable='between\(t,($e.t1),($e.t2))':eof_action=pass[($next)]"
    })

    let overlay_base = $"[scr][cam_pip]overlay=x='($screen_primary_x)':y='($screen_primary_y)':eof_action=pass[v1]"

    let overlays = if $n_base == 0 {
        [ ($overlay_base | str replace --all "[v1]" "[vout]") ]
    } else {
        let cam_overlays = ($merged_base_windows | enumerate | each { |it|
            let i = $it.index
            let w_ = $it.item
            let prev = if $i == 0 { "v1" } else { let p = ($i - 1); $"vbase_($p)" }
            let is_last = ($i == ($n_base - 1))
            let next = if $is_last and (not $has_speaker_primary) { "vout" } else { $"vbase_($i)" }
            $"[($prev)][cam_($i)]overlay=0:0:enable='between\(t,($w_.0),($w_.1))':eof_action=pass[($next)]"
        })
        let chain = [$overlay_base] ++ $cam_overlays
        if $has_speaker_primary {
            let last_idx = ($n_base - 1)
            $chain ++ [ $"[vbase_($last_idx)][scr_pip]overlay=x='($speaker_primary_x)':y='($speaker_primary_y)':eof_action=pass[vout]" ]
        } else {
            $chain
        }
    }

    let graph = (
        $nodes_common
        ++ $nodes_cam
        ++ $nodes_scr_pip
        ++ $nodes_img_full
        ++ $nodes_img_pip
        ++ $nodes_scr_fold
        ++ $nodes_scr_pip_fold
        ++ $overlays
        | str join ";"
    )
    { graph: $graph, out_label: "vout" }
}
