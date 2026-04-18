# Helpers for generating the body-render filter_complex string.
#
# Input indexing: 0 = screen, 1 = speaker.
#
# Graph shape:
#   [scr]       screen full-frame
#   [cam]       speaker full-frame (used during swap + solo modes)
#   [cam_pip]   speaker scaled + bordered, for sliding PiP
#   [scr_pip]   screen scaled + bordered, for sliding PiP in swap mode
#
#   [scr][cam_pip]  overlay with multi-corner x/y exprs (pip cues)   -> [v1]
#   [v1][cam]       overlay 0:0 with enable=(swap+solo cues)          -> [v2]   (if any swap/solo)
#   [v2][scr_pip]   overlay with multi-corner x/y exprs (swap cues)   -> [vout] (if any swap)
#
# Cues may declare an optional `corner` field (default "bottom-right").
# Valid: bottom-right, top-right, top-left, bottom-left. The PiP slides
# in horizontally from the nearest canvas edge and rests at the chosen
# corner. Only applies to `pip` and `swap` cues.

export def parse-hms [s: string]: nothing -> float {
    let parts = ($s | split row ":" | each { into float })
    match ($parts | length) {
        3 => ($parts.0 * 3600.0 + $parts.1 * 60.0 + $parts.2)
        2 => ($parts.0 * 60.0 + $parts.1)
        1 => $parts.0
        _ => (error make { msg: $"invalid HH:MM:SS string: ($s)" })
    }
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
    slide_dur: float
    default_off: int
]: nothing -> string {
    let terms = ($groups | each { |g|
        if ($g.windows | is-empty) {
            ""
        } else {
            let between_sum = ($g.windows | each { |w| $"between\(t,($w.0),($w.1))" } | str join "+")
            let env_sum = ($g.windows | each { |w| envelope $w.0 $w.1 $slide_dur } | str join "+")
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

# enable= expression for hard-cut overlay (full-frame camera during
# swap + solo windows).
def windows-enable-expr [windows: list<list<float>>]: nothing -> string {
    $windows
    | each { |w| $"between\(t,($w.0),($w.1))" }
    | str join "+"
}

# Build the complete filter_complex string.
# Returns a record: { graph: string, out_label: string }
export def build-graph [cues: list<record>, layout: record]: nothing -> record {
    let w = ($layout.resolution | get 0)
    let h = ($layout.resolution | get 1)
    let pip_w = ($layout.pip_size | get 0)
    let pip_h = ($layout.pip_size | get 1)
    let margin = $layout.pip_margin
    let slide = ($layout.slide_dur | into float)
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
        if ($mode in ["pip" "swap"]) and ($corner not-in $valid_corners) {
            error make { msg: $"cue corner '($corner)' is invalid. valid: ($valid_corners | str join ', ')" }
        }
        {
            mode: $mode
            corner: $corner
            t1: (parse-hms $c.from)
            t2: (parse-hms $c.to)
        }
    })

    # Build per-mode, per-corner groups. The same windows drive both x
    # (which slides) and y (which steps between top and bottom).
    let pip_x_groups = ($valid_corners | each { |c|
        let windows = ($cs | where mode == "pip" and corner == $c | each { |x| [$x.t1, $x.t2] })
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.off_x, rest: $spec.rest_x }
    })
    let pip_y_groups = ($valid_corners | each { |c|
        let windows = ($cs | where mode == "pip" and corner == $c | each { |x| [$x.t1, $x.t2] })
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.y, rest: $spec.y }
    })
    let swap_x_groups = ($valid_corners | each { |c|
        let windows = ($cs | where mode == "swap" and corner == $c | each { |x| [$x.t1, $x.t2] })
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.off_x, rest: $spec.rest_x }
    })
    let swap_y_groups = ($valid_corners | each { |c|
        let windows = ($cs | where mode == "swap" and corner == $c | each { |x| [$x.t1, $x.t2] })
        let spec = (corner-spec $c $w $h $pip_w $pph $ppw $margin)
        { windows: $windows, off: $spec.y, rest: $spec.y }
    })

    let pip_x = (axis-expr $pip_x_groups $slide $default_off_x)
    let pip_y = (axis-expr $pip_y_groups $slide $default_y)
    let swap_x = (axis-expr $swap_x_groups $slide $default_off_x)
    let swap_y = (axis-expr $swap_y_groups $slide $default_y)

    let swap_windows_all = ($cs | where mode == "swap" | each { |w| [$w.t1, $w.t2] })
    let solo_windows = ($cs | where mode == "solo" | each { |w| [$w.t1, $w.t2] })
    let cam_full_windows = ($swap_windows_all ++ $solo_windows)
    let has_swap = (not ($swap_windows_all | is-empty))

    let nodes_common = [
        $"[0:v]setpts=PTS-STARTPTS,fps=($fps),scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1[scr]"
        $"[1:v]setpts=PTS-STARTPTS,fps=($fps),scale=($pip_w):($pip_h),setsar=1,pad=($ppw):($pph):($border):($border):white,format=yuva420p[cam_pip]"
    ]
    let nodes_cam = if ($cam_full_windows | is-empty) { [] } else {
        [ $"[1:v]setpts=PTS-STARTPTS,fps=($fps),scale=($w):($h):force_original_aspect_ratio=decrease,pad=($w):($h):\(ow-iw)/2:\(oh-ih)/2:black,setsar=1[cam]" ]
    }
    let nodes_scr_pip = if $has_swap {
        [ $"[0:v]setpts=PTS-STARTPTS,fps=($fps),scale=($pip_w):($pip_h),setsar=1,pad=($ppw):($pph):($border):($border):white,format=yuva420p[scr_pip]" ]
    } else {
        []
    }

    let overlay_pip = $"[scr][cam_pip]overlay=x='($pip_x)':y='($pip_y)':eof_action=pass[v1]"

    let overlays = if ($cam_full_windows | is-empty) {
        [ ($overlay_pip | str replace --all "[v1]" "[vout]") ]
    } else if (not $has_swap) {
        let enable = (windows-enable-expr $cam_full_windows)
        [
            $overlay_pip
            $"[v1][cam]overlay=0:0:enable='($enable)':eof_action=pass[vout]"
        ]
    } else {
        let enable = (windows-enable-expr $cam_full_windows)
        [
            $overlay_pip
            $"[v1][cam]overlay=0:0:enable='($enable)':eof_action=pass[v2]"
            $"[v2][scr_pip]overlay=x='($swap_x)':y='($swap_y)':eof_action=pass[vout]"
        ]
    }

    let graph = ($nodes_common ++ $nodes_cam ++ $nodes_scr_pip ++ $overlays | str join ";")
    { graph: $graph, out_label: "vout" }
}
