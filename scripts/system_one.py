#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-vlm>=0.8.1"]
# ///
"""Triple-gate LiquidAI d1-2B decision layer for herdr-yes-only, on Apple MLX.

Reads visible terminal text from stdin and emits JSON:

{
  "approved": bool,
  "context_sufficient": float,
  "safe_for_automatic_decision": float,
  "response_is_affirmative": float
}

Each question is a d1 `noul`: the ChatML prompt d1 trained on, one forward pass
up to the answer slot, and a softmax over the yes/no tokens there. The calling
Bash plugin sends Enter only when every configured threshold passes.
"""

import argparse
import json
import math
import os
import re
import sys
from pathlib import Path

IM_START = "<|im_start|>"
IM_END = "<|im_end|>"
BREAK = "\u200b"
YES_FORMS = ("yes", "Yes", "YES")
NO_FORMS = ("no", "No", "NO")

QUESTIONS = {
    "context_sufficient": "Is the visible terminal context sufficient to determine the correct response to the pending prompt?",
    "safe_for_automatic_decision": "Is this prompt unambiguous and safe to decide automatically, without destructive, irreversible, privileged, security-sensitive, or poorly understood consequences?",
    "response_is_affirmative": "Is the correct response the affirmative option, such as Yes, Approve, Allow, Confirm, Proceed, Accept, Install, Run, Trust, or Enable?",
}


def plain(tokenizer, text: str) -> str:
    """Break every special token in `text` so the screen cannot close the user turn."""
    names = sorted((n for n in tokenizer.all_special_tokens if len(n) > 1), key=len, reverse=True)
    if not names:
        return text
    return re.sub("|".join(map(re.escape, names)), lambda m: m[0][0] + BREAK + m[0][1:], text)


def single_ids(tokenizer, forms) -> list:
    ids = [tokenizer.encode(f, add_special_tokens=False) for f in forms]
    return sorted({e[0] for e in ids if len(e) == 1})


def chat_lead(tokenizer) -> str:
    """What the ChatML template writes after the assistant header for a non-thinking reply."""
    text = tokenizer.apply_chat_template([{"role": "user", "content": "x"}], add_generation_prompt=True,
                                         tokenize=False, enable_thinking=False)
    head = f"{IM_START}assistant\n"
    if head not in text:
        raise ValueError("not a ChatML chat template")
    return text[text.rindex(head) + len(head):]


def noul_temperature(model_dir: Path) -> float:
    path = model_dir / "calibration.json"
    if not path.exists():
        return 1.0
    d = json.loads(path.read_text())
    return float(d.get("temperatures", {}).get("noul", d.get("default", 1.0)))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=os.environ.get("HERDR_YES_ONLY_D1_MODEL", "LiquidAI/d1-2B-MLX-4bit"))
    parser.add_argument("--min-context", type=float, default=float(os.environ.get("HERDR_YES_ONLY_D1_MIN_CONTEXT_CONFIDENCE", "0.80")))
    parser.add_argument("--min-safety", type=float, default=float(os.environ.get("HERDR_YES_ONLY_D1_MIN_SAFETY_CONFIDENCE", "0.90")))
    parser.add_argument("--min-response", type=float, default=float(os.environ.get("HERDR_YES_ONLY_D1_MIN_RESPONSE_CONFIDENCE", "0.90")))
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("HERDR_YES_ONLY_D1_TIMEOUT_SEC", "5")))
    args = parser.parse_args()

    screen = sys.stdin.read()

    try:
        import mlx.core as mx
        from huggingface_hub import snapshot_download
        from mlx_vlm import load

        model_dir = Path(snapshot_download(args.model))
        model, processor = load(str(model_dir))
        tokenizer = getattr(processor, "tokenizer", processor)

        yes_ids, no_ids = single_ids(tokenizer, YES_FORMS), single_ids(tokenizer, NO_FORMS)
        if not yes_ids or not no_ids:
            raise RuntimeError("tokenizer has no single-token yes/no")

        bos = tokenizer.bos_token if isinstance(tokenizer.bos_token, str) else ""
        lead = chat_lead(tokenizer)
        temperature = noul_temperature(model_dir)
        prefix = f"{bos}{IM_START}user\n{plain(tokenizer, screen)}\n\n\nQUESTION:\n"

        answers = {}
        for name, instructions in QUESTIONS.items():
            prompt = f"{prefix}{instructions}\n\nReply with yes or no only.{IM_END}\n{IM_START}assistant\n{lead}"
            ids = mx.array([tokenizer.encode(prompt, add_special_tokens=False)])
            logits = model.language_model(ids).logits[0, -1, :]
            logz = logits - mx.logsumexp(logits)
            yes = max(logz[i].item() for i in yes_ids) / temperature
            no = max(logz[i].item() for i in no_ids) / temperature
            answers[name] = 1.0 / (1.0 + math.exp(no - yes))

        context = answers["context_sufficient"]
        safety = answers["safe_for_automatic_decision"]
        response = answers["response_is_affirmative"]

        approved = (
            context >= args.min_context
            and safety >= args.min_safety
            and response >= args.min_response
        )

        print(json.dumps({
            "approved": approved,
            "context_sufficient": context,
            "safe_for_automatic_decision": safety,
            "response_is_affirmative": response,
            "model": args.model,
            "thresholds": {
                "context": args.min_context,
                "safety": args.min_safety,
                "response": args.min_response,
            },
        }))
        return 0
    except Exception as exc:
        print(json.dumps({
            "approved": False,
            "error": type(exc).__name__,
            "message": str(exc),
        }))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())