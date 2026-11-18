"""Stub of the beets 2.x API surface the intake shim uses (test/beets-shim.test.ts).

Every metadata source is a plugin; load_plugins() takes no arguments and
reads the config's `plugins` list (stub: STUB_BEETS_PLUGINS, default
"musicbrainz" like beets' default config). Default shape is 2.14+:
tag_album(Source) -> Proposal. STUB_BEETS_API=2.4 gives the 2.4-2.13 shape:
tag_album(items) -> (artist, album, Proposal), no Source.
"""

import os

__version__ = "2.4.0" if os.environ.get("STUB_BEETS_API") == "2.4" else "2.14.1"
