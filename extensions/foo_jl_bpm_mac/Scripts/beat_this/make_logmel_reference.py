# Writes Tests/fixtures/logmel_reference.bin: Beat This!'s log-mel front end
# (torchaudio, as upstream's LogMelSpect, in float64) over a fixed 2.5 s test signal, for
# LogMelSpectrogramTests. The signal is a formula, so the C++ test builds the
# same samples. Needs the beat_this package (see README.md here).
#
#   python make_logmel_reference.py <output.bin>
#
# Output: uint32 frames, uint32 bands, then frames x bands float32, row major.
import sys
import numpy as np
import torch
from beat_this.preprocessing import LogMelSpect


def test_signal():
    n = 55125  # 2.5 s at 22.05 kHz
    i = np.arange(n, dtype=np.float64)
    t = i / 22050.0
    x = 0.3 * np.sin(2 * np.pi * 110 * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 2 * t))
    x += 0.2 * np.sin(2 * np.pi * 440 * t + 0.5)
    x += 0.1 * np.sin(2 * np.pi * 3000 * t)
    x += 0.05 * np.sin(2 * np.pi * (200 + 2000 * t) * t)
    for k in range(5):  # a decaying click every 0.5 s
        d = i - k * 11025
        burst = (d >= 0) & (d < 2000)
        x[burst] += 0.8 * np.exp(-d[burst] / 50.0) * np.sin(2 * np.pi * 1500 * t[burst])
    return x.astype(np.float32)


# In float64: in bands with almost no energy, log(1 + 1000 x) magnifies
# float32 rounding to a few 1e-4, different for every FFT implementation
spect = LogMelSpect().double()(torch.tensor(test_signal()).double()).numpy().astype(np.float32)
with open(sys.argv[1], "wb") as f:
    np.array(spect.shape, dtype=np.uint32).tofile(f)
    spect.tofile(f)
print(sys.argv[1], spect.shape, float(spect.min()), float(spect.max()))
