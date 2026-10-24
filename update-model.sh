#!/bin/zsh
# Downloads a Hugging Face MLX repo into the project root with aria2c; pick that folder in the app.
#
#   ./update-model.sh                                      # mlx-community/Qwen3-ASR-0.6B-8bit
#   ./update-model.sh mlx-community/Qwen3-ASR-0.6B-4bit
#
# Fetches only what Qwen3ASRModel.load reads, verifies every size against the Hub, and moves the folder
# in only on success.
set -euo pipefail

repo=${1:-mlx-community/Qwen3-ASR-0.6B-8bit}
root=${0:A:h}
target="$root/${repo:t}"
staging="$root/.model-staging"

command -v aria2c >/dev/null || { print -u2 "aria2c not found: brew install aria2"; exit 1; }

# "path<TAB>size" for config, tokenizer files, and every safetensors shard (the index file is not read).
manifest=$(curl -fsSL "https://huggingface.co/api/models/$repo/tree/main" | /usr/bin/python3 -c '
import json, sys
wanted = {"config.json", "vocab.json", "merges.txt", "tokenizer_config.json"}
for entry in json.load(sys.stdin):
    path = entry["path"]
    if entry["type"] == "file" and (path in wanted or path.endswith(".safetensors")):
        print(path, entry["size"], sep="\t")
')
[[ $(print -r -- "$manifest" | grep -c -v '\.safetensors') -eq 4 && "$manifest" == *.safetensors* ]] \
    || { print -u2 "$repo is missing config, tokenizer, or weights:"; print -u2 -r -- "$manifest"; exit 1; }

mkdir -p "$staging"
print -r -- "$manifest" | while IFS=$'\t' read -r file size; do
    print "https://huggingface.co/$repo/resolve/main/$file"
    print "  out=$file"
done | aria2c --input-file=- --dir="$staging" --continue=true --auto-file-renaming=false \
    --max-connection-per-server=16 --split=16 --min-split-size=4M --max-concurrent-downloads=4 \
    --enable-color=false --console-log-level=warn --summary-interval=0 --download-result=hide

print -r -- "$manifest" | while IFS=$'\t' read -r file size; do
    actual=$(stat -f %z "$staging/$file")
    [[ $actual -eq $size && ! -e "$staging/$file.aria2" ]] \
        || { print -u2 "$file: $actual of $size bytes; rerun to resume"; exit 1; }
done

rm -rf "$target"
mv "$staging" "$target"

print "Installed $repo → ${target#$root/}"
