import json
import os
import time


def default_path():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "history.json")


class RoomHistory:
    def __init__(self, path=None):
        self.path = path or default_path()
        self.items = []
        self.load()

    def load(self):
        if not os.path.isfile(self.path):
            self.items = []
            return
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
            self.items = data.get("rooms") or []
        except Exception:
            self.items = []

    def save(self):
        payload = {"rooms": self.items}
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.replace(tmp, self.path)

    def remember(self, room_id, nick=""):
        room_id = str(room_id).strip()
        found = None
        for item in self.items:
            if str(item.get("room_id")) == room_id:
                found = item
                break
        if found is None:
            found = {"room_id": room_id, "nick": nick, "ts": 0}
            self.items.append(found)
        if nick:
            found["nick"] = nick
        found["ts"] = int(time.time())
        self.items.sort(key=lambda x: x.get("ts") or 0, reverse=True)
        self.save()
        return found

    def remove(self, room_id):
        room_id = str(room_id).strip()
        kept = [item for item in self.items if str(item.get("room_id")) != room_id]
        if len(kept) == len(self.items):
            return False
        self.items = kept
        self.save()
        return True

    def labels(self):
        out = []
        for item in self.items:
            room_id = str(item.get("room_id") or "")
            nick = (item.get("nick") or "").strip()
            if nick:
                out.append("%s  %s" % (room_id, nick))
            else:
                out.append(room_id)
        return out

    def room_id_of(self, label):
        text = (label or "").strip()
        if not text:
            return ""
        return text.split()[0]
