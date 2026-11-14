import os


class Item:
    def __init__(self, path):
        self.path = path
        self.title = os.path.splitext(os.path.basename(path.decode()))[0].split(" - ", 1)[-1]

    @classmethod
    def from_path(cls, path):
        return cls(path if isinstance(path, bytes) else path.encode())
