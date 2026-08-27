# llcpp

An [ollama](https://ollama.com)-style CLI for [llama.cpp](https://github.com/ggml-org/llama.cpp).
Pull GGUF models from Hugging Face, run them, and serve them to your editor —
without a wrapper process sitting between you and the inference.

Single Python file, standard library only, no daemon.

```console
$ llcpp search "fast coding model under 20gb"
Apple M5 Max · 128 GB unified · ~614 GB/s · weight budget 20.0 GB

MODEL                                       QUANT        SIZE  ~TOK/S  FLAGS   PULLS
unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF   IQ4_XS    16.4 GB     206  moe     12.7M
Qwen/Qwen2.5-Coder-7B-Instruct-GGUF         Q4_K_M     4.7 GB      92  —       245k

$ llcpp pull unsloth/Qwen3.8-27B-GGUF:Q6_K_XL
$ llcpp run qwen3.8-27b
```

## Install

```bash
brew install HatimDiab/tap/llcpp
```

That pulls in `llama.cpp` as a dependency. To run from source instead, the script
needs only Python 3.9+ and `llama-server` on `PATH`.

## Why not just use ollama

Ollama is easier. On Apple Silicon it also leaves a lot on the table:

- **It cannot do MTP speculative decoding.** Several recent models ship a
  multi-token-prediction head. llcpp finds it and wires it up, which on
  Qwen3.8-27B measured 55–68% draft acceptance — roughly **18 → 29-38 tok/s**.
- **Its wrapper costs throughput.** Published benchmarks put raw llama.cpp at
  89 tok/s where ollama gets 43 on the same MoE model. llcpp starts
  `llama-server` directly and gets out of the way.
- **You keep llama.cpp's whole flag surface**, rather than whatever a wrapper
  chose to expose.

What you give up: no idle unload, no Modelfile equivalent. See
[Limitations](#limitations).

## Commands

| | |
|---|---|
| `search <query>` | find models that fit this machine; plain English works |
| `pull <ref>` | download a model, plus its MTP head and vision encoder |
| `run <name> [prompt]` | chat; starts the server if needed. No prompt → REPL |
| `serve <name>` | start a server and leave it up, for editors |
| `list` | what is downloaded |
| `ps` | what is running |
| `stop <name>` or `--all` | shut a server down |
| `rm <name>...` | delete weights |
| `help [command\|topic]` | detail on anything |

The built-in help goes further than this table:

```bash
llcpp help            # overview
llcpp help search     # one command, with examples
llcpp help quants     # concepts: refs, quants, mtp, hardware, storage, editors
```

## Naming models

```
unsloth/Qwen3.8-27B-GGUF:UD-Q6_K_XL   exact repo and quant
unsloth/Qwen3.8-27B-GGUF:Q6           fuzzy quant → UD-Q6_K
unsloth/Qwen3.8-27B-GGUF              no quant → Q4_K_M
qwen3.8-27b                           a model you already pulled
qwen3-coder                           not local → Hugging Face is searched
```

Matching prefers an exact hit, then the shortest prefix, and breaks ties toward
Unsloth `UD-` dynamic quants, which are better at the same size. A partial ref
resolves to the *highest-quality* match, so `:Q8` gives `UD-Q8_K_XL`, not `Q8_0`.

## Auto-detection

Three things are picked up from a repo without being asked for:

- **MTP heads** (`MTP/mtp-*.gguf`) → `--spec-type draft-mtp`, the single largest
  speed lever on models that have one
- **Vision encoders** (`mmproj-*.gguf`) → prefers `F16` over `BF16`, the safer
  choice on Metal
- **Split shards** (`*-00001-of-00003.gguf`) → all downloaded, first one passed

## search

Results are filtered to what actually runs on your machine, and annotated with an
estimated decode speed.

**Hardware profile** comes from `machdep.cpu.brand_string`, `hw.memsize`, and
`iogpu.wired_limit_mb` (or the 75% macOS default). The weight budget leaves
headroom for the KV cache; override it with `--vram N`.

**Speed estimate** is `bandwidth / bytes-per-token × efficiency`, with 0.70 for
dense models and 0.55 for MoE. Calibrated on an M5 Max: predicted 17 tok/s for
Qwen3.8-27B Q6_K_XL against 18 measured. MoE models are detected from `30B-A3B`
naming and estimated on *active* parameters, so they rank realistically instead
of looking slow.

Bandwidth comes from a per-chip table, of which only the M5 Max entry is
vendor-confirmed. Set `LLCPP_BANDWIDTH=<GB/s>` if yours is wrong.

**Plain English** is parsed for size caps (`under 20gb`), modality (`vision`),
and intent (`fast` vs `best`). When a query describes a job but names no model,
an intent table steers it at a suitable family and says so.

### `--llm`: retrieve, then rerank

Hugging Face search matches **repo names only** — a natural sentence returns zero
results. So the model is never asked to be the search engine. With a server
running, `--llm` runs four stages:

1. **Expand** — the model turns the request into 2–4 short *name fragments*
   (`starcoder2`, `qwen2.5 coder`, `deepseek coder`) plus constraints. Several
   cheap guesses beat one, and a wrong one costs a single HTTP request.
2. **Retrieve** — those, plus the heuristic query, fan out across both Hugging
   Face search endpoints, unioned and deduped.
3. **Fit** — enrich with file trees, filter to what runs here.
4. **Rerank** — the model orders the survivors against the original request and
   gives a one-line reason for each.

Stage 4 is where a local model earns its keep: judging concrete candidates it can
see is far easier than inventing keywords. An earlier version did it the other
way round, and returned obscure PHP fine-tunes for an autocomplete query; the
same query now returns Qwen2.5-Coder-1.5B at ~403 tok/s, "ideal for autocomplete".

Every stage falls back to the heuristic path if the model returns junk. Costs
about 10 seconds.

### Portals

Hugging Face is primary. **Docker Hub's `ai/` namespace** — 99 curated models,
what `llama-server -dr` pulls from — appears as a secondary section. ModelScope's
public API returns 404, and the Ollama registry has no search endpoint.

## Editors

```bash
llcpp serve qwen3.8-27b --port 8080 --ctx 131072
```

OpenAI-compatible API at `/v1`, llama.cpp's own web UI at the root. The served
model id is the short name without its quant tag.

`llcpp help editors` has a working Continue config and two caveats worth reading:
Cursor's own base-URL override proxies through Cursor's servers and cannot reach
`127.0.0.1`, and loading a vision encoder makes llama-server disable prompt-cache
reuse — which for coding is usually the worse trade.

That second one has a one-flag fix. If the model shipped an `mmproj` you do not
need, skip it and keep cache reuse:

```bash
llcpp serve qwen3.8-27b --port 8080 --no-vision
```

`serve` and `run` both take `--no-vision`; `pull --no-vision` skips downloading
the encoder in the first place. When a pulled model has an `mmproj` that is being
left out, startup says so (`no vision, cache-reuse on`).

## Older GGUFs

Models that ship without a chat template fall back to ChatML, which is wrong for
anything trained on Alpaca- or Vicuna-style prompts — the stop token never fires
and `<|im_end|>` leaks into replies. Override it:

```bash
llcpp run some-old-30b --chat-template vicuna          # a built-in name
llcpp run some-old-30b --chat-template "$(cat tpl.j2)" # or a jinja template
```

A bare name is passed to llama.cpp as a built-in; anything containing jinja
syntax is passed as a literal template.

Short-context models are the other half of this. llcpp caps nothing itself, but
llama.cpp caps the slot at the model's training context, and llcpp defaults to
`--no-context-shift` — good for coding, wrong for long-form generation that runs
past the window. `--context-shift` slides it instead of stopping.

## Storage

```
$LLAMA_CACHE/                    default ~/.cache/llama.cpp
  models/<org>/<repo>/…          weights, mirroring the Hugging Face repo layout
  registry.json                  what is pulled, and what is running
  logs/<model>.log               llama-server output
```

Because the layout mirrors Hugging Face exactly, you can drop files in by hand
and `pull` will find them already complete instead of re-downloading.

### Interrupted downloads

Ctrl-C keeps what has transferred. `list` shows it under **unfinished**, and
pulling the same model again asks what to do rather than silently continuing a
days-old partial:

```console
$ llcpp pull TheBloke/WizardLM-...-30B-GGUF:Q8_0
partial download found: 1.3 GB of 34.6 GB (3.8%), interrupted 2 hours ago
  resume? [Y/r/q]
```

`y` continues, `r` discards and starts over, `q` leaves it untouched. Pass
`--resume` or `--restart` to answer in advance; anything non-interactive resumes
by default so scripts never block. `llcpp rm <name>` throws a partial away.

A dropped connection mid-transfer is retried automatically with backoff — only a
deliberate interrupt produces a partial you get asked about.

Environment: `LLAMA_CACHE`, `HF_TOKEN`, `HF_HOME`, `LLCPP_BANDWIDTH`, `NO_COLOR`.

## Limitations

- **No idle unload.** llama-server holds the model until `llcpp stop`; ollama
  drops it after five minutes. Adding that needs a supervisor process.
- **No Modelfile equivalent** — no system prompts or parameter presets baked into
  a named model.
- **Single-stream downloads.** Fine at ~40 MB/s; no multi-connection acceleration.
- **`search` ranking leans on download counts**, which favours established repos
  and under-ranks a genuinely better model published last week.
- **`--llm` expansion is bounded by the local model's knowledge cutoff.** Ask for
  "the smartest reasoning model" and it proposes families it knows, so results
  skew older than the actual state of the art.
- **Speed estimates ignore context length.** At long prompts the bottleneck moves
  from streaming weights to KV traffic, and the real number will be lower.

## Requirements

Python 3.9+ and `llama-server` on `PATH`. Hardware detection and the speed model
are macOS/Apple Silicon specific; everything else is portable, and elsewhere
`search` simply omits the tok/s column.

## License

MIT — see [LICENSE](LICENSE).

llcpp invokes `llama-server` as a separate process and neither links nor bundles
llama.cpp, which is independently MIT licensed by the ggml authors.
