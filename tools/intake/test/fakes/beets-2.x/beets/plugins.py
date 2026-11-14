import os

loaded = []


def load_plugins():
    if loaded:
        return
    names = [n for n in os.environ.get("STUB_BEETS_PLUGINS", "musicbrainz").split(",") if n]
    print("stub beets: loading plugins %s" % names)  # beets/plugins may print; must not reach the shim's stdout
    if "prompt" in names:
        # Like the discogs plugin's OAuth setup without a token. beets catches
        # plugin init errors and skips the plugin.
        try:
            input("Enter the Discogs verification code: ")
        except EOFError:
            names.remove("prompt")
    loaded.extend(names)
