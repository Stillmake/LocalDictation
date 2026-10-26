#!/bin/zsh
# Downloads an MLX repo from ModelScope into ~/.local/share/LocalDictation with aria2c; pick that folder in the app.
#
#   curl -fsSL https://raw.githubusercontent.com/Stillmake/LocalDictation/main/update-model.sh | zsh
#   curl -fsSL https://raw.githubusercontent.com/Stillmake/LocalDictation/main/update-model.sh | zsh -s -- mlx-community/Qwen3-ASR-0.6B-4bit
#   LOCALDICTATION_DIR=/path/to/models ./update-model.sh
#
# Fetches only what Qwen3ASRModel.load reads, verifies every size against ModelScope, skips a model already
# installed intact, and moves the folder in only on success.
set -euo pipefail

repo=${1:-mlx-community/Qwen3-ASR-0.6B-8bit}
root=${LOCALDICTATION_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/LocalDictation}
target="$root/${repo:t}"
staging="$root/.staging-${repo:t}"

command -v aria2c >/dev/null || { print -u2 "aria2c not found: brew install aria2"; exit 1; }

# "path<TAB>size" for config, tokenizer files, and every safetensors shard (the index file is not read).
# ModelScope mirrors mlx-community byte for byte and is far faster than the Hub's US CDN from China.
manifest=$(curl -fsSL "https://modelscope.cn/api/v1/models/$repo/repo/files?Recursive=true" | /usr/bin/python3 -c '
import json, sys
wanted = {"config.json", "vocab.json", "merges.txt", "tokenizer_config.json"}
for entry in json.load(sys.stdin)["Data"]["Files"]:
    path = entry["Path"]
    if entry["Type"] == "blob" and (path in wanted or path.endswith(".safetensors")):
        print(path, entry["Size"], sep="\t")
')
[[ $(print -r -- "$manifest" | grep -c -v '\.safetensors') -eq 4 && "$manifest" == *.safetensors* ]] \
    || { print -u2 "$repo is missing config, tokenizer, or weights:"; print -u2 -r -- "$manifest"; exit 1; }

# Succeeds when every manifest file in $1 has its expected size and no unfinished aria2 control file.
complete() {
    print -r -- "$manifest" | while IFS=$'\t' read -r file size; do
        [[ -f "$1/$file" && $(stat -f %z "$1/$file") -eq $size && ! -e "$1/$file.aria2" ]] || return 1
    done
}

complete "$target" && { print "Already installed: $target"; exit 0; }

mkdir -p "$staging"
print -r -- "$manifest" | while IFS=$'\t' read -r file size; do
    print "https://modelscope.cn/models/$repo/resolve/master/$file"
    print "  out=$file"
done | aria2c --input-file=- --dir="$staging" --continue=true --auto-file-renaming=false \
    --max-connection-per-server=16 --split=16 --min-split-size=1M --max-concurrent-downloads=4 \
    --lowest-speed-limit=50K --max-tries=0 --retry-wait=1 --file-allocation=none \
    --enable-color=false --console-log-level=warn --summary-interval=0 --download-result=hide

complete "$staging" || { print -u2 "Download incomplete in $staging; rerun to resume"; exit 1; }

rm -rf "$target"
mv "$staging" "$target"

print "Installed $repo → $target"
