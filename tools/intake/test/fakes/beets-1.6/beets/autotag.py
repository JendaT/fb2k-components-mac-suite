from collections import namedtuple

from beets.library import Item

Proposal = namedtuple("Proposal", ("candidates", "recommendation"))
AlbumMatch = namedtuple("AlbumMatch", ("distance", "info", "mapping", "extra_items", "extra_tracks"))
TrackInfo = namedtuple("TrackInfo", ("title",))


class Distance:
    """Not a float: the shim must convert with float()."""

    def __init__(self, value):
        self.value = value

    def __float__(self):
        return self.value


class AlbumInfo:
    def __init__(self, **fields):
        self.__dict__.update(fields)


def tag_album(items, search_artist=None, search_album=None, search_ids=[]):
    if not (isinstance(items, list) and all(isinstance(i, Item) for i in items)):
        raise TypeError("beets 1.6 tag_album takes the item list")
    info = AlbumInfo(
        data_source="MusicBrainz",
        album_id="mb-16",
        artist="Stub Artist",
        album="Stub Album",
        year=2012,
        label="Stub Label",
        catalognum="STUB-16",
    )
    match = AlbumMatch(Distance(0.07123), info, {i: TrackInfo(i.title) for i in items}, [], [])
    return "Stub Artist", "Stub Album", Proposal([match], 0)
