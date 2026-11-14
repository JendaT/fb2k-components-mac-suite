import os
from collections import namedtuple
from typing import NamedTuple

from beets import plugins
from beets.library import Item

AlbumMatch = namedtuple("AlbumMatch", ("distance", "info", "mapping"))
TrackInfo = namedtuple("TrackInfo", ("title",))


class Proposal(NamedTuple):
    candidates: list
    recommendation: int


class Distance:
    """Not a float: the shim must convert with float()."""

    def __init__(self, value):
        self.value = value

    def __float__(self):
        return self.value


class AlbumInfo:
    def __init__(self, **fields):
        self.__dict__.update(fields)


# What each loaded metadata-source plugin yields: (data_source, album_id, distance).
PLUGIN_CANDIDATES = {
    "musicbrainz": [("MusicBrainz", "mb-%d" % n, 0.05 * n) for n in range(1, 6)],
    "discogs": [("Discogs", "1234", 0.08)],
    "spotify": [("Spotify", "sp-1", 0.01)],
}


def _candidates(items):
    out = []
    for name in plugins.loaded:
        for source, album_id, dist in PLUGIN_CANDIDATES.get(name, []):
            info = AlbumInfo(
                data_source=source,
                album_id=album_id,
                artist="Stub Artist",
                album="Stub Album",
                year=2012,
                label="Stub Label",
                catalognum="STUB-2",
            )
            out.append(AlbumMatch(Distance(dist), info, {i: TrackInfo(i.title) for i in items}))
    return sorted(out, key=lambda m: float(m.distance))


def _is_items(items):
    return isinstance(items, list) and all(isinstance(i, Item) for i in items)


if os.environ.get("STUB_BEETS_API") == "2.4":

    def tag_album(items, search_artist=None, search_album=None, search_ids=[]):
        if not _is_items(items):
            raise TypeError("beets 2.4-2.13 tag_album takes the item list")
        return "Stub Artist", "Stub Album", Proposal(_candidates(items), 0)

else:

    class Source(NamedTuple):
        items: list

        @classmethod
        def from_items(cls, items):
            return cls(items=items)

    def tag_album(source, search_artist=None, search_name=None, search_ids=[]):
        if not (isinstance(source, Source) and _is_items(source.items)):
            # What beets 2.14 does when handed the item list.
            raise AttributeError("'%s' object has no attribute 'desc'" % type(source).__name__)
        return Proposal(_candidates(source.items), 0)
