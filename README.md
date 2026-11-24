# herdr-yes-only

A conservative Herdr plugin that sends `Enter` only when a pending binary prompt is safe and requires the affirmative response.

Without the optional decision model, it recognizes **only exact `Yes` and `No` options**. It never approves `Approve`, `Allow`, `Confirm`, `Proceed`, `Yes, always`, or similar labels in strict mode.

With the optional [`LiquidAI/d1-2B`](https://huggingface.co/LiquidAI/d1-2B) System One gate enabled, it can consider binary prompts from related affirmative/negative families, but only after a triple safety and context check.

Inspired by [`RenKoya1/herdr-approve-all`](https://github.com/RenKoya1/herdr-approve-all), but replaces blanket approval with a fail-closed pipeline.

## Install

```bash
herdr plugin install izziva/herdr-yes-only
```

## Modes

### `strict` — default

The plugin reads the visible screen and sends `Enter` only when:

1. Exactly two options are present.
2. They are exactly `Yes` and `No`, case-insensitive.
3. The cursor, default marker, or explicit hint shows that `Enter` selects or confirms `Yes`.
4. No high-risk command pattern is visible.

It ignores:

- `Approve`, `Allow`, `Confirm`, `Proceed`, `Accept`, `Install`, `Run`, `Trust`, and `Enable`
- `Yes, always`, `Yes, allow`, and other compound affirmative labels
- Three or more choices
- Multi-select menus
- Ambiguous prompts

### `system-one` — optional

Enable with:

```bash
export HERDR_YES_ONLY_MODE=system-one
```

This mode first identifies a candidate binary prompt from affirmative/negative families:

| Affirmative | Negative |
|---|---|
| `Yes`, `Yes, always`, `Yes, allow` | `No` |
| `Approve` | `Deny`, `Reject` |
| `Allow` | `Deny`, `Reject` |
| `Confirm` | `Cancel` |
| `Proceed`, `Continue` | `Abort`, `Cancel` |
| `Accept` | `Decline` |
| `Install` | `Skip` |
| `Run`, `Execute` | `Don't run`, `Do not run` |
| `Trust`, `Enable` | `Disable` |

The candidate must still contain exactly two options: one affirmative and one negative. The plugin then asks `d1-2B` three `noul` questions in **one** `system_one` request:

| Gate | Question | Default threshold |
|---|---|---:|
| Context | Is the visible context sufficient to determine the correct response? | 0.80 |
| Safety | Is this safe to decide automatically without ambiguity or unacceptable risk? | 0.90 |
| Response | Is the correct response the affirmative option? | 0.90 |

`Enter` is sent only when all thresholds pass and the deterministic check confirms that `Enter` selects or confirms the affirmative option.

If the model is unavailable, times out, errors, or is uncertain, the plugin fails closed and sends nothing.

## Configuration

Create `$HERDR_PLUGIN_CONFIG_DIR/config.env` or export:

```bash
HERDR_YES_ONLY_MODE=strict
HERDR_YES_ONLY_D1_MODEL=LiquidAI/d1-2B
HERDR_YES_ONLY_D1_MIN_CONTEXT_CONFIDENCE=0.80
HERDR_YES_ONLY_D1_MIN_SAFETY_CONFIDENCE=0.90
HERDR_YES_ONLY_D1_MIN_RESPONSE_CONFIDENCE=0.90
HERDR_YES_ONLY_D1_TIMEOUT_SEC=5
HERDR_YES_ONLY_BLOCK_RISKY=1
HERDR_YES_ONLY_DEBUG=0
```

## Model setup

Pre-download the model before starting Herdr:

```bash
python3 -m pip install 'transformers>=5.19' torch torchvision pillow
python3 - <<'PY'
from transformers import AutoModel
AutoModel.from_pretrained('LiquidAI/d1-2B', trust_remote_code=True)
PY
```

The bundled helper loads the model locally through Transformers, preferring CUDA, then Apple MPS, then CPU.

## Actions

| Action | Behavior |
|---|---|
| `Approve qualifying binary prompts` | One sweep across blocked agents |
| `System One triple gate: ON` | Enables the optional model gate |
| `System One triple gate: OFF` | Disables the optional model gate |
| `Auto-approve: ON` | Enables automatic approval |
| `Auto-approve: OFF` | Disables automatic approval |

## Safety

Automatic approval can authorize agent actions. Keep `strict` as the default, run the decision model locally, retain the risky-command guard, use high confidence thresholds, and review the terminal before enabling automatic mode.

## License

MIT. Includes design concepts inspired by `RenKoya1/herdr-approve-all`.
