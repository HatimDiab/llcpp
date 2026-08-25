# llcpp

An ollama-style CLI for llama.cpp. Single Python file, stdlib only, no daemon.

```bash
llcpp pull unsloth/Qwen3.8-27B-GGUF:Q6_K_XL
llcpp run  qwen3.8-27b
llcpp list
llcpp rm   qwen3.8-27b
```

## Why not just use ollama

Ollama is easier, but on this hardware it leaves a lot on the table:

- **It cannot do MTP speculative decoding.** On Qwen3.8-27B that is measured at
  55–68% draft acceptance, roughly **2x decode throughput**. `llcpp` detects an
  `MTP/` folder in a repo and wires `--spec-type draft-mtp` automatically.
- **Its Go wrapper costs throughput** — published benchmarks put raw llama.cpp at
  89 tok/s where ollama gets 43 on the same MoE model. `llcpp` execs
  `llama-server` directly and gets out of the way.
- **You keep llama.cpp's full flag surface.** `--ctx`, `--no-vision`, and anything
  else you want to add to `build_cmd`.

## Commands

| | |
|---|---|
| `search <query>` | find models that fit this machine. Plain English works |
| `pull <ref>` | download from Hugging Face. `--no-mtp`, `--no-vision` |
| `run <name> [prompt]` | chat. Auto-pulls and auto-starts. No prompt → REPL |
| `list` | pulled models, with size, features, and which port each is serving on |
| `rm <name>...` | delete weights and deregister |
| `serve <name>` | start a server and leave it up. `--port`, `--ctx` |
| `ps` | running servers |
| `stop <name> \| --all` | shut one down |

## search

```bash
llcpp search qwen3 coder
llcpp search "a fast coding model that fits in 20gb"
llcpp search "best vision model I can run locally"
```

Ranks by download count, then filters hard on what actually fits, and prints an
estimated decode speed for each. Flags show `mtp`, `vision`, `moe`.

**Hardware profile** is auto-detected — chip via `machdep.cpu.brand_string`, RAM
via `hw.memsize`, GPU budget from `iogpu.wired_limit_mb` or the 75% default.
Bandwidth comes from a per-chip table; only the M5 Max entry is vendor-confirmed,
so override with `LLCPP_BANDWIDTH=546` if yours is wrong.

**Speed estimate** is `bandwidth / bytes-per-token * efficiency` (0.70 dense, 0.55
MoE). Validated against this machine: predicted 17 tok/s for Qwen3.8-27B Q6_K_XL,
measured 18 without MTP. MoE models are detected from `30B-A3B`-style names and
estimated on active params, so they show realistically high numbers.

Constraints parsed from plain English: size caps (`under 20gb`, `fits in 32 GB`),
`vision`/`multimodal`, and speed-vs-quality intent (`fast` / `best`). When a query
describes a job but names no model, an intent table steers it at a suitable family
and says so.

### `--llm`: retrieve, then rerank

Hugging Face search matches **repo names only** — a natural sentence literally
returns zero results. So the model is never asked to be the search engine. With a
server running, `--llm` runs a two-stage pipeline:

1. **Expand.** The model turns the request into 2-4 short *name fragments*
   ("starcoder2", "qwen2.5 coder", "deepseek coder") plus constraints. Several
   cheap guesses beat one; a wrong one costs a single HTTP request.
2. **Retrieve.** Those, plus the heuristic query, fan out across both HF endpoints
   (`?search=` and `quicksearch`), unioned and deduped.
3. **Fit.** Enrich with file trees, filter to what runs on this machine.
4. **Rerank.** The model orders the surviving shortlist against the original
   request and gives a one-line reason per pick.

Stage 4 is where a local model actually earns its keep: judging concrete
candidates it can see is far easier than inventing keywords. An earlier version
did it the other way round (model → keywords → search) and returned obscure PHP
fine-tunes for an autocomplete query; the same query now returns
Qwen2.5-Coder-1.5B at ~403 tok/s, top-ranked, "ideal for autocomplete".

Every stage degrades to the heuristic path if the model returns junk. Costs about
10s. `--no-rerank` keeps expansion but skips stage 4.

Other flags: `--vram N` to override the budget, `--all` to include models that do
not fit, `-n` for result count, `--json`, `--no-docker`, `--no-rerank`.

### Portals

Hugging Face is primary. **Docker Hub's `ai/` namespace** (99 curated models, what
`llama-server -dr` pulls) is shown as a secondary section; its tags carry quant and
size directly. ModelScope's public API 404s, and the Ollama registry has no search
endpoint — neither is usable here.

## Model refs

```
unsloth/Qwen3.8-27B-GGUF:UD-Q6_K_XL   explicit
unsloth/Qwen3.8-27B-GGUF:Q6           fuzzy quant → UD-Q6_K
unsloth/Qwen3.8-27B-GGUF              defaults to Q4_K_M
qwen3.8-27b                           local model, or HF search if not pulled
```

Quant matching prefers exact, then shortest prefix, and breaks ties toward
unsloth `UD-` dynamic quants (better quality at the same size). Partial refs
resolve to the *highest-quality* match, so `:Q8` gives you `UD-Q8_K_XL`, not
`Q8_0` — be explicit if you care.

## What it auto-detects

- **MTP heads** (`MTP/mtp-*.gguf`) → speculative decoding, the single biggest
  perf lever on hybrid Qwen models
- **Vision encoders** (`mmproj-*.gguf`) → prefers `F16` over `BF16`, which is the
  safer choice on the Metal backend
- **Split shards** (`*-00001-of-00003.gguf`) → downloads all, passes the first

## Storage

Everything under `$LLAMA_CACHE` (default `~/.cache/llama.cpp`), matching the
`~/.cache/<provider>/` convention:

```
$LLAMA_CACHE/
  models/<org>/<repo>/…      weights, mirroring the HF repo layout
  registry.json              name → files, plus running servers
  logs/<model>.log           llama-server output
```

Because the layout mirrors Hugging Face exactly, you can drop files in by hand and
`llcpp pull` will find them already complete rather than re-downloading.

## Gotcha: vision vs prompt caching

llama-server disables `--cache-reuse` whenever an mmproj is loaded:

```
cache_reuse is not supported by multimodal, it will be disabled
```

For coding assistants that resend the same file context every turn, prefix cache
reuse is usually worth more than image input. Use `llcpp serve <m> --no-vision` to
keep it. Vision is on by default.

## Editor integration

```bash
llcpp serve qwen3.8-27b --port 8080 --ctx 131072
```

Point Continue (or anything OpenAI-compatible) at `http://127.0.0.1:8080/v1`. The
served model id is the name without its quant tag — `qwen3.8-27b`. llama.cpp's own
web UI is at the port root.

## Not implemented

- No idle unload. llama-server holds the model until `llcpp stop`; ollama drops it
  after 5 minutes. Adding that needs a supervisor process.
- No Modelfile equivalent — no custom system prompts or parameter presets baked
  into a named model.
- Single-stream downloads. Fine at ~40 MB/s; no multi-connection acceleration.
- `search` ranking leans on download counts. That favours established repos and
  will under-rank a genuinely better model published last week.
- `--llm` expansion is limited by the local model's knowledge cutoff. Ask for "the
  smartest reasoning model" and it suggests families it knows, so results skew
  older than what is actually state of the art.
- Speed estimates ignore context length. A long prompt shifts the bottleneck from
  weight streaming to KV traffic and the numbers will read high.
