//
//  NetworkBeats.h
//  foo_jl_bpm_mac
//
//  Beats and downbeats from a beat-tracking network's frame logits (Beat
//  This!, JKU Linz, MIT: github.com/CPJKU/beat_this), for buildBeatGrid. The
//  network itself runs elsewhere (Core ML, in the integration layer); this
//  is the arithmetic around it, plain C++ and unit tested standalone:
//    - which chunks of the spectrogram to run, and how their predictions are
//      stitched back together (as upstream's split_piece and
//      aggregate_prediction: chunks of 1500 frames, 6 border frames
//      discarded each side, earlier chunks win where they overlap, the last
//      chunk moved back to end on the piece's end);
//    - beat times from the logits (as upstream's minimal postprocessor:
//      local maxima within +-3 frames above logit 0, adjacent frames merged,
//      downbeats moved to the nearest beat), plus a parabola through each
//      peak for sub-frame times.
//  Frame k is centred on k / kNetworkFps seconds (a centred STFT, hop 441
//  at 22.05 kHz).
//

#pragma once

#include "BeatGridAnalyzer.h"

#include <functional>
#include <vector>

namespace bpm {

constexpr double kNetworkFps = 50.0;
constexpr long kNetworkChunk = 1500;
constexpr long kNetworkBorder = 6;

// Where each chunk starts, in frames, for a piece `frames` long. A start can
// be negative (the first chunk is padded by the border) and the last chunk
// can run past the end (padded by up to the border); see chunkInput.
std::vector<long> networkChunkStarts(long frames);

// The rows [start, start + kNetworkChunk) of a frames x bins spectrogram as
// the network's input: rows outside the piece are zero, and the chunk is cut
// short at the piece's end plus the border, as upstream does. Returns the
// chunk's row count; `out` gets rows * bins values.
long chunkInput(const std::vector<float> &spectrogram, long frames, long bins, long start, std::vector<float> &out);

// Writes a chunk's predictions (`rows` frames from `start`) into the piece's,
// border frames dropped. Call in chunk order: earlier chunks keep their
// frames where chunks overlap. `filled` tracks which frames are taken.
void mergeChunk(const std::vector<float> &chunk, long rows, long start, std::vector<float> &piece,
                std::vector<bool> &filled);

// Peak frames (fractional) of a logit curve: local maxima within +-3 frames
// with a logit above 0, runs of adjacent frames merged to their mean, single
// peaks refined with a parabola through their neighbours
std::vector<double> pickPeaks(const std::vector<float> &logits);

// Runs the network over a spectrogram as it streams in: each of upstream's
// chunks as soon as its frames are in, the ones that need the piece's end on
// finish(), merged as upstream merges them, so the logits equal a run over
// the whole piece at once. Keeps only the frames later chunks still need.
// `run` gets `rows` x bins input values (rows <= kNetworkChunk, zero rows
// outside the piece) and writes `rows` beat and downbeat logits; it returns
// false when the network failed, which stops the chunker.
class NetworkChunker {
public:
    using Runner = std::function<bool(const float *input, long rows, float *beat, float *downbeat)>;
    NetworkChunker(long bins, Runner run);

    // Frames, bins values each, oldest first
    bool add(const float *frames, long count);
    bool finish();

    long frames() const { return received_; }
    // Per frame, after finish()
    const std::vector<float> &beatLogits() const { return beat_; }
    const std::vector<float> &downbeatLogits() const { return downbeat_; }

private:
    bool runChunk(long start);

    long bins_;
    Runner run_;
    std::vector<float> stored_;     // frames from base_ on
    long base_ = 0;
    long received_ = 0;
    long nextStart_ = -kNetworkBorder;
    long lastRun_ = -kNetworkBorder - 1;
    bool failed_ = false;
    std::vector<float> input_, chunkBeat_, chunkDownbeat_, beat_, downbeat_;
    std::vector<bool> filled_;
};

// Beats and downbeats in seconds, downbeats on their nearest beat, and how
// sure the network is of each beat (its probability at the peak)
RawBeats networkBeats(const std::vector<float> &beatLogits, const std::vector<float> &downbeatLogits);

} // namespace bpm
