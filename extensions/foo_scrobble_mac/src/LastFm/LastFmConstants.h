//
//  LastFmConstants.h
//  foo_scrobble_mac
//
//  Last.fm API constants
//

#pragma once

// Include secret credentials (not committed to git)
#include "SecretConfig.h"

namespace LastFm {

// API endpoints
static const char* const kBaseUrl = "https://ws.audioscrobbler.com/2.0/";
static const char* const kAuthUrl = "https://www.last.fm/api/auth/";

// API credentials from SecretConfig.h
static const char* const kApiKey = LASTFM_API_KEY;
static const char* const kApiSecret = LASTFM_API_SECRET;

// API methods
static const char* const kMethodGetToken = "auth.getToken";
static const char* const kMethodGetSession = "auth.getSession";
static const char* const kMethodScrobble = "track.scrobble";
static const char* const kMethodNowPlaying = "track.updateNowPlaying";
static const char* const kMethodGetUserInfo = "user.getInfo";

// Timing constants
static const double kAuthPollInterval = 3.0;      // Poll for approval every 3s
static const double kAuthTimeout = 600.0;         // 10 minute auth timeout
static const double kRequestTimeout = 30.0;       // HTTP request timeout

// Rate limiting (token bucket)
static const double kTokensPerSecond = 5.0;
static const int kBurstCapacity = 750;            // 5min * 5tps / 2

// Batch limits
static const int kMaxScrobblesPerBatch = 50;      // Last.fm limit

} // namespace LastFm
