# Bonsai 2 27B (ternary PQ2_0) on an RTX 3080

Local llama.cpp hosting for `prism-ml/Ternary-Bonsai-2-27B-gguf`, tuned for a single
RTX 3080 (10 GB, Ampere sm_86), plus the fix that makes Codex CLI work against it.

| File | What |
|---|---|
| `start-bonsai2-server.ps1` | hosts llama-server: 3080 only, 32K context, `-ub 512` |
| `build-cuda-prism.bat` | builds the PrismML fork, required for PQ2_0/PTQ1_0 tensors |
| `build-cuda.bat` | builds upstream llama.cpp, for ordinary GGUF models |
| `chat-template-bonsai2-codex.jinja` | patched chat template required by Codex CLI |
| `codex/3080.config.example.toml` | Codex profile used by `codex -p 3080` |
| `BONSAI2-SETUP.md` | measurements, tuning notes, Codex root cause |

## Quick start

```powershell
.\build-cuda-prism.bat
hf download prism-ml/Ternary-Bonsai-2-27B-gguf Ternary-Bonsai-2-27B-PQ2_0.gguf --local-dir models
.\start-bonsai2-server.ps1          # terminal 1
codex --yolo -p 3080               # terminal 2
```

Chat UI at http://127.0.0.1:8080, OpenAI API at `/v1`, metrics at `/metrics`.
Copy `codex/3080.config.example.toml` to `~/.codex/3080.config.toml` and add your token.

`llama.cpp/`, `llama.cpp-prism/`, `models/` and `logs/` are build/run artifacts and
are not tracked here; see `.gitignore`.
