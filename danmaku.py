import base64
import threading
import time

from tars import TarsInput, TarsOutput

try:
    import websocket
except ImportError:
    websocket = None

DANMU_URI = 1400
WS_URL = "wss://cdnws.api.huya.com"
HEARTBEAT = base64.b64decode("ABQdAAwsNgBM")
DEFAULT_COLOR = "#E8ECF2"


def rgb_hex(value):
    if value is None:
        return DEFAULT_COLOR
    try:
        n = int(value)
    except Exception:
        return DEFAULT_COLOR
    if n < 0 or n in (0, 0xFFFFFF):
        return DEFAULT_COLOR
    n = n & 0xFFFFFF
    return "#%06X" % n


def parse_chat(payload):
    try:
        stream = TarsInput(payload)
        cmd = stream.read_int(0, False, 0)
        if cmd != 7:
            return None
        body = stream.read_bytes(1, False)
        push = TarsInput(body)
        uri = push.read_int(1, False, 0)
        if uri != DANMU_URI:
            return None
        msg = push.read_bytes(2, False)
        notice = TarsInput(msg)
        user_blob = notice.read_struct_bytes(0, False)
        nick = ""
        if user_blob:
            user = TarsInput(user_blob)
            nick = user.read_string(2, False, "")
        content = notice.read_string(3, False, "")
        if not content:
            return None
        color = DEFAULT_COLOR
        blob = TarsInput(msg).read_struct_bytes(6, False)
        if blob:
            color = rgb_hex(TarsInput(blob).read_int(0, False, -1))
        return nick or "匿名", content, color
    except Exception:
        return None


def build_join(ayyuid, tid, sid):
    inner = TarsOutput()
    inner.write_int(ayyuid, 0)
    inner.write_bool(True, 1)
    inner.write_string("", 2)
    inner.write_string("", 3)
    inner.write_int(tid, 4)
    inner.write_int(sid, 5)
    inner.write_int(0, 6)
    inner.write_int(0, 7)
    outer = TarsOutput()
    outer.write_int(1, 0)
    outer.write_bytes(inner.to_bytes(), 1)
    return outer.to_bytes()


class DanmakuClient:
    def __init__(self, on_message, on_status):
        self.on_message = on_message
        self.on_status = on_status
        self._ws = None
        self._thread = None
        self._stop = threading.Event()
        self._connected = False
        self._gen = 0

    @property
    def connected(self):
        return self._connected

    def start(self, ayyuid, top_sid, sub_sid):
        self.stop(notify=False)
        if websocket is None:
            self.on_status("弹幕未连接", False)
            self.on_message("系统", "缺少 websocket-client，无法连接弹幕", "#FF8A7C")
            return
        self._stop.clear()
        self._gen += 1
        gen = self._gen
        self.on_status("弹幕连接中", False)
        self._thread = threading.Thread(
            target=self._run,
            args=(int(ayyuid), int(top_sid), int(sub_sid), gen),
            daemon=True,
        )
        self._thread.start()

    def stop(self, notify=True):
        self._stop.set()
        self._gen += 1
        ws = self._ws
        self._ws = None
        if ws is not None:
            try:
                ws.close()
            except Exception:
                pass
        if self._thread and self._thread.is_alive() and threading.current_thread() is not self._thread:
            self._thread.join(timeout=1.2)
        self._thread = None
        self._connected = False
        if notify:
            self.on_status("弹幕未连接", False)

    def _alive(self, gen):
        return (not self._stop.is_set()) and self._gen == gen

    def _run(self, ayyuid, top_sid, sub_sid, gen):
        join = build_join(ayyuid, top_sid, sub_sid)
        while self._alive(gen):
            try:
                self.on_status("弹幕连接中", False)
                ws = websocket.WebSocket()
                ws.settimeout(20)
                ws.connect(
                    WS_URL,
                    header=["User-Agent: Mozilla/5.0"],
                    timeout=12,
                )
                if not self._alive(gen):
                    ws.close()
                    return
                self._ws = ws
                ws.send(join, opcode=websocket.ABNF.OPCODE_BINARY)
                self._connected = True
                self.on_status("弹幕已连接", True)
                last_hb = time.time()
                while self._alive(gen):
                    if time.time() - last_hb >= 60:
                        try:
                            ws.send(HEARTBEAT, opcode=websocket.ABNF.OPCODE_BINARY)
                        except Exception:
                            break
                        last_hb = time.time()
                    ws.settimeout(1.0)
                    try:
                        opcode, data = ws.recv_data()
                    except websocket.WebSocketTimeoutException:
                        continue
                    except Exception:
                        break
                    if opcode == websocket.ABNF.OPCODE_CLOSE:
                        break
                    if not data:
                        continue
                    chat = parse_chat(data)
                    if chat:
                        self.on_message(chat[0], chat[1], chat[2])
            except Exception as exc:
                self._connected = False
                if self._alive(gen):
                    self.on_status("弹幕未连接", False)
                    self.on_message("系统", "弹幕连接失败: %s" % exc, "#FF8A7C")
                    self._stop.wait(2.5)
            finally:
                ws = self._ws
                self._ws = None
                if self._gen == gen:
                    self._connected = False
                if ws is not None:
                    try:
                        ws.close()
                    except Exception:
                        pass
            if not self._alive(gen):
                break
        if self._gen == gen:
            self._connected = False
            self.on_status("弹幕未连接", False)
