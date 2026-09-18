import os
import shutil
import subprocess
import threading
import time

from huya_api import PLAY_UA, build_play_url, fetch_room


def find_ffplay():
    here = os.path.dirname(os.path.abspath(__file__))
    names = ["ffplay.exe", "ffplay"]
    search = [
        os.path.join(here, "bin"),
        os.path.join(here, "ffmpeg"),
        os.path.join(os.path.dirname(here), "bin"),
        os.getcwd(),
        os.path.join(os.getcwd(), "bin"),
    ]
    for folder in search:
        for name in names:
            path = os.path.join(folder, name)
            if os.path.isfile(path):
                return path
    return shutil.which("ffplay") or shutil.which("ffplay.exe")


REFRESH_SEC = 120
OVERLAP_SEC = 2.0


def _win_set_pid_volume(pid, level):
    if os.name != "nt" or not pid:
        return False
    try:
        return _win_set_pid_volume_impl(pid, level)
    except Exception:
        return False


def _win_set_pid_volume_impl(pid, level):
    import ctypes
    from ctypes import HRESULT, POINTER, byref, c_float, c_int, c_uint32, c_void_p

    class GUID(ctypes.Structure):
        _fields_ = [
            ("Data1", ctypes.c_uint32),
            ("Data2", ctypes.c_uint16),
            ("Data3", ctypes.c_uint16),
            ("Data4", ctypes.c_ubyte * 8),
        ]

        def __init__(self, d1, d2, d3, d4):
            super().__init__(d1, d2, d3, (ctypes.c_ubyte * 8)(*d4))

    def vtbl(obj, index, restype, *argtypes):
        p = ctypes.cast(obj, POINTER(POINTER(c_void_p)))
        fn = ctypes.WINFUNCTYPE(restype, c_void_p, *argtypes)(p.contents[index])
        return lambda *a: fn(obj, *a)

    CLSID_MMDeviceEnumerator = GUID(0xBCDE0395, 0xE52F, 0x467C, (0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E))
    IID_IMMDeviceEnumerator = GUID(0xA95664D2, 0x9614, 0x4F35, (0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6))
    IID_IAudioSessionManager2 = GUID(0x77AA99A0, 0x1BD6, 0x484F, (0x8B, 0xC7, 0x2C, 0x65, 0x4C, 0x9A, 0x9B, 0x6F))
    IID_IAudioSessionControl2 = GUID(0xBFB7FF88, 0x7239, 0x4FC9, (0x8F, 0xA2, 0x07, 0xC9, 0x50, 0xBE, 0x9C, 0x6D))
    IID_ISimpleAudioVolume = GUID(0x87CE5498, 0x68D6, 0x44E5, (0x92, 0x15, 0x6D, 0xA4, 0x7E, 0xF8, 0x83, 0xD8))

    ole32 = ctypes.windll.ole32
    ole32.CoInitialize.argtypes = [c_void_p]
    ole32.CoInitialize.restype = HRESULT
    ole32.CoCreateInstance.argtypes = [
        POINTER(GUID), c_void_p, ctypes.c_uint32, POINTER(GUID), POINTER(c_void_p)
    ]
    ole32.CoCreateInstance.restype = HRESULT
    ole32.CoInitialize(None)
    enumerator = c_void_p()
    hr = ole32.CoCreateInstance(
        byref(CLSID_MMDeviceEnumerator),
        None,
        7,
        byref(IID_IMMDeviceEnumerator),
        byref(enumerator),
    )
    if hr != 0 or not enumerator:
        return False
    try:
        device = c_void_p()
        hr = vtbl(enumerator, 4, HRESULT, c_int, c_int, POINTER(c_void_p))(0, 1, byref(device))
        if hr != 0 or not device:
            return False
        try:
            manager = c_void_p()
            hr = vtbl(device, 3, HRESULT, POINTER(GUID), ctypes.c_uint32, c_void_p, POINTER(c_void_p))(
                byref(IID_IAudioSessionManager2), 7, None, byref(manager)
            )
            if hr != 0 or not manager:
                return False
            try:
                sess_enum = c_void_p()
                hr = vtbl(manager, 5, HRESULT, POINTER(c_void_p))(byref(sess_enum))
                if hr != 0 or not sess_enum:
                    return False
                try:
                    count = c_int(0)
                    if vtbl(sess_enum, 3, HRESULT, POINTER(c_int))(byref(count)) != 0:
                        return False
                    found = False
                    for i in range(count.value):
                        control = c_void_p()
                        if vtbl(sess_enum, 4, HRESULT, c_int, POINTER(c_void_p))(i, byref(control)) != 0:
                            continue
                        try:
                            control2 = c_void_p()
                            if vtbl(control, 0, HRESULT, POINTER(GUID), POINTER(c_void_p))(
                                byref(IID_IAudioSessionControl2), byref(control2)
                            ) != 0 or not control2:
                                continue
                            try:
                                proc_id = c_uint32(0)
                                if vtbl(control2, 14, HRESULT, POINTER(c_uint32))(byref(proc_id)) != 0:
                                    continue
                                if int(proc_id.value) != int(pid):
                                    continue
                                volume = c_void_p()
                                if vtbl(control2, 0, HRESULT, POINTER(GUID), POINTER(c_void_p))(
                                    byref(IID_ISimpleAudioVolume), byref(volume)
                                ) != 0 or not volume:
                                    continue
                                try:
                                    vol = max(0.0, min(1.0, float(level)))
                                    if vtbl(volume, 3, HRESULT, c_float, c_void_p)(c_float(vol), None) == 0:
                                        found = True
                                finally:
                                    vtbl(volume, 2, ctypes.c_ulong)()
                            finally:
                                vtbl(control2, 2, ctypes.c_ulong)()
                        finally:
                            vtbl(control, 2, ctypes.c_ulong)()
                    return found
                finally:
                    vtbl(sess_enum, 2, ctypes.c_ulong)()
            finally:
                vtbl(manager, 2, ctypes.c_ulong)()
        finally:
            vtbl(device, 2, ctypes.c_ulong)()
    finally:
        vtbl(enumerator, 2, ctypes.c_ulong)()


class AudioPlayer:
    def __init__(self, on_status):
        self.on_status = on_status
        self._proc = None
        self._overlap = None
        self._loop = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._room_id = ""
        self._line_index = 0
        self._wanted = False
        self._gen = 0
        self._volume = 100

    @property
    def connected(self):
        return self._wanted

    @property
    def volume(self):
        return self._volume

    def set_volume(self, value):
        try:
            n = int(round(float(value)))
        except Exception:
            return
        self._volume = max(0, min(100, n))
        threading.Thread(target=self._apply_volume, daemon=True).start()

    def start(self, room):
        ffplay = find_ffplay()
        if not ffplay:
            self._wanted = False
            self.on_status("音频未连接", False)
            raise RuntimeError("未找到 ffplay，请把 ffmpeg 的 ffplay.exe 放到本目录 bin 文件夹")
        self.stop(notify=False)
        self._stop.clear()
        self._wanted = True
        self._gen += 1
        gen = self._gen
        self._room_id = str(room.get("room_id") or "")
        self._line_index = 0
        self._loop = threading.Thread(target=self._run, args=(ffplay, gen), daemon=True)
        self._loop.start()
        self.on_status("音频连接中", False)

    def _spawn(self, ffplay, url):
        cmd = [
            ffplay,
            "-nodisp",
            "-vn",
            "-autoexit",
            "-loglevel",
            "quiet",
            "-volume",
            str(self._volume),
            "-user_agent",
            PLAY_UA,
            "-headers",
            "Referer: https://www.huya.com/\r\n",
            "-i",
            url,
        ]
        creationflags = 0
        startupinfo = None
        if os.name == "nt":
            creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        return subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creationflags,
            startupinfo=startupinfo,
        )

    def _kill_proc(self, proc):
        if proc is None:
            return
        try:
            proc.terminate()
        except Exception:
            pass
        try:
            proc.wait(timeout=1.2)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass

    def _pids(self):
        with self._lock:
            procs = [self._proc, self._overlap]
        out = []
        for proc in procs:
            if proc is not None and proc.poll() is None:
                out.append(proc.pid)
        return out

    def _apply_volume(self):
        level = self._volume / 100.0
        for _ in range(8):
            pids = self._pids()
            if not pids:
                return
            ok = True
            for pid in pids:
                if not _win_set_pid_volume(pid, level):
                    ok = False
            if ok:
                return
            time.sleep(0.25)

    def _playing(self):
        return bool(self._pids())

    def _swap_proc(self, proc):
        with self._lock:
            leftover = self._overlap
            self._overlap = self._proc
            self._proc = proc
        self._kill_proc(leftover)
        return self._overlap

    def _clear_if_current(self, proc):
        with self._lock:
            if self._proc is proc:
                self._proc = None
            if self._overlap is proc:
                self._overlap = None

    def _run(self, ffplay, gen):
        fail = 0
        first = True
        while not self._stop.is_set() and self._gen == gen:
            try:
                if first:
                    self.on_status("音频连接中", False)
                room = fetch_room(self._room_id)
                url, self._line_index = build_play_url(room, self._line_index)
                proc = self._spawn(ffplay, url)
            except Exception:
                if self._stop.is_set() or self._gen != gen:
                    break
                fail += 1
                if not self._playing():
                    self.on_status("音频重连中", False)
                self._stop.wait(min(8, 1.2 * fail))
                self._line_index += 1
                first = False
                continue
            overlap = self._swap_proc(proc)
            fail = 0
            first = False
            self.on_status("音频已连接", True)
            threading.Thread(target=self._apply_volume, daemon=True).start()
            if overlap is not None:
                if self._stop.wait(OVERLAP_SEC) or self._gen != gen:
                    break
                self._kill_proc(overlap)
                with self._lock:
                    if self._overlap is overlap:
                        self._overlap = None
            started = time.time()
            died = False
            while not self._stop.is_set() and self._gen == gen:
                code = proc.poll()
                if code is not None:
                    died = True
                    break
                if time.time() - started >= REFRESH_SEC:
                    break
                time.sleep(0.35)
            if self._stop.is_set() or self._gen != gen:
                break
            if died:
                self._clear_if_current(proc)
                self._kill_proc(proc)
                self.on_status("音频重连中", False)
                self._line_index += 1
                self._stop.wait(0.4)
        if self._gen == gen:
            self._wanted = False
            self.on_status("音频未连接", False)

    def stop(self, notify=True):
        self._wanted = False
        self._gen += 1
        self._stop.set()
        with self._lock:
            procs = [self._proc, self._overlap]
            self._proc = None
            self._overlap = None
        for proc in procs:
            self._kill_proc(proc)
        loop = self._loop
        self._loop = None
        if loop and loop.is_alive() and threading.current_thread() is not loop:
            loop.join(timeout=1.8)
        if notify:
            self.on_status("音频未连接", False)
