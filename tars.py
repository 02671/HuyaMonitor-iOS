import struct

BYTE = 0
SHORT = 1
INT = 2
LONG = 3
FLOAT = 4
DOUBLE = 5
STRING1 = 6
STRING4 = 7
MAP = 8
LIST = 9
STRUCT_BEGIN = 10
STRUCT_END = 11
ZERO = 12
SIMPLE_LIST = 13


class TarsOutput:
    def __init__(self):
        self.buf = bytearray()

    def write_head(self, ttype, tag):
        if tag < 15:
            self.buf.append((tag << 4) | ttype)
        else:
            self.buf.append(0xF0 | ttype)
            self.buf.append(tag & 0xFF)

    def write_bool(self, value, tag):
        self.write_int(1 if value else 0, tag)

    def write_int(self, n, tag):
        n = int(n)
        if n == 0:
            self.write_head(ZERO, tag)
            return
        if -128 <= n <= 127:
            self.write_head(BYTE, tag)
            self.buf.append(n & 0xFF)
            return
        if -32768 <= n <= 32767:
            self.write_head(SHORT, tag)
            self.buf += struct.pack(">h", n)
            return
        if -2147483648 <= n <= 2147483647:
            self.write_head(INT, tag)
            self.buf += struct.pack(">i", n)
            return
        self.write_head(LONG, tag)
        self.buf += struct.pack(">q", n)

    def write_string(self, text, tag):
        data = text.encode("utf-8")
        if len(data) > 255:
            self.write_head(STRING4, tag)
            self.buf += struct.pack(">I", len(data))
        else:
            self.write_head(STRING1, tag)
            self.buf.append(len(data))
        self.buf += data

    def write_bytes(self, data, tag):
        self.write_head(SIMPLE_LIST, tag)
        self.write_head(BYTE, 0)
        self.write_int(len(data), 0)
        self.buf += data

    def write_struct_begin(self, tag):
        self.write_head(STRUCT_BEGIN, tag)

    def write_struct_end(self):
        self.write_head(STRUCT_END, 0)

    def to_bytes(self):
        return bytes(self.buf)


class TarsInput:
    def __init__(self, data):
        self.data = data if isinstance(data, (bytes, bytearray)) else bytes(data)
        self.pos = 0

    def remaining(self):
        return len(self.data) - self.pos

    def _u8(self):
        if self.pos >= len(self.data):
            raise EOFError("tars buffer overflow")
        b = self.data[self.pos]
        self.pos += 1
        return b

    def _read(self, n):
        if self.pos + n > len(self.data):
            raise EOFError("tars buffer overflow")
        chunk = self.data[self.pos:self.pos + n]
        self.pos += n
        return chunk

    def peek_head(self):
        saved = self.pos
        try:
            return self.read_head()
        finally:
            self.pos = saved

    def read_head(self):
        b = self._u8()
        ttype = b & 0x0F
        tag = (b & 0xF0) >> 4
        if tag == 15:
            tag = self._u8()
        return ttype, tag

    def skip_field(self, ttype=None):
        if ttype is None:
            ttype, _ = self.read_head()
        if ttype == BYTE:
            self._u8()
        elif ttype == SHORT:
            self._read(2)
        elif ttype == INT:
            self._read(4)
        elif ttype == LONG:
            self._read(8)
        elif ttype == FLOAT:
            self._read(4)
        elif ttype == DOUBLE:
            self._read(8)
        elif ttype == STRING1:
            n = self._u8()
            self._read(n)
        elif ttype == STRING4:
            n = struct.unpack(">I", self._read(4))[0]
            self._read(n)
        elif ttype == MAP:
            size = self.read_int(0, False)
            for _ in range(size):
                self.skip_field()
                self.skip_field()
        elif ttype == LIST:
            size = self.read_int(0, False)
            for _ in range(size):
                self.skip_field()
        elif ttype == STRUCT_BEGIN:
            while True:
                nested, _ = self.read_head()
                if nested == STRUCT_END:
                    break
                self.skip_field(nested)
        elif ttype == STRUCT_END:
            return
        elif ttype == ZERO:
            return
        elif ttype == SIMPLE_LIST:
            self.read_head()
            n = self.read_int(0, False)
            self._read(n)
        else:
            raise ValueError("unknown tars type %s" % ttype)

    def skip_to_tag(self, tag, required=False):
        while self.remaining() > 0:
            ttype, cur = self.peek_head()
            if ttype == STRUCT_END:
                return False
            if cur == tag:
                return True
            if cur > tag:
                return False
            self.read_head()
            self.skip_field(ttype)
        if required:
            raise KeyError("missing tag %s" % tag)
        return False

    def read_bool(self, tag, required=False, default=False):
        return bool(self.read_int(tag, required, 1 if default else 0))

    def read_int(self, tag, required=False, default=0):
        if not self.skip_to_tag(tag, required):
            return default
        ttype, _ = self.read_head()
        if ttype == ZERO:
            return 0
        if ttype == BYTE:
            b = self._u8()
            return b - 256 if b > 127 else b
        if ttype == SHORT:
            return struct.unpack(">h", self._read(2))[0]
        if ttype == INT:
            return struct.unpack(">i", self._read(4))[0]
        if ttype == LONG:
            return struct.unpack(">q", self._read(8))[0]
        raise ValueError("not int type %s" % ttype)

    def read_string(self, tag, required=False, default=""):
        if not self.skip_to_tag(tag, required):
            return default
        ttype, _ = self.read_head()
        if ttype == ZERO:
            return ""
        if ttype == STRING1:
            n = self._u8()
            return self._read(n).decode("utf-8", "replace")
        if ttype == STRING4:
            n = struct.unpack(">I", self._read(4))[0]
            return self._read(n).decode("utf-8", "replace")
        raise ValueError("not string type %s" % ttype)

    def read_bytes(self, tag, required=False, default=b""):
        if not self.skip_to_tag(tag, required):
            return default
        ttype, _ = self.read_head()
        if ttype == ZERO:
            return b""
        if ttype == SIMPLE_LIST:
            self.read_head()
            n = self.read_int(0, False)
            return self._read(n)
        if ttype == LIST:
            n = self.read_int(0, False)
            out = bytearray()
            for _ in range(n):
                out.append(self.read_int(0, False) & 0xFF)
            return bytes(out)
        raise ValueError("not bytes type %s" % ttype)

    def read_struct_bytes(self, tag, required=False):
        if not self.skip_to_tag(tag, required):
            return None
        ttype, _ = self.read_head()
        if ttype != STRUCT_BEGIN:
            raise ValueError("not struct type %s" % ttype)
        start = self.pos
        depth = 1
        while depth > 0:
            nested, _ = self.read_head()
            if nested == STRUCT_BEGIN:
                depth += 1
            elif nested == STRUCT_END:
                depth -= 1
            else:
                self.skip_field(nested)
        return self.data[start:self.pos - 1]
