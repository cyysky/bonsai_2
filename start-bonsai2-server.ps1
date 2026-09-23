#Requires -Version 5.1
<#
  Hosts Bonsai 2 27B (ternary PQ2_0) with llama-server, tuned to maximise
  inference on a single RTX 3080 (10 GB, Ampere sm_86).

  Bonsai 2 needs the PrismML llama.cpp fork: stock llama.cpp rejects the
  PQ2_0/PTQ1_0 tensor types. Binaries come from .\build-cuda-prism.bat.

  Defaults target the 3080 alone and are overridable by environment variables:
    BONSAI_GPU=3080            GPU name substring used to pick the device
    BONSAI_NGL=999             layers offloaded (999 = all)
    BONSAI_CTX=32768           context per slot, in tokens
    BONSAI_BATCH=2048           logical batch (prompt processing)
    BONSAI_UBATCH=512           physical batch; lower it if VRAM is tight
    BONSAI_THREADS=<physical>   CPU threads
    BONSAI_KV_Q8=1              store KV cache in q8_0 (halves KV VRAM, ~6% slower)
    BONSAI_LOAD_MODE=none        auto|none|mmap|mlock|dio (none/dio load ~2s faster)
    BONSAI_VISION=1             load the vision projector (image input)
    BONSAI_MMPROJ_CPU=1         keep the vision projector in system RAM
    BONSAI_REASONING_BUDGET=N   cap thinking tokens per request
    BONSAI_TEMPLATE=<path|off>  chat template to use; default is the patched
                                chat-template-bonsai2-codex.jinja, 'off' falls back
                                to the template baked into the GGUF (see Codex note)
    BONSAI_HOST=0.0.0.0         bind address (default 127.0.0.1)
    BONSAI_PORT=8080             listen port
    BONSAI_TEMP / BONSAI_TOP_P / BONSAI_TOP_K / BONSAI_MIN_P

  Any remaining arguments are passed straight through to llama-server.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ExtraArgs
)

$ErrorActionPreference = "Stop"

$Root     = $PSScriptRoot
$Bin      = Join-Path $Root "llama.cpp-prism\build\bin\llama-server.exe"
$ModelDir = Join-Path $Root "models"
$Model    = Join-Path $ModelDir "Ternary-Bonsai-2-27B-PQ2_0.gguf"
$Mmproj   = Join-Path $ModelDir "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"

# The GGUF template raises unless every system message is the first message, but the
# OpenAI Responses API converter emits `instructions` as system and then replays the
# caller's developer/system items, so Codex CLI hits "System message must be at the
# beginning." (HTTP 500). The patched template merges those into one leading block
# and clamps unsupported reasoning_effort values instead of raising.
$DefaultTemplate = Join-Path $Root "chat-template-bonsai2-codex.jinja"

$HostAddress = if ($env:BONSAI_HOST) { $env:BONSAI_HOST } else { "127.0.0.1" }
$Port        = if ($env:BONSAI_PORT) { [int]$env:BONSAI_PORT } else { 8080 }
$GpuName     = if ($env:BONSAI_GPU) { $env:BONSAI_GPU } else { "3080" }
$Ngl         = if ($env:BONSAI_NGL) { $env:BONSAI_NGL } else { "999" }
$Ctx         = if ($env:BONSAI_CTX) { [int]$env:BONSAI_CTX } else { 32768 }
$Batch       = if ($env:BONSAI_BATCH) { $env:BONSAI_BATCH } else { "2048" }
$UBatch      = if ($env:BONSAI_UBATCH) { $env:BONSAI_UBATCH } else { "512" }

foreach ($required in @($Bin, $Model)) {
    if (-not (Test-Path $required)) {
        Write-Host "[ERR] Not found: $required" -ForegroundColor Red
        Write-Host "      Run .\build-cuda-prism.bat and download the model first." -ForegroundColor Yellow
        exit 1
    }
}

try {
    $null = Invoke-WebRequest -Uri "http://$HostAddress`:$Port/health" -TimeoutSec 2 -UseBasicParsing
    Write-Host "[ERR] Something already answers on http://$HostAddress`:$Port" -ForegroundColor Red
    exit 1
} catch {}

# The llama-server and ggml-cuda DLLs sit next to the executable.
$env:Path = "$(Split-Path $Bin -Parent);$env:Path"

# Physical cores, not logical ones: SMT siblings only add contention here.
$Threads = if ($env:BONSAI_THREADS) { $env:BONSAI_THREADS } else {
    (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
}

# Pin the 3080 explicitly: device order is not guaranteed across reboots,
# and letting the 3060 get picked would split the model over two 10-12 GB cards.
$Device = if ($env:BONSAI_DEVICE) { $env:BONSAI_DEVICE } else {
    $listing = & $Bin --list-devices 2>&1 | Out-String
    $found = [regex]::Match($listing, "(?m)^\s*(CUDA\d+):\s*.*$([regex]::Escape($GpuName))")
    if ($found.Success) { $found.Groups[1].Value } else {
        Write-Host "[WARN] No CUDA device matching '$GpuName'; falling back to CUDA0." -ForegroundColor Yellow
        "CUDA0"
    }
}

$ServerArgs = @(
    "-m", $Model,
    "--alias", "bonsai2-27b",
    "--host", $HostAddress,
    "--port", "$Port",
    "--device", $Device,
    "-ngl", $Ngl,
    "-fa", "on",
    "-c", "$Ctx",
    "-b", $Batch,
    "-ub", $UBatch,
    "-t", "$Threads",
    "-np", "1",
    "--jinja",
    "--metrics"
)

$Template = if ($env:BONSAI_TEMPLATE) { $env:BONSAI_TEMPLATE } else { $DefaultTemplate }
if ($Template -ne "off") {
    if (Test-Path $Template) {
        $ServerArgs += @("--chat-template-file", $Template)
    } else {
        Write-Host "[WARN] Chat template not found: $Template" -ForegroundColor Yellow
        Write-Host "       Codex CLI will fail with 'System message must be at the beginning.'" -ForegroundColor Yellow
    }
}

$LoadMode = if ($env:BONSAI_LOAD_MODE) { $env:BONSAI_LOAD_MODE } else { "none" }
$ServerArgs += @("-lm", $LoadMode)
if ($env:BONSAI_KV_Q8 -eq "1") { $ServerArgs += @("-ctk", "q8_0", "-ctv", "q8_0") }
if ($env:BONSAI_REASONING_BUDGET) { $ServerArgs += @("--reasoning-budget", $env:BONSAI_REASONING_BUDGET) }

# Sampling defaults from the model card (thinking mode). They already travel in
# the GGUF metadata; passing them makes the behaviour explicit and overridable.
$ServerArgs += @(
    "--temp",   $(if ($env:BONSAI_TEMP)  { $env:BONSAI_TEMP }  else { "1.0" }),
    "--top-p",  $(if ($env:BONSAI_TOP_P) { $env:BONSAI_TOP_P } else { "0.95" }),
    "--top-k",  $(if ($env:BONSAI_TOP_K) { $env:BONSAI_TOP_K } else { "20" }),
    "--min-p",  $(if ($env:BONSAI_MIN_P) { $env:BONSAI_MIN_P } else { "0.0" })
)

# The vision tower costs ~0.9 GiB of VRAM, so it stays opt-in on a 10 GB card.
if ($env:BONSAI_VISION -eq "1") {
    if (Test-Path $Mmproj) {
        $ServerArgs += @("--mmproj", $Mmproj)
        if ($env:BONSAI_MMPROJ_CPU -eq "1") { $ServerArgs += "--no-mmproj-offload" }
        if (-not $env:BONSAI_IMAGE_MAX_TOKENS) { $ServerArgs += @("--image-max-tokens", "1024") }
    } else {
        Write-Host "[WARN] BONSAI_VISION=1 but $Mmproj is missing; continuing text-only." -ForegroundColor Yellow
    }
}
if ($env:BONSAI_IMAGE_MAX_TOKENS) { $ServerArgs += @("--image-max-tokens", $env:BONSAI_IMAGE_MAX_TOKENS) }

$KvBytes = $Ctx * 64KB
if ($env:BONSAI_KV_Q8 -eq "1") { $KvBytes = $KvBytes / 2 }
$KvGiB = [math]::Round($KvBytes / 1GB, 2)
$KvLabel = if ($env:BONSAI_KV_Q8 -eq "1") { "q8_0" } else { "FP16" }
Write-Host "Bonsai 2 27B (PQ2_0) on llama-server" -ForegroundColor Cyan
Write-Host "  device   : $Device ($GpuName), -ngl $Ngl, flash attention on"
Write-Host "  context  : -c $Ctx (~$KvGiB GiB $KvLabel KV), -np 1"
Write-Host "  batches  : -b $Batch -ub $UBatch, threads $Threads"
Write-Host "  load mode: $LoadMode"
if ($Template -eq "off") {
    Write-Host "  template : GGUF default (Codex CLI incompatible)" -ForegroundColor Yellow
} else {
    Write-Host "  template : $(Split-Path $Template -Leaf)"
}
Write-Host "  endpoint : http://$HostAddress`:$Port  (chat UI, /v1 OpenAI API, /metrics)"

& $Bin @ServerArgs @ExtraArgs
exit $LASTEXITCODE
