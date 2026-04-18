#!/usr/bin/env nu
# Concatenate work/intro.mp4, work/body.mp4, work/outro.mp4 into output/final.mp4.
# All three inputs are encoded with matching codec parameters
# in the earlier pipeline stages, so `-c copy` lets us do this without re-encoding.

def main [] {
    mkdir output

    let manifest = [
        "file 'intro.mp4'"
        "file 'body.mp4'"
        "file 'outro.mp4'"
    ] | str join "\n"
    $manifest | save -f work/manifest.txt

    ^ffmpeg -y -f concat -safe 0 -i work/manifest.txt -c copy output/final.mp4
}
