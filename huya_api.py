import hashlib
import json
import random
import time
import urllib.parse
import urllib.request
import ssl
import base64

MOBILE_UA = (
    "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36"
)
PLAY_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)

_SSL = ssl.create_default_context()


class HuyaError(RuntimeError):
    pass


def _http_get(url, headers=None, timeout=12):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout, context=_SSL) as resp:
        return resp.read()


def _http_post_json(url, payload, headers=None, timeout=12):
    body = json.dumps(payload).encode("utf-8")
    hdrs = {"Content-Type": "application/json"}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=body, headers=hdrs)
    with urllib.request.urlopen(req, timeout=timeout, context=_SSL) as resp:
        return json.loads(resp.read().decode("utf-8"))


def normalize_room_id(text):
    text = (text or "").strip()
    if not text:
        raise HuyaError("请输入房号")
    if "huya.com" in text:
        path = urllib.parse.urlparse(text).path.strip("/")
        text = path.split("/")[-1]
    if not text.isdigit():
        raise HuyaError("房号必须是数字")
    return text


def parse_search_results(payload):
    response = payload.get("response") if isinstance(payload, dict) else None
    if not isinstance(response, dict):
        response = payload if isinstance(payload, dict) else {}
    block = response.get("1") or {}
    docs = block.get("docs") if isinstance(block, dict) else []
    out = []
    seen = set()
    for doc in docs or []:
        if not isinstance(doc, dict):
            continue
        room_id = str(doc.get("room_id") or doc.get("game_privateHost") or "").strip()
        nick = str(doc.get("game_nick") or "").strip()
        live_on = bool(doc.get("gameLiveOn"))
        if not room_id or room_id in seen:
            continue
        seen.add(room_id)
        out.append({"room_id": room_id, "nick": nick, "live_on": live_on})
    out.sort(key=lambda x: (0 if x["live_on"] else 1, x["nick"]))
    return out


def search_anchors(keyword):
    keyword = (keyword or "").strip()
    if not keyword:
        raise HuyaError("请输入搜索内容")
    url = "https://search.cdn.huya.com/?m=Search&do=getSearchContent&q=%s&typ=-5&rows=30" % urllib.parse.quote(keyword)
    headers = {
        "User-Agent": PLAY_UA,
        "Referer": "https://www.huya.com/",
        "Accept": "application/json,text/plain,*/*",
    }
    raw = _http_get(url, headers=headers)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise HuyaError("搜索结果解析失败") from exc
    return parse_search_results(payload)


def fetch_room(room_id):
    room_id = normalize_room_id(room_id)
    url = "https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=" + room_id
    headers = {
        "User-Agent": MOBILE_UA,
        "Referer": "https://m.huya.com/" + room_id,
        "Accept": "application/json,text/plain,*/*",
    }
    raw = _http_get(url, headers=headers)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise HuyaError("房间信息解析失败") from exc
    if payload.get("status") != 200 or not payload.get("data"):
        raise HuyaError(payload.get("message") or "房间不存在")
    data = payload["data"]
    profile = data.get("profileInfo") or {}
    live = data.get("liveData") or {}
    stream = data.get("stream") or {}
    lines = stream.get("baseSteamInfoList") or []
    live_on = str(data.get("liveStatus") or "").upper() == "ON"
    return {
        "room_id": str(profile.get("profileRoom") or live.get("profileRoom") or room_id),
        "nick": profile.get("nick") or live.get("nick") or "",
        "title": live.get("roomName") or live.get("introduction") or "",
        "live_on": live_on,
        "yyid": int(profile.get("yyid") or live.get("yyid") or 0),
        "uid": int(profile.get("uid") or live.get("uid") or 0),
        "top_sid": int(data.get("chTopId") or live.get("channel") or 0),
        "sub_sid": int(data.get("subChId") or live.get("liveChannel") or 0),
        "lines": lines,
    }


def _uuid():
    now = time.time() * 1000
    rand = random.randint(0, 1000)
    return int((now % 10000000000 * 1000 + rand) % 4294967295)


def anonymous_uid():
    try:
        resp = _http_post_json(
            "https://udblgn.huya.com/web/anonymousLogin",
            {"appId": 5002, "byPass": 3, "context": "", "version": "2.4", "data": {}},
            headers={"User-Agent": MOBILE_UA},
        )
        return str(resp["data"]["uid"])
    except Exception:
        return str(int(time.time() * 1000) % 10000000000)


def process_anticode(anticode, uid, stream_name):
    q = dict(urllib.parse.parse_qs(anticode))
    q["ver"] = ["1"]
    q["sv"] = ["2110211124"]
    q["seqid"] = [str(int(uid) + int(time.time() * 1000))]
    q["uid"] = [str(uid)]
    q["uuid"] = [str(_uuid())]
    ss = hashlib.md5(
        "{}|{}|{}".format(q["seqid"][0], q["ctype"][0], q["t"][0]).encode("utf-8")
    ).hexdigest()
    fm = base64.b64decode(q["fm"][0]).decode("utf-8")
    fm = fm.replace("$0", q["uid"][0]).replace("$1", stream_name).replace("$2", ss).replace("$3", q["wsTime"][0])
    q["wsSecret"] = [hashlib.md5(fm.encode("utf-8")).hexdigest()]
    q.pop("fm", None)
    q.pop("txyp", None)
    return urllib.parse.urlencode({k: v[0] for k, v in q.items()})


def _valid_lines(room):
    out = []
    for line in room.get("lines") or []:
        flv_url = line.get("sFlvUrl") or ""
        name = line.get("sStreamName") or ""
        anticode = line.get("sFlvAntiCode") or ""
        if flv_url and name and anticode:
            out.append(line)
    return out


def build_play_url(room, line_index=0):
    if not room.get("live_on"):
        raise HuyaError("该房间未开播")
    lines = _valid_lines(room)
    if not lines:
        raise HuyaError("未拿到直播流地址")
    uid = anonymous_uid()
    last_error = None
    count = len(lines)
    for offset in range(count):
        line = lines[(line_index + offset) % count]
        flv_url = line.get("sFlvUrl") or ""
        name = line.get("sStreamName") or ""
        suffix = line.get("sFlvUrlSuffix") or "flv"
        anticode = line.get("sFlvAntiCode") or ""
        try:
            params = process_anticode(anticode, uid, name)
            url = "{}/{}.{}?{}".format(flv_url.rstrip("/"), name, suffix, params)
            if url.startswith("http://"):
                url = "https://" + url[len("http://"):]
            if "ratio=" not in url:
                url += "&ratio=2000"
            return url, (line_index + offset) % count
        except Exception as exc:
            last_error = exc
    raise HuyaError("直播流签名失败") from last_error
