#!/usr/bin/env python3
"""Prove a pulled model really serves more context than the old 2048 floor.

    python3 tests/long_context.py <model> [--tokens N] [--ctx N] [--no-vision]

Builds a needle-in-a-haystack prompt of at least N tokens (default 4096, twice
the 2048 training context of LLaMA-1-era GGUFs), counts it with the server's own
tokenizer rather than guessing, sends it, and checks the answer came back.

A model whose slot is capped below the prompt fails here instead of silently
truncating, which is the failure this exists to catch: llama.cpp caps the slot at
the model's training context and only says so in the server log.

Needs the model pulled. Starts the server if it is not already up.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

NEEDLE_NAME = "Marguerite Vasquez-Oyelaran"
NEEDLE_CAT = "Tobermory"
FILLER = ("Log entry {i}. The tide came in at dawn and the gulls wheeled over the "
          "breakwater while the lamp turned steadily through the fog, painting the "
          "water with slow bands of light that faded before they reached the rocks.")


def load_llcpp():
    """Import the llcpp script sitting next to this test (it has no .py suffix)."""
    path = Path(__file__).resolve().parent.parent / "llcpp"
    spec = importlib.util.spec_from_loader(
        "llcpp", importlib.machinery.SourceFileLoader("llcpp", str(path)))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def post(port: int, route: str, body: dict, timeout: int = 600) -> dict:
    req = urllib.request.Request(f"http://127.0.0.1:{port}{route}",
                                 json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def n_tokens(port: int, text: str) -> int:
    return len(post(port, "/tokenize", {"content": text}, timeout=120)["tokens"])


def build_prompt(port: int, want: int) -> "tuple[str, int]":
    """Grow the filler until the server's tokenizer agrees we are over `want`."""
    head = (f"IMPORTANT FACT: the lighthouse keeper's name is {NEEDLE_NAME} "
            f"and her cat is called {NEEDLE_CAT}.\n\n")
    tail = ("\nQUESTION: What is the lighthouse keeper's name, and what is her cat "
            "called? Answer in one short sentence.")
    lines, count = [], 0
    while True:
        lines += [FILLER.format(i=len(lines) + n + 1) for n in range(40)]
        prompt = head + "\n".join(lines) + tail
        count = n_tokens(port, prompt)
        if count >= want:
            return prompt, count
        if len(lines) > 20000:                      # refuse to spin forever
            raise SystemExit("could not reach the requested token count")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model")
    ap.add_argument("--tokens", type=int, default=4096,
                    help="minimum prompt size in tokens (default 4096)")
    ap.add_argument("--ctx", type=int, default=None, help="context to start the server with")
    ap.add_argument("--no-vision", action="store_true")
    args = ap.parse_args()

    m = load_llcpp()
    reg = m.load_reg()
    name = m._match_local(args.model, reg, autopull=False)
    port, _ = m.ensure_server(name, reg, args.ctx or m.DEFAULT_CTX,
                              vision=not args.no_vision)

    prompt, count = build_prompt(port, args.tokens)
    print(f"model            {name}")
    print(f"port             {port}")
    print(f"prompt tokens    {count}")
    if count <= 2048:
        print("FAIL: prompt did not exceed 2048 tokens")
        return 1

    try:
        out = post(port, "/v1/chat/completions", {
            "model": name, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 512, "temperature": 0.0, "stream": False,
            # Reasoning models spend the budget thinking and return an empty
            # content, which reads as a recall failure. Ask them not to.
            "chat_template_kwargs": {"enable_thinking": False},
        })
    except urllib.error.HTTPError as e:
        # A slot capped below the prompt shows up here rather than as a wrong answer.
        print(f"FAIL: server rejected the prompt ({e.code}): {e.read()[:300].decode()}")
        return 1

    msg = out["choices"][0]["message"]
    # Some builds still route everything to reasoning_content; the needle counts
    # wherever it lands, since either way the model read the whole prompt.
    reply = " ".join(filter(None, (msg.get("content"), msg.get("reasoning_content")))).strip()
    if not reply:
        print("FAIL: model returned nothing at all")
        return 1
    print(f"reply            {reply[:160]}")

    missing = [n for n in (NEEDLE_NAME, NEEDLE_CAT) if n.lower() not in reply.lower()]
    if missing:
        print(f"FAIL: answer did not recall {', '.join(missing)} — "
              "the prompt was probably truncated")
        return 1
    print(f"PASS: recalled the needle from a {count}-token prompt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
