# Beat This! model and test fixture

The component bundles Beat This! (Foscarin, Schlüter and Widmer, "Beat This!
Accurate Beat Tracking Without DBN Postprocessing", ISMIR 2024; code and
weights MIT, github.com/CPJKU/beat_this) as a Core ML model,
`Resources/BeatThisSmall0.mlpackage`. These scripts rebuild it and the front
end's test fixture. Nothing here runs during a normal build.

| Script | Writes |
|---|---|
| `convert_beat_this.py` | `Resources/BeatThisSmall0.mlpackage` (small0, float32, macOS 12+) |
| `make_logmel_reference.py` | `Tests/fixtures/logmel_reference.bin` (torchaudio's log-mel of a test signal) |

## Setup

An isolated environment; nothing is installed system-wide. Versions as used
for the bundled model (coremltools 9.0 is tested with torch up to 2.7):

```bash
uv venv --python 3.12 /tmp/beat-this-env
git clone https://github.com/CPJKU/beat_this /tmp/beat_this   # used at b95c8ab (1.1.0)
VIRTUAL_ENV=/tmp/beat-this-env uv pip install "torch==2.7.0" "torchaudio==2.7.0" "coremltools==9.0" \
    "numpy==2.5.4" "einops==0.8.2" "rotary-embedding-torch==0.9.1" "soxr==1.1.0" -e /tmp/beat_this
/tmp/beat-this-env/bin/python convert_beat_this.py
/tmp/beat-this-env/bin/python make_logmel_reference.py ../../Tests/fixtures/logmel_reference.bin
```

The first run downloads the small0 checkpoint (8 MB) from JKU's server into
`$TORCH_HOME` (default `~/.cache/torch`).

## Conversion notes

- The converter needs two patches (in the script): coremltools 9 fails on a
  traced one-element shape cast under NumPy 2, and cannot convert the rotary
  embedding's `einsum('..., f -> ... f')`; the script replaces it with the
  same broadcast product and checks the output is unchanged (difference 0.0).
- The rotary embedding caches its frequencies on first use, which makes
  `torch.jit.trace` fail its consistency check; the cache is switched off.
- float32, not float16: float16 moves logits by up to 0.3 (0.9 on the Neural
  Engine) and changes 1-4% of the picked beats; float32 on CPU and GPU picks
  the same beats as PyTorch on all 10 test tracks (logits within 1e-4), about
  0.6 s per 10-minute track on an M5 Pro.
