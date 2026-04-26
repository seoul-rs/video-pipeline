# Helpers for generating the body-render filter_complex string.
#
# Input indexing depends on whether a real screen recording exists:
#   non-synthetic: 0 = screen, 1 = speaker, 2.. = images
#   synthetic:     0 = speaker, 1.. = images
# In synthetic mode the lavfi black canvas is gone — the concat'd image
# track is the full-body screen layer.
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
# `screen_synthetic` signals that the talk has no real screen recording
# (only image cues). In that mode there is no `[0:v]` lavfi stand-in: the
# concat'd image track *is* the screen layer, so the speaker shifts to
# input 0 and images start at input 1. Caller (render-body.nu) skips the
# lavfi `-i` accordingly.
export def build-graph [
    cues: list<record>
    layout: record
    body_dur: float
    screen_synthetic: bool = false
]: nothing -> record {
    # Input indexing — see top-of-file comment.
    let screen_offset = (if $screen_synthetic { 0 } else { 1 })
    let speaker_idx = $screen_offset
    let image_input_base = (1 + $screen_offset)
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

    # Routing: which image-track an image cue feeds.
    #   screen-primary / screen-only -> "full" (fills canvas, folded into [scr])
    #   speaker-primary              -> "pip"  (fills PiP, folded into [scr_pip])
    let route_of = { |mode|
        if $mode in ["screen-primary" "screen-only"] { "full" } else if $mode == "speaker-primary" { "pip" } else { null }
    }

    # Image cues get one ffmpeg input each, starting at $image_input_base.
    # Preserve cue order so input indices are stable.
    #
    # `lead_in` flags an entry whose immediately-preceding cue is also an
    # image cue with the same routing — i.e. the cue chains into this one
    # via xfade. Such entries get their input duration extended by
    # `transition` (in render-body.nu) and skip the alpha fade-in (xfade
    # handles the blend). render-body.nu uses the same routing+predecessor
    # test, so the two stay in lockstep.
    let image_entries = ($cues | enumerate | reduce --fold { out: [], k: 0 } { |it, acc|
        let c = $it.item
        if ($c.image? | default null) == null {
            $acc
        } else {
            let routing = (do $route_of $c.mode)
            let lead_in = if $it.index > 0 {
                let p = ($cues | get ($it.index - 1))
                let p_image = ($p.image? | default null)
                let p_routing = (do $route_of $p.mode)
                ($p_image != null) and ($p_routing == $routing) and ($p.to == $c.from)
            } else { false }
            let entry = {
                cue_idx: $it.index
                input_idx: ($image_input_base + $acc.k)
                mode: $c.mode
                routing: $routing
                t1: $c.from
                t2: $c.to
                lead_in: $lead_in
            }
            { out: ($acc.out | append $entry), k: ($acc.k + 1) }
        }
    } | get out)
    # `trail_out` mirrors `lead_in`: true when the next image entry in the
    # same routing is the chronologically-next cue. Drives "skip fade-out
    # on this clip; xfade with the next clip handles the blend."
    let attach_trail = { |entries: list<record>|
        let n = ($entries | length)
        $entries | enumerate | each { |it|
            let i = $it.index
            let e = $it.item
            let trail_out = if $i < ($n - 1) {
                let next = ($entries | get ($i + 1))
                ($next.lead_in) and ($next.cue_idx == ($e.cue_idx + 1))
            } else { false }
            $e | upsert trail_out $trail_out
        }
    }
    let full_image_entries = (do $attach_trail ($image_entries | where routing == "full"))
    let pip_image_entries = (do $attach_trail ($image_entries | where routing == "pip"))

    # Per-mode, per-corner groups. The same windows drive both x
    # (which slides) and y (which steps between top and bottom).
    # Adjacent same-mode same-corner cues fuse into one window so the
    # PiP rests through the seam instead of sliding off and back in
    # — mirrors the merge applied to `merged_base_windows` for cam.
    let screen_primary_x_groups = ($valid_corners | each { |c|
        let windows = (merge-windows ($cs | where mode == "screen-primary" and corner == $c | each { |x| [$x.t1, $x.t2] }))
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.off_x, rest: $spec.rest_x }
    })
    let screen_primary_y_groups = ($valid_corners | each { |c|
        let windows = (merge-windows ($cs | where mode == "screen-primary" and corner == $c | each { |x| [$x.t1, $x.t2] }))
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.y, rest: $spec.y }
    })
    let speaker_primary_x_groups = ($valid_corners | each { |c|
        let windows = (merge-windows ($cs | where mode == "speaker-primary" and corner == $c | each { |x| [$x.t1, $x.t2] }))
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.off_x, rest: $spec.rest_x }
    })
    let speaker_primary_y_groups = ($valid_corners | each { |c|
        let windows = (merge-windows ($cs | where mode == "speaker-primary" and corner == $c | each { |x| [$x.t1, $x.t2] }))
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

    let has_full_imgs = (not ($full_image_entries | is-empty))
    let has_pip_imgs = (not ($pip_image_entries | is-empty))

    # Routing depends on (synthetic, has_imgs):
    #   synthetic + has_imgs:        concat outputs directly to [scr] / [scr_pip];
    #                                no separate base node.
    #   non-synthetic + has_imgs:    [0:v] -> [scr_raw]; concat -> [img_track];
    #                                [scr_raw][img_track]overlay -> [scr].
    #   non-synthetic + no imgs:     [0:v] -> [scr] directly.
    #   synthetic + no imgs:         disallowed by render-body validation.
    let scr_base_label = if $has_full_imgs and (not $screen_synthetic) { "scr_raw" } else { "scr" }
    let scr_pip_base_label = if $has_pip_imgs and (not $screen_synthetic) { "scr_pip_raw" } else { "scr_pip" }
    let full_track_label = if $has_full_imgs and (not $screen_synthetic) { "img_track" } else { "scr" }
    let pip_track_label = if $has_pip_imgs and (not $screen_synthetic) { "img_pip_track" } else { "scr_pip" }

    # In synthetic mode there's no [0:v] — the concat'd image track is the
    # screen layer. Skip the base prep node entirely in that case.
    let nodes_common = (if $screen_synthetic {
        []
    } else {
        [ $"[0:v]setpts=PTS-STARTPTS,fps=($fps),($NORMALIZE_YUV),scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1[($scr_base_label)]" ]
    }) ++ [
        $"[($speaker_idx):v]setpts=PTS-STARTPTS,fps=($fps),($NORMALIZE_YUV),scale=($pip_w):($pip_h),setsar=1,pad=($ppw):($pph):($border):($border):white,format=yuva420p[cam_pip]"
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
        let prep_common = $"[($speaker_idx):v]setpts=PTS-STARTPTS,fps=($fps),($NORMALIZE_YUV),scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1,format=yuva420p"
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
    # In synthetic mode, [scr_pip] (when needed) is produced directly by the
    # concat'd PiP image track — no separate base node from [0:v].
    let nodes_scr_pip = if $has_speaker_primary and (not $screen_synthetic) {
        [ $"[0:v]setpts=PTS-STARTPTS,fps=($fps),($NORMALIZE_YUV),scale=($pip_w):($pip_h),setsar=1,pad=($ppw):($pph):($border):($border):white,format=yuva420p[($scr_pip_base_label)]" ]
    } else {
        []
    }

    # Per-cue image clips: scale + color-convert + clip-local edge fades.
    # Fade-in only on a clip whose preceding cue is *not* a same-routing
    # image — otherwise xfade with the previous clip handles the blend
    # and a separate alpha fade-in would cause a midpoint dip. Same idea
    # for fade-out: applied only at the trailing edge of a run. Inside a
    # run, the second-and-later clips have their input duration extended
    # by `transition` (in render-body.nu) so the xfade overlap doesn't
    # shorten the timeline; the rest of the per-clip math falls out of
    # `clip_dur` so the same fade_out_st formula works for both
    # extended and non-extended clips.
    #
    # zscale runs after scale: the PNG decoder emits RGB with loose tags and
    # zscale fails with "no path between colorspaces" when it sees the raw
    # input directly. Running scale first normalizes the pipe, matching the
    # proven chain in render-intro.nu.
    let clip_prep = { |e: record, kind: string|
        let cue_dur = ($e.t2 - $e.t1)
        let clip_dur = $cue_dur + (if $e.lead_in { $transition } else { 0.0 })
        let needs_fade_in = (not $e.lead_in) and ($e.t1 in $cue_tos)
        let needs_fade_out = (not $e.trail_out) and ($e.t2 in $cue_froms)
        let fade_in = if $needs_fade_in { $",fade=t=in:st=0:d=($transition):alpha=1" } else { "" }
        let fade_out_st = ($clip_dur - $transition)
        let fade_out = if $needs_fade_out { $",fade=t=out:st=($fade_out_st):d=($transition):alpha=1" } else { "" }
        let scale_chain = if $kind == "full" {
            $"scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1"
        } else {
            $"scale=($pip_w):($pip_h),setsar=1,pad=($ppw):($pph):($border):($border):white"
        }
        let label = if $kind == "full" { $"img_clip_($e.cue_idx)" } else { $"img_pip_clip_($e.cue_idx)" }
        $"[($e.input_idx):v]setpts=PTS-STARTPTS,fps=($fps),($scale_chain),($NORMALIZE_SRGB),format=yuva420p($fade_in)($fade_out)[($label)]"
    }
    let nodes_img_clip_full = ($full_image_entries | each { |e| do $clip_prep $e "full" })
    let nodes_img_clip_pip = ($pip_image_entries | each { |e| do $clip_prep $e "pip" })

    # Group consecutive entries into runs. A run is a maximal sequence
    # where every entry after the first has lead_in=true (the prior cue
    # in the source order is also a same-routing image cue that abuts).
    # Within a run, adjacent clips xfade into each other; runs are
    # separated by transparent gap segments in the concat.
    let group_runs = { |entries: list<record>|
        $entries | reduce --fold [] { |e, acc|
            if ($acc | is-empty) {
                [[$e]]
            } else if $e.lead_in {
                let last_run = ($acc | last)
                ($acc | drop 1) | append [($last_run | append $e)]
            } else {
                $acc | append [[$e]]
            }
        }
    }
    let runs_full = (do $group_runs $full_image_entries)
    let runs_pip = (do $group_runs $pip_image_entries)

    # For each run: emit an xfade chain (zero nodes for a length-1 run)
    # and decide the segment label that the concat will splice in.
    # Length 1 -> the clip's own label is the segment.
    # Length N -> chain `[a][b]xfade...[step1]; [step1][c]xfade...[step2]; ...`
    #            with offset = (chain_dur_before - transition) per step,
    #            so the run's output dur equals Σ cue_durs (= run time span).
    let xfade_chain = { |run: list<record>, kind: string|
        let n = ($run | length)
        let clip_label = { |e: record|
            if $kind == "full" { $"img_clip_($e.cue_idx)" } else { $"img_pip_clip_($e.cue_idx)" }
        }
        if $n <= 1 {
            let e = ($run | first)
            { nodes: [], out_label: (do $clip_label $e), dur: ($e.t2 - $e.t1) }
        } else {
            let first_e = ($run | first)
            let prefix = if $kind == "full" { "img_run" } else { "img_pip_run" }
            let init = {
                nodes: []
                chain_dur: ($first_e.t2 - $first_e.t1)
                prev_label: (do $clip_label $first_e)
            }
            let acc = (1..($n - 1) | reduce --fold $init { |i, st|
                let e = ($run | get $i)
                let cue_dur = ($e.t2 - $e.t1)
                let offset = ($st.chain_dur - $transition)
                let is_last = ($i == ($n - 1))
                let out_label = if $is_last {
                    $"($prefix)_($first_e.cue_idx)"
                } else {
                    $"($prefix)_($first_e.cue_idx)_step_($i)"
                }
                let curr = (do $clip_label $e)
                let node = $"[($st.prev_label)][($curr)]xfade=transition=fade:duration=($transition):offset=($offset)[($out_label)]"
                {
                    nodes: ($st.nodes | append $node)
                    chain_dur: ($st.chain_dur + $cue_dur)
                    prev_label: $out_label
                }
            })
            { nodes: $acc.nodes, out_label: $acc.prev_label, dur: $acc.chain_dur }
        }
    }
    let runs_full_built = ($runs_full | each { |r| do $xfade_chain $r "full" })
    let runs_pip_built = ($runs_pip | each { |r| do $xfade_chain $r "pip" })
    let nodes_xfade_full = ($runs_full_built | each { |b| $b.nodes } | flatten)
    let nodes_xfade_pip = ($runs_pip_built | each { |b| $b.nodes } | flatten)

    # Build the run-based segment sequence: gap, run, gap, run, ..., gap.
    # Drop zero-duration gaps (run starts at body t=0 or ends at body_dur,
    # or two runs of different routing share the same time span on the
    # OTHER routing's track). Concat below stitches the surviving
    # segments into one full-body track.
    let build_run_segments = { |built: list<record>, runs: list<list<record>>, gap_prefix: string|
        let n = ($built | length)
        if $n == 0 {
            []
        } else {
            let first_t1 = ($runs | first | first | get t1)
            let init = if $first_t1 > 0.0 {
                [ { kind: "gap", dur: $first_t1, label: $"($gap_prefix)_0" } ]
            } else { [] }
            $built | enumerate | reduce --fold $init { |it, acc|
                let i = $it.index
                let b = $it.item
                let r = ($runs | get $i)
                let with_run = ($acc | append { kind: "run", dur: $b.dur, label: $b.out_label })
                let next_t = if $i == ($n - 1) { $body_dur } else { ($runs | get ($i + 1) | first | get t1) }
                let last_t2 = ($r | last | get t2)
                let gap_dur = ($next_t - $last_t2)
                if $gap_dur > 0.0 {
                    let gap_idx = ($i + 1)
                    $with_run | append { kind: "gap", dur: $gap_dur, label: $"($gap_prefix)_($gap_idx)" }
                } else {
                    $with_run
                }
            }
        }
    }
    let segs_full = (do $build_run_segments $runs_full_built $runs_full "gap_full")
    let segs_pip = (do $build_run_segments $runs_pip_built $runs_pip "gap_pip")

    # Gap source nodes: transparent yuva420p frames at the right size + duration.
    # `colorchannelmixer=aa=0` zeroes the alpha channel after format conversion.
    let nodes_gaps_full = ($segs_full | where kind == "gap" | each { |s|
        $"color=c=black:s=($w)x($h):r=($fps):d=($s.dur),format=yuva420p,colorchannelmixer=aa=0[($s.label)]"
    })
    let nodes_gaps_pip = ($segs_pip | where kind == "gap" | each { |s|
        $"color=c=black:s=($ppw)x($pph):r=($fps):d=($s.dur),format=yuva420p,colorchannelmixer=aa=0[($s.label)]"
    })

    # Concat the segment sequence (gaps + run outputs) into one
    # full-body track, replacing what used to be a 47-deep serial overlay
    # chain. Within each run, xfade chains the image cues; between runs,
    # concat splices in transparent gaps so the screen base shows through.
    let nodes_concat_full = if ($segs_full | is-empty) { [] } else {
        let inputs = ($segs_full | each { |s| $"[($s.label)]" } | str join "")
        let n_segs = ($segs_full | length)
        [ $"($inputs)concat=n=($n_segs):v=1:a=0[($full_track_label)]" ]
    }
    let nodes_concat_pip = if ($segs_pip | is-empty) { [] } else {
        let inputs = ($segs_pip | each { |s| $"[($s.label)]" } | str join "")
        let n_segs = ($segs_pip | length)
        [ $"($inputs)concat=n=($n_segs):v=1:a=0[($pip_track_label)]" ]
    }

    # In non-synthetic mode the concat track lives at [img_track] / [img_pip_track]
    # and is overlaid onto the real screen base. In synthetic mode the concat
    # track *is* [scr] / [scr_pip] (full_track_label == "scr"), so no overlay.
    let nodes_full_overlay = if $has_full_imgs and (not $screen_synthetic) {
        [ $"[($scr_base_label)][($full_track_label)]overlay=0:0:eof_action=pass[scr]" ]
    } else { [] }
    let nodes_pip_overlay = if $has_pip_imgs and (not $screen_synthetic) {
        [ $"[($scr_pip_base_label)][($pip_track_label)]overlay=0:0:eof_action=pass[scr_pip]" ]
    } else { [] }

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
        ++ $nodes_img_clip_full
        ++ $nodes_img_clip_pip
        ++ $nodes_xfade_full
        ++ $nodes_xfade_pip
        ++ $nodes_gaps_full
        ++ $nodes_gaps_pip
        ++ $nodes_concat_full
        ++ $nodes_concat_pip
        ++ $nodes_full_overlay
        ++ $nodes_pip_overlay
        ++ $overlays
        | str join ";"
    )
    { graph: $graph, out_label: "vout" }
}
