cue := "cue.toml"

# Full end-to-end render: intro + body + outro, concatenated to output/final.mp4
default: render

render: intro body outro concat

# Render only the intro card
intro:
    nu scripts/render-intro.nu {{cue}}

# Render the body (PiP composite or rescaled screen)
body:
    nu scripts/render-body.nu {{cue}}

# Render the outro card
outro:
    nu scripts/render-outro.nu {{cue}}

# Concat intro + body + outro into output/final.mp4
concat:
    nu scripts/concat.nu {{cue}}

# Wipe intermediates and final output
clean:
    rm -rf work output
    mkdir -p work output

# Show available recipes
list:
    @just --list
