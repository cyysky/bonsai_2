# Bonsai 2 27B (ternary PQ2_0) on the RTX 3080

Hosting notes for this machine: RTX 3080 (10 GB) + RTX 3060 (12 GB), 64 GB RAM,
12 logical / 6 physical cores, CUDA 12.9, MSVC 2022 17.14, driver 591.86.

## Why the PrismML fork is required

`Ternary-Bonsai-2-27B-PQ2_0.gguf` stores weights in Prism-private tensor types
(`GGML_TYPE_PQ2_0 = 142`, `GGML_TYPE_PTQ1_0 = 143`) in a rotated basis, and the
matching activation transform only exists in the PrismML llama.cpp fork. Stock
llama.cpp refuses these files as an unknown type, which is the safe failure.

| Build | Path | Purpose |
|---|---|---|
| upstream b11118 | `llama.cpp\build\bin` | ordinary GGUF models, `build-cuda.bat` |
| fork prism-b10709 (bdc23b56b) | `llama.cpp-prism\build\bin` | Bonsai 2, `build-cuda-prism.bat` |

Both are built the same way: MSVC 2022 + Ninja + CUDA 12.9, `CMAKE_CUDA_ARCHITECTURES=86`
(Ampere, matching both cards), AVX2 CPU backend. The fork's HEAD is an Ampere-specific
CUDA commit ("branch-free PTQ1_0 MMQ tile loader and full Ampere tile table").

## Files

| Path | What |
|---|---|
| `models\Ternary-Bonsai-2-27B-PQ2_0.gguf` | language model, 6.71 GiB (2.13 bpw) |
| `models\Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` | vision tower, optional, 0.63 GB |
| `start-bonsai2-server.ps1` | hosts llama-server tuned for the 3080 |
| `chat-template-bonsai2-codex.jinja` | patched chat template, needed by Codex CLI |

## Run

```powershell
.\start-bonsai2-server.ps1                  # text-only, 32K context, 3080 only
$env:BONSAI_CTX=65536; $env:BONSAI_KV_Q8=1; .\start-bonsai2-server.ps1   # 64K context
$env:BONSAI_VISION=1; .\start-bonsai2-server.ps1   # + image input (needs VRAM headroom)
.\start-bonsai2-server.ps1 --reasoning-budget 2048    # pass-through args
```

Then: chat UI at http://127.0.0.1:8080, OpenAI API at `/v1`, Prometheus metrics at `/metrics`.
Set `BONSAI_HOST=0.0.0.0` to serve the LAN; there is no API key by default.

## Codex CLI

`codex --yolo -p 3080` uses `~/.codex/3080.config.toml`, which points at this
server with `wire_api = "responses"`. That failed with `Reconnecting... 5/5` and a
generic "high demand" message, which masks the real HTTP 500:

```
Jinja Exception: System message must be at the beginning.
```

### Why it failed

Two things in the Responses -> Chat Completions converter do not match the model's
template:

1. **Non-leading system messages.** Codex sends `instructions` (its 17 KB system
   prompt) plus a `developer` input item. The converter emits `instructions` as a
   system message, appends the input items, and llama.cpp rewrites `developer` to
   `system` (`workaround::map_developer_role_to_system`). The template then sees
   `[system, system, user, user]` and raises, because it only accepts a system
   message at index 0.
2. **Unsupported `reasoning_effort`.** The template accepts only
   `xhigh`/`medium`/`low` and raises otherwise. Codex's default
   (`reasoning effort: none`) is not sent as a field, so the template fell back to
   `xhigh`; a `minimal` or `high` setting would raise.

`chat-template-bonsai2-codex.jinja` is the GGUF template with two changes:

- every `system`/`developer` message is merged into one leading system block, and
  the per-message loop skips them instead of raising;
- unknown `reasoning_effort` values are clamped (`none`/`minimal`/`off` -> `low`,
  anything else -> `xhigh`) instead of raising.

Everything else, including the `<tool_call>`/`<function=`/`<parameter=` markers that
llama.cpp uses to select its Qwen3-Coder tool parser, is untouched. The script
passes the file with `--chat-template-file` by default; `BONSAI_TEMPLATE=off`
restores the GGUF template (and breaks Codex).

### Usage

```powershell
.\start-bonsai2-server.ps1        # in one terminal
codex --yolo -p 3080             # in another
```

Verified end to end: plain replies, `exec_command` tool calls, tool output replay,
reasoning round-trips, and a real fix-and-test task in a scratch repo.

`3080.config.toml` sets `model_reasoning_effort = "low"`. Codex only sends a
`reasoning.effort` field when it is configured, and with the field absent the
template defaults to `xhigh`, which asks the model to think hard on every turn.
At ~50 tok/s decode that is the dominant latency term, so `low` is the default here;
raise it to `medium` for harder work. Codex warns `Model metadata for
`bonsai2-27b` not found` and falls back to generic metadata, which is harmless.

### Known limits

- Codex also advertises non-function Responses tools (`namespace`, `web_search`).
  The converter logs `unsupported Responses tool type ... skipped` and drops them, so
  those built-ins are unavailable; the function tools all work.
- `previous_response_id` is rejected by the converter, but Codex sends the full
  conversation each turn, so this has not been hit.
- Thinking still consumes output tokens. If a request looks truncated, cap it with
  `--reasoning-budget N` or raise `model_reasoning_effort`.

## Measured on this machine (RTX 3080 alone, `-ngl 999 -fa on`)

Weights 6.87 GiB resident, FP16 KV cache ~64 KiB/token (hybrid attention: only ~25% of
blocks are full attention), so context dominates the VRAM budget.

| Config | pp512 | pp4096 | tg128 | VRAM at load |
|---|---|---|---|---|
| `-b 2048 -ub 512`, f16 KV, **default** | 1233.6 | 1197.0 | 61.1 | 9186 MiB @ 32K |
| `-b 2048 -ub 1024` | 1211.9 | 1194.4 | 60.5 | |
| `-b 2048 -ub 2048` | 1189.9 | 1176.0 | 59.8 | |
| `-b 4096 -ub 512` | 1161.2 | | 59.6 | |
| `-b 2048 -ub 512`, q8_0 KV | 1157.9 | | 58.9 | 9560 MiB @ 64K |
| `-b 2048 -ub 512`, q8_0 K + f16 V | 408.0 | | 42.7 | never mix |

Load time: `--load-mode mmap` 7.2 s, `none` 5.3 s, `dio` 5.3 s.

### What the numbers say

- **`-ub 512` is the sweet spot.** Bigger ubatch costs both prefill and decode here,
  unlike the usual "raise `-ub` for prefill" advice. The Ampere tile table already keeps
  the kernels fed at 512.
- **`-b 2048` beats `-b 4096`.** Keep the logical batch at the default.
- **Never quantize only K.** `-ctk q8_0 -ctv f16` collapses to 408 tok/s prefill.
  Quantize both or neither.
- **q8_0 KV is the only way past 32K** on a 10 GB card: it halves KV to ~32 KiB/token
  (32K -> 64K context) for ~6% prefill and ~4% decode.
- **Load mode `none`/`dio` shaves ~2 s** off startup vs mmap. `dio` also keeps the
  6.7 GiB file out of the page cache entirely.

### Context budget

| Context | KV (f16) | KV (q8_0) | VRAM with weights |
|---|---|---|---|
| 32768 | 2 GiB | 1 GiB | 9186 MiB (f16) |
| 65536 | 4 GiB | 2 GiB | 9560 MiB (q8_0) |

Both fit; 64K with f16 KV does not. The 3060 stays free (its 12 GB are untouched
because the script pins `--device CUDA0`), so a second instance could be pointed at it.

## Behaviour notes

- **Thinking is on by default and is verbose.** A small `max_tokens` is consumed entirely
  by reasoning and the visible `content` comes back empty. Cap it per request with
  `--reasoning-budget N` or budget more tokens on the client.
- **Prompt cache works across turns.** The server reports `cache_n` and picks the slot by
  LCP similarity, so follow-up turns only prefill the new suffix.
- **Vision costs ~0.9 GiB of VRAM** when the projector is offloaded, which does not fit
  alongside a 32K context on this card. Use `BONSAI_MMPROJ_CPU=1` or a smaller
  `BONSAI_CTX` for image input.
- The script pins the 3080 by name (`BONSAI_GPU=3080`) because device order is not
  stable across reboots; letting the 3060 get picked would split the model.
