# LocalDictation

On-device speech-to-text for macOS, running Qwen3-ASR on MLX, with a local OpenAI-compatible HTTP server.

## Install

1. Download `LocalDictation.dmg` from the [latest release](https://github.com/Stillmake/LocalDictation/releases/latest) and drag the app to Applications.
2. Download the model (needs `aria2c`: `brew install aria2`):

   ```sh
   curl -fsSL https://raw.githubusercontent.com/Stillmake/LocalDictation/main/update-model.sh | zsh
   ```

   This saves `mlx-community/Qwen3-ASR-0.6B-8bit` to `~/LocalDictation/Qwen3-ASR-0.6B-8bit`. If the model is already there and complete, the script does nothing. If a download is interrupted, rerun the command and it resumes.
3. In the app, choose the folder `~/LocalDictation/Qwen3-ASR-0.6B-8bit`.

To download another model, pass its repo name. To save somewhere else, set `LOCALDICTATION_DIR`:

```sh
curl -fsSL https://raw.githubusercontent.com/Stillmake/LocalDictation/main/update-model.sh | LOCALDICTATION_DIR=~/Models zsh -s -- mlx-community/Qwen3-ASR-0.6B-4bit
```

Files are downloaded from ModelScope, which hosts the same files as Hugging Face's `mlx-community` and is much faster from China.
