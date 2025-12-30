# foo_jl_biography - Pre-Research Document

## Project Overview

A foobar2000 macOS component that displays artist biography, images, and related information for the currently playing track. The component fetches data from multiple sources (Last.fm, Wikipedia, Fanart.tv, TheAudioDB) with intelligent fallback.

**Component Name:** `foo_jl_biography_mac`
**Target Platform:** foobar2000 v2.x (macOS)
**Component Type:** UI Element (Layout Component via `ui_element_mac`)
**SDK Version:** foobar2000 SDK 2025-03-07

---

## Research Summary

### 1. Reference Implementation Analysis

#### Wil-B/Biography (Windows - Spider Monkey Panel)
- **Repository:** [https://github.com/Wil-B/Biography](https://github.com/Wil-B/Biography)
- **Architecture:** JavaScript-based using Spider Monkey Panel 1.5.2+
- **Data Sources:** Last.fm, AllMusic, Wikipedia
- **Features:**
  - Artist photos, biographies, and reviews
  - Lyrics display (synced and unsynced)
  - Album and track information
  - Filmstrip navigation with drag-resize
  - 5 layout presets + custom freestyle
  - 5 theme modes with randomization
  - Display modes: image+text, image-only, text-only

**Key Insights:**
- Multi-source approach provides redundancy
- Caching is essential for responsiveness
- Flexible layout system is highly valued by users
- Image quality matters (multiple sources for best images)

---

## Data Source Analysis

### 1. Last.fm API

**Documentation:** [https://www.last.fm/api/show/artist.getInfo](https://www.last.fm/api/show/artist.getInfo)

#### Endpoints

| Endpoint | Purpose | Auth Required |
|----------|---------|---------------|
| `artist.getInfo` | Biography, images, similar artists | API Key only |
| `artist.getSimilar` | Related artists | API Key only |
| `artist.getTopTracks` | Popular tracks | API Key only |
| `artist.getTopAlbums` | Discography | API Key only |

#### artist.getInfo Response

```json
{
  "artist": {
    "name": "Cher",
    "mbid": "bfcc6d75-a6a5-4bc6-8571-5d0e...",
    "url": "https://www.last.fm/music/Cher",
    "image": [
      {"#text": "https://lastfm.freetls.fastly.net/i/u/34s/...", "size": "small"},
      {"#text": "https://lastfm.freetls.fastly.net/i/u/64s/...", "size": "medium"},
      {"#text": "https://lastfm.freetls.fastly.net/i/u/174s/...", "size": "large"},
      {"#text": "https://lastfm.freetls.fastly.net/i/u/300x300/...", "size": "extralarge"},
      {"#text": "https://lastfm.freetls.fastly.net/i/u/300x300/...", "size": "mega"}
    ],
    "streamable": "0",
    "stats": {
      "listeners": "2291439",
      "playcount": "32814914"
    },
    "similar": {
      "artist": [
        {"name": "Madonna", "url": "...", "image": [...]}
      ]
    },
    "tags": {
      "tag": [
        {"name": "pop", "url": "..."},
        {"name": "female vocalists", "url": "..."}
      ]
    },
    "bio": {
      "published": "01 Jan 2011, 21:56",
      "summary": "Cher is an American singer and actress...<a href=\"https://www.last.fm/music/Cher\">Read more on Last.fm</a>",
      "content": "Full biography text here..."
    }
  }
}
```

#### Authentication & Limits

- **API Key:** Required (obtain at https://www.last.fm/api/account/create)
- **Rate Limit:** Reasonable use policy, ~1 req/sec recommended
- **Error 29:** Rate limit exceeded
- **No OAuth:** Required for read-only artist info

#### Pros/Cons

| Pros | Cons |
|------|------|
| Comprehensive artist data | Image quality limited (300px max) |
| Biography in multiple languages | Biography truncated at 300 chars in summary |
| Similar artists included | Rate limiting (not documented precisely) |
| Free API access | Images may be missing for some artists |
| MusicBrainz ID included | |

---

### 2. Wikipedia / MediaWiki API

**Documentation:** [https://www.mediawiki.org/wiki/API:Query](https://www.mediawiki.org/wiki/API:Query)

#### Endpoints

```
Base URL: https://en.wikipedia.org/w/api.php
```

#### Key Queries

**Search + Extract + Images:**
```
?action=query
&titles={Artist Name}
&prop=extracts|pageimages|info
&pithumbsize=500
&inprop=url
&redirects=1
&format=json
&origin=*
```

**Search Artists:**
```
?action=query
&generator=search
&gsrlimit=5
&prop=pageimages|extracts
&exintro=1
&explaintext=1
&exlimit=max
&format=json
&gsrsearch={query}
```

#### Response Example

```json
{
  "query": {
    "pages": {
      "12345": {
        "pageid": 12345,
        "title": "Cher",
        "extract": "Cher is an American singer, actress...",
        "thumbnail": {
          "source": "https://upload.wikimedia.org/.../500px-Cher.jpg",
          "width": 500,
          "height": 750
        },
        "fullurl": "https://en.wikipedia.org/wiki/Cher"
      }
    }
  }
}
```

#### Pros/Cons

| Pros | Cons |
|------|------|
| No API key required | Disambiguation needed (search results) |
| High-quality images | Artist matching can be ambiguous |
| Comprehensive biographies | No music-specific metadata |
| Multiple languages | Extract formatting varies |
| CORS-friendly | |

---

### 3. Fanart.tv API

**Documentation:** [https://fanarttv.docs.apiary.io/](https://fanarttv.docs.apiary.io/)

#### Endpoint

```
GET https://webservice.fanart.tv/v3/music/{musicbrainz_artist_id}?api_key=YOUR_API_KEY
```

#### Image Types Available

| Type | Description | Resolution |
|------|-------------|------------|
| `artistthumb` | Artist thumbnail | 1000x1000 |
| `artistbackground` | Wide background | 1920x1080 |
| `hdmusiclogo` | HD logo | 800x310 |
| `musiclogo` | Standard logo | 400x155 |
| `musicbanner` | Banner | 1000x185 |

#### Response Example

```json
{
  "name": "Coldplay",
  "mbid_id": "cc197bad-dc9c-440d-a5b5-d52ba2e14234",
  "artistthumb": [
    {
      "id": "12345",
      "url": "https://assets.fanart.tv/fanart/music/.../artistthumb/coldplay-12345.jpg",
      "likes": "5"
    }
  ],
  "artistbackground": [
    {
      "id": "67890",
      "url": "https://assets.fanart.tv/fanart/music/.../artistbackground/coldplay-67890.jpg",
      "likes": "3"
    }
  ]
}
```

#### Authentication

- **API Key:** Required (obtain at https://fanart.tv/get-an-api-key/)
- **Personal API Key:** Optional, bypasses delays
- **Image Delay:**
  - v3: 1 week behind
  - v3 + personal key: 2 days behind
  - v3 + VIP: Real-time

#### Pros/Cons

| Pros | Cons |
|------|------|
| High-resolution images | Requires MusicBrainz ID |
| Multiple image types | API key required |
| Community curated | Image availability varies |
| Consistent quality | Delay for new images |

---

### 4. TheAudioDB API

**Documentation:** [https://www.theaudiodb.com/free_music_api](https://www.theaudiodb.com/free_music_api)

#### Endpoints (v1)

| Endpoint | Purpose | Example |
|----------|---------|---------|
| `search.php?s={artist}` | Search artist | `?s=coldplay` |
| `artist.php?i={id}` | Lookup by ID | `?i=111239` |
| `artist-mb.php?i={mbid}` | Lookup by MusicBrainz ID | `?i=cc197bad-...` |

#### Response Fields

```json
{
  "artists": [{
    "idArtist": "111239",
    "strArtist": "Coldplay",
    "strArtistStripped": "coldplay",
    "strStyle": "Rock/Pop",
    "strGenre": "Alternative Rock",
    "strMood": "Reflective",
    "strWebsite": "www.coldplay.com",
    "strFacebook": "coldplay",
    "strTwitter": "coldplay",
    "strBiographyEN": "Coldplay are a British rock band...",
    "strBiographyCZ": "Czech biography...",
    "strGender": "Male",
    "intMembers": "4",
    "strCountry": "London, England",
    "strArtistThumb": "https://www.theaudiodb.com/images/media/artist/thumb/...",
    "strArtistLogo": "https://www.theaudiodb.com/images/media/artist/logo/...",
    "strArtistCutout": "https://www.theaudiodb.com/images/media/artist/cutout/...",
    "strArtistClearart": "https://www.theaudiodb.com/images/media/artist/clearart/...",
    "strArtistWideThumb": "https://www.theaudiodb.com/images/media/artist/widethumb/...",
    "strArtistFanart": "https://www.theaudiodb.com/images/media/artist/fanart/...",
    "strArtistFanart2": "...",
    "strArtistFanart3": "...",
    "strArtistBanner": "https://www.theaudiodb.com/images/media/artist/banner/..."
  }]
}
```

#### Rate Limits

| Tier | Rate Limit | Cost |
|------|------------|------|
| Free | 30 req/min | Free |
| Premium | 100 req/min | Paid |
| Business | 120 req/min | Paid |

#### Image Sizes

- Original: 720px
- Medium: 500px (append `/medium`)
- Small: 250px (append `/small`)

#### Pros/Cons

| Pros | Cons |
|------|------|
| Rich metadata (mood, style, gender) | 30 req/min limit on free tier |
| Multiple image types | Search limited on free tier |
| Biography in multiple languages | Some artists missing |
| Social media links | Registration required |
| No MusicBrainz ID needed for search | |

---

### 5. MusicBrainz API

**Documentation:** [https://musicbrainz.org/doc/MusicBrainz_API](https://musicbrainz.org/doc/MusicBrainz_API)

#### Purpose
- Obtain MusicBrainz ID (MBID) for use with Fanart.tv and other services
- Artist disambiguation
- Standardized artist metadata

#### Endpoint

```
GET https://musicbrainz.org/ws/2/artist/?query=artist:{name}&fmt=json
```

#### Rate Limits

- **1 request per second** (strict)
- User-Agent header required

#### Pros/Cons

| Pros | Cons |
|------|------|
| Authoritative music database | Strict rate limiting |
| Links to other services | No images directly |
| Disambiguation support | Complex query syntax |

---

### 6. Discogs API

**Documentation:** [https://www.discogs.com/developers](https://www.discogs.com/developers)

#### Endpoints

```
GET https://api.discogs.com/artists/{id}
GET https://api.discogs.com/database/search?q={query}&type=artist
```

#### Rate Limits

| Type | Limit |
|------|-------|
| Authenticated | 60 req/min |
| Unauthenticated | 25 req/min |
| Images (api-img) | 240 req/min |

#### Pros/Cons

| Pros | Cons |
|------|------|
| High-quality artist profile | Images require authentication |
| Discography data | Rate limiting |
| Professional metadata | OAuth for images |

---

## Recommended Data Source Strategy

### Priority Order for Biography

1. **Last.fm** - Primary source (music-focused, good coverage)
2. **TheAudioDB** - Secondary (multi-language support, mood/style)
3. **Wikipedia** - Fallback (comprehensive but needs disambiguation)

### Priority Order for Images

1. **Fanart.tv** - Best quality (1000px+, multiple types)
2. **TheAudioDB** - Good quality (720px, multiple types)
3. **Last.fm** - Acceptable (300px max, limited)
4. **Wikipedia** - Variable quality (fallback)

### Data Flow

```
Track Playing
     │
     ▼
Extract Artist Name from Metadata
     │
     ├─── Check Local Cache ───► Hit: Return cached data
     │
     ▼ (Cache Miss)
     │
     ├─[1]─► Last.fm artist.getInfo
     │           │
     │           ├── Success: Get bio, MBID, basic images
     │           │
     │           └── Fail: Continue to next source
     │
     ├─[2]─► Fanart.tv (if MBID available)
     │           │
     │           ├── Success: Get high-res images
     │           │
     │           └── Fail: Continue
     │
     ├─[3]─► TheAudioDB search
     │           │
     │           ├── Success: Supplement bio, get images if needed
     │           │
     │           └── Fail: Continue
     │
     └─[4]─► Wikipedia (if bio still needed)
                 │
                 └── Success/Fail: Return combined data
```

---

## Existing Codebase Patterns

### From foo_jl_scrobble_mac (Last.fm Client)

**HTTP Request Pattern:**
```objc
@property (nonatomic, strong) NSURLSession* urlSession;

- (void)executeRequest:(NSDictionary*)params
            completion:(void(^)(NSDictionary*, NSError*))completion {
    NSURL* url = [self buildURL:params];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];

    [[_urlSession dataTaskWithRequest:request
                    completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(nil, error);
                return;
            }
            NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:nil];
            completion(json, nil);
        });
    }] resume];
}
```

### From foo_jl_album_art_mac (Image Handling)

**Image Loading:**
```objc
- (void)loadImageFromURL:(NSURL*)url {
    [[NSURLSession sharedSession] dataTaskWithURL:url
                                completionHandler:^(NSData* data,
                                                    NSURLResponse* response,
                                                    NSError* error) {
        if (data && !error) {
            NSImage* image = [[NSImage alloc] initWithData:data];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.artistImage = image;
                [self setNeedsDisplay:YES];
            });
        }
    }] resume];
}
```

### UI Element Registration

```cpp
class biography_ui_element : public ui_element_mac {
    service_ptr instantiate(service_ptr arg) override;
    bool match_name(const char* name) override {
        return strcmp(name, "biography") == 0 ||
               strcmp(name, "artist_biography") == 0 ||
               strcmp(name, "foo_jl_biography") == 0;
    }
    GUID get_guid() override;
    fb2k::stringRef get_name() override { return "Artist Biography"; }
};
FB2K_SERVICE_FACTORY(biography_ui_element);
```

---

## Technical Considerations

### API Key Management

- Store in `SecretConfig.h` (git-ignored)
- Provide template file `SecretConfig.h.template`
- Consider allowing user-provided keys in preferences

### Caching Strategy

| Data Type | Storage | TTL |
|-----------|---------|-----|
| Biography text | SQLite/JSON | 7 days |
| Artist images | File system | 30 days |
| MBID lookups | SQLite | Permanent |
| API responses | Memory | Session |

**Cache Location:** `~/Library/Application Support/foobar2000-v2/biography_cache/`

### Rate Limiting

| Service | Limit | Implementation |
|---------|-------|----------------|
| Last.fm | ~1/sec | Token bucket |
| MusicBrainz | 1/sec | Strict queue |
| TheAudioDB | 30/min | Sliding window |
| Fanart.tv | None specified | Reasonable use |

### Error Handling

1. Network timeout (30s)
2. API error responses
3. Missing artist data
4. Image download failures
5. Rate limit exceeded (429)

### Fallback Behavior

- Missing biography: Show "No biography available" with link to search
- Missing image: Show placeholder or album art fallback
- All APIs fail: Show cached data if available, or minimal display

---

## UI Considerations

### Display Modes

1. **Full Mode** - Image + Biography + Tags + Similar Artists
2. **Compact Mode** - Small image + Short bio excerpt
3. **Image Only** - Large artist image
4. **Text Only** - Biography text with formatting

### Layout Options

- Top (horizontal banner with bio below)
- Left sidebar (image left, text right)
- Right sidebar (text left, image right)
- Overlay (image background, text overlay)

### Theming

- Follow foobar2000 appearance settings
- Support dark mode (NSAppearance)
- Configurable fonts and colors

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Last.fm API changes | Low | High | Abstract API layer, cache responses |
| Rate limiting | Medium | Medium | Implement queuing, respect limits |
| Missing artist data | Medium | Low | Multiple source fallback |
| Image licensing | Low | Medium | Use official APIs only |
| Performance (large images) | Medium | Medium | Lazy loading, size limits |

---

## References

### API Documentation
- [Last.fm API](https://www.last.fm/api/)
- [Wikipedia API](https://www.mediawiki.org/wiki/API:Main_page)
- [Fanart.tv API](https://fanarttv.docs.apiary.io/)
- [TheAudioDB API](https://www.theaudiodb.com/free_music_api)
- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API)
- [Discogs API](https://www.discogs.com/developers)

### Reference Implementations
- [Wil-B/Biography](https://github.com/Wil-B/Biography) - Spider Monkey Panel plugin
- [foo_uie_biography](https://www.foobar2000.org/components/view/foo_uie_biography) - Classic Windows component

### Existing Codebase
- `foo_jl_scrobble_mac` - Last.fm API patterns
- `foo_jl_album_art_mac` - Image handling, UI element patterns
- `foo_jl_simplaylist_mac` - Complex view rendering

---

*Document Version: 1.0*
*Created: 2025-12-28*
*Research: Claude Code with parallel web research*
