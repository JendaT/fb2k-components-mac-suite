#pragma once

#include "../fb2k_sdk.h"
#include "../Core/TrackInfo.h"
#include <string>

namespace cloud_streamer {

// Album art extractor instance for a specific cloud track
class CloudAlbumArtInstance : public album_art_extractor_instance {
public:
    CloudAlbumArtInstance(const std::string& internalURL);
    ~CloudAlbumArtInstance();

    // album_art_extractor_instance interface
    album_art_data_ptr query(const GUID& p_what, abort_callback& p_abort) override;

private:
    std::string m_internalURL;
    std::string m_thumbnailURL;
    bool m_metadataLoaded;

    void loadMetadata(abort_callback& p_abort);
};

// Album art extractor entrypoint for cloud URLs
class CloudAlbumArtExtractor : public album_art_extractor_v2 {
public:
    // album_art_extractor interface
    bool is_our_path(const char* p_path, const char* p_extension) override;
    album_art_extractor_instance_ptr open(file_ptr p_filehint, const char* p_path, abort_callback& p_abort) override;

    // album_art_extractor_v2 interface
    GUID get_guid() override;
};

} // namespace cloud_streamer
