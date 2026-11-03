# Converts Beat This! small0 (JKU Linz, MIT: github.com/CPJKU/beat_this) to
# the Core ML model the component bundles: one chunk of 1500 frames x 128
# log-mel bands in ("spect"), beat and downbeat logits out, float32
# throughout, macOS 12 or later. Xcode compiles it at build time.
#
#   python convert_beat_this.py [<output.mlpackage>]
#
# Default output: ../../Resources/BeatThisSmall0.mlpackage. Checks that the
# patched model below matches upstream's output exactly before converting.
# Setup and pinned versions: README.md here.
import os
import sys

import numpy as np
import torch
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops as ct_ops
from rotary_embedding_torch import RotaryEmbedding
from beat_this.inference import load_model

CHUNK = 1500
here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "..", "Resources", "BeatThisSmall0.mlpackage")

# 1. coremltools 9 casts a traced one-element shape value with
#    int(ndarray), which NumPy 2 rejects: take the element instead
_orig_cast = ct_ops._cast


def _cast(context, node, dtype, dtype_name):
    x = ct_ops._get_inputs(context, node, expected=1)[0]
    if x.can_be_folded_to_const() and isinstance(x.val, np.ndarray) and x.val.size == 1:
        context.add(mb.const(val=dtype(x.val.reshape(-1)[0]), name=node.name), node.name)
        return
    _orig_cast(context, node, dtype, dtype_name)


ct_ops._cast = _cast


# 2. The rotary embedding computes its frequencies with
#    einsum('..., f -> ... f'), which coremltools cannot convert: the same
#    outer product by broadcasting (positions are 1-D here). Its frequency
#    cache also makes the traced graph depend on cache state: off.
def _rotary_forward(self, t, seq_len=None, offset=0):
    freqs = t.type(self.freqs.dtype).unsqueeze(-1) * self.freqs
    return freqs.repeat_interleave(2, dim=-1)


class Logits(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, spect):
        result = self.model(spect)
        return result["beat"], result["downbeat"]


reference = load_model("small0", "cpu").eval()
model = load_model("small0", "cpu").eval()
for m in model.modules():
    if isinstance(m, RotaryEmbedding):
        m.cache_if_possible = False
RotaryEmbedding.forward = _rotary_forward
wrapped = Logits(model).eval()

example = torch.randn(1, CHUNK, 128)
with torch.no_grad():
    beat, downbeat = wrapped(example)
    expected = reference(example)
diff = max(float((beat - expected["beat"]).abs().max()), float((downbeat - expected["downbeat"]).abs().max()))
print(f"patched model vs upstream: max abs diff {diff}")
assert diff == 0.0, "the patches changed the model's output"

with torch.no_grad():
    traced = torch.jit.trace(wrapped, example)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="spect", shape=(1, CHUNK, 128), dtype=np.float32)],
    outputs=[ct.TensorType(name="beat", dtype=np.float32), ct.TensorType(name="downbeat", dtype=np.float32)],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.macOS12,
)
mlmodel.short_description = ("Beat This! small0: beat and downbeat logits at 50 fps from 1500 frames of "
                             "128 log-mel bands")
mlmodel.author = "Francesco Foscarin, Jan Schlueter, Gerhard Widmer (CPJKU/beat_this)"
mlmodel.license = "MIT"
mlmodel.version = "small0 (beat_this 1.1.0)"
mlmodel.save(out)
print("saved", os.path.abspath(out))
