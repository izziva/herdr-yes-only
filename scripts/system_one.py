#!/usr/bin/env python3
"""Triple-gate LiquidAI d1-2B decision layer for herdr-yes-only.

Reads visible terminal text from stdin and emits JSON:

{
  "approved": bool,
  "context_sufficient": float,
  "safe_for_automatic_decision": float,
  "response_is_affirmative": float
}

All three questions are submitted in one system_one request. The calling Bash
plugin sends Enter only when every configured threshold passes.
"""

import argparse
import json
import os
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=os.environ.get("HERDR_YES_ONLY_D1_MODEL", "LiquidAI/d1-2B"))
    parser.add_argument("--min-context", type=float, default=float(os.environ.get("HERDR_YES_ONLY_D1_MIN_CONTEXT_CONFIDENCE", "0.80")))
    parser.add_argument("--min-safety", type=float, default=float(os.environ.get("HERDR_YES_ONLY_D1_MIN_SAFETY_CONFIDENCE", "0.90")))
    parser.add_argument("--min-response", type=float, default=float(os.environ.get("HERDR_YES_ONLY_D1_MIN_RESPONSE_CONFIDENCE", "0.90")))
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("HERDR_YES_ONLY_D1_TIMEOUT_SEC", "5")))
    args = parser.parse_args()

    screen = sys.stdin.read()

    try:
        import torch
        from transformers import AutoModel

        device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
        dtype = torch.float32 if device == "cpu" else torch.bfloat16

        model = AutoModel.from_pretrained(args.model, trust_remote_code=True, dtype=dtype).to(device)

        questions = {
            "context_sufficient": {
                "type": "noul",
                "instructions": "Is the visible terminal context sufficient to determine the correct response to the pending prompt?",
            },
            "safe_for_automatic_decision": {
                "type": "noul",
                "instructions": "Is this prompt unambiguous and safe to decide automatically, without destructive, irreversible, privileged, security-sensitive, or poorly understood consequences?",
            },
            "response_is_affirmative": {
                "type": "noul",
                "instructions": "Is the correct response the affirmative option, such as Yes, Approve, Allow, Confirm, Proceed, Accept, Install, Run, Trust, or Enable?",
            },
        }

        result = model.system_one(screen, questions)
        answers = result.get("answers", {})

        context = float(answers.get("context_sufficient", {}).get("noul", 0.0))
        safety = float(answers.get("safe_for_automatic_decision", {}).get("noul", 0.0))
        response = float(answers.get("response_is_affirmative", {}).get("noul", 0.0))

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
