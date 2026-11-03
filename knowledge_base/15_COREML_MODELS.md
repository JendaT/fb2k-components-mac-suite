# Core ML Models in a Component

Lessons from bundling the Beat This! beat tracker in foo_jl_bpm (2026-11).
The code: `extensions/foo_jl_bpm_mac/src/Integration/BeatThisModel.mm`,
`Scripts/beat_this/`, `Scripts/generate_xcode_project.rb`.

## Bundling

- Commit the `.mlpackage` under `Resources/` and add it to the target's
  **Sources** build phase (file type `folder.mlpackage`). Xcode's
  CoreMLModelCompile step writes `<name>.mlmodelc` into the bundle's
  Resources at build time. Set `COREML_CODEGEN_LANGUAGE = None` and use the
  generic `MLModel` API; the generated class is not needed.
- Link `CoreML.framework`.
- Find the bundle with `[NSBundle bundleForClass:]` on a class defined in the
  component. Objective-C class names are global across every component in the
  process: prefix them (`JLBpm...`).
- Load lazily on first use (a function-local static), never during static
  initialisation (see 03_SDK_SERVICE_PATTERNS.md on `abort_callback_impl`).
- Serialise predictions with a mutex when several threads (Analyze BPM runs
  tracks in parallel) share one `MLModel`.

## Converting from PyTorch (coremltools 9.0)

- Pin torch to what coremltools is tested with (2.7 for 9.0); 2.15 warned.
- `convert_to="mlprogram"`, `minimum_deployment_target=ct.target.macOS12`
  to match the components' deployment target.
- Patches that were needed for a rotary-embedding transformer, each checked
  to leave the PyTorch output bit-identical before tracing:
  - `rotary_embedding_torch` caches frequencies on first use, so
    `torch.jit.trace` fails its consistency check: set
    `cache_if_possible = False`.
  - `einsum('..., f -> ... f')` (an outer product) does not convert: replace
    with `t.unsqueeze(-1) * freqs`.
  - coremltools 9's `int` cast does `int(ndarray)` on a one-element shape
    value, which NumPy 2 rejects: patch `ops._cast` to take the element.

## Precision and compute units

float16 is the default and it is not harmless: on Beat This! it moved logits
by up to 0.3 on the GPU and 0.9 on the Neural Engine, and 1-4% of the
peak-picked beats. float32 with `MLComputeUnitsCPUAndGPU` matched PyTorch
within 1e-4 with identical beats, at 0.6-0.9 s per 10 minutes of audio on an
M5 Pro (CPU alone: 1.6 s). The Neural Engine computes in float16 regardless.
The first prediction in a session takes ~2 s more (GPU compile).

## Match the training front end exactly

A network reacts to front-end differences that look negligible:

- **Resampling**: Beat This! was trained on soxr (HQ) resampled audio, flat
  to 0.913 of Nyquist and down 120 dB at Nyquist. AVAudioConverter keeps
  energy up to Nyquist; that filled the top mel band and moved 10-20% of the
  beats. A FIR with soxr's response afterwards fixed it (`ResampleLowpass`);
  100 dB instead of 120 was not enough, and 140 dB matched worse.
- **AVAudioConverter quality**: Mastering + High is closer to soxr after the
  roll-off than Max and twice as fast (0.9 s vs 1.8 s per 10 minutes);
  Normal is 10x faster but moved 11-18% of the beats. For 2:1 and 4:1 a
  vDSP_desamp decimator with the same FIR design is exact and takes 0.08 s.
- **Spectrogram precision**: log(1 + 1000 x) magnifies float32 FFT rounding
  in near-empty bands to a few 1e-4, different for every FFT library. Compute
  the STFT and mel stage in double; compare against a float64 reference.
- Verify end to end, not stage by stage: feed both front ends through the
  network and compare the picked beats.
