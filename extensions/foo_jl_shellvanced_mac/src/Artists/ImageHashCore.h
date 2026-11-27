//
//  ImageHashCore.h
//  Pure perceptual hashing (no SDK, no AppKit): used to spot Deezer artist pictures that are
//  really one of the artist's album covers.
//
#pragma once

#include <cstdint>
#include <vector>

namespace imagehash {

// 64-bit difference hash of a 9x8 (width x height) RGBA buffer: bit = left luma < right luma,
// row-major, 8 comparisons per row.
inline uint64_t dHash9x8(const uint8_t* rgba) {
    int luma[8][9];
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 9; x++) {
            const uint8_t* p = rgba + (y * 9 + x) * 4;
            luma[y][x] = 299 * p[0] + 587 * p[1] + 114 * p[2];
        }
    uint64_t h = 0;
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 8; x++) {
            h <<= 1;
            if (luma[y][x] < luma[y][x + 1]) h |= 1;
        }
    return h;
}

inline int hammingDistance(uint64_t a, uint64_t b) {
    uint64_t v = a ^ b;
    int n = 0;
    while (v) { v &= v - 1; n++; }
    return n;
}

constexpr int kCoverMaxDistance = 10;

// The picture is "cover-like" if it is within `maxDistance` bits of any album cover.
inline bool isCoverLike(uint64_t photo, const std::vector<uint64_t>& covers, int maxDistance = kCoverMaxDistance) {
    for (uint64_t c : covers)
        if (hammingDistance(photo, c) <= maxDistance) return true;
    return false;
}

}  // namespace imagehash
