"""Search and download subtitles from opensubtitles.org's public site, no account needed.

  sub_find.py --search VIDEO LANGS [QUERY]    LANGS is comma separated, e.g. pob,eng;
                                              QUERY is typed text such as "Title S05E12"
  sub_find.py --download ID LANG VIDEO

Every answer is one line, SUBFIND_JSON:<json>, so main.lua can find it in the output.
"""

import io
import json
import os
import re
import struct
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

SITE = "https://www.opensubtitles.org/en/search/sublanguageid-{lang}/{key}/rss_2_00"
DOWNLOAD = "https://dl.opensubtitles.org/en/download/sub/{id}"
HEADERS = {"User-Agent": "Mozilla/5.0"}
MAX_BYTES = 5_000_000
SUB_EXTS = (".srt", ".ass", ".ssa")
VENDOR = Path(__file__).resolve().parent.parent / "anilistUpdater" / "vendor"

# The tag Jellyfin and mpv read back as the language, keyed by the site's own codes.
LANG_TAGS = {"pob": "pt-BR", "por": "pt", "eng": "en", "spa": "es", "fre": "fr", "ger": "de", "ita": "it", "jpn": "ja"}


def answer(payload):
    print("SUBFIND_JSON:" + json.dumps(payload, ensure_ascii=False), flush=True)


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=20) as r:
        data = r.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError(f"{url} answered more than {MAX_BYTES} bytes")
    return data


def movie_hash(path):
    # OpenSubtitles' hash: size plus the 64-bit little-endian words of the first and last 64 KiB.
    size = os.path.getsize(path)
    if size < 65536 * 2:
        return None
    h = size
    with open(path, "rb") as f:
        for offset in (0, size - 65536):
            f.seek(offset)
            h += sum(struct.unpack("<8192Q", f.read(65536)))
    return f"{h & 0xFFFFFFFFFFFFFFFF:016x}"


def imdb_id(video):
    # Jellyfin and Kodi leave an .nfo with the episode's IMDb id next to the video.
    nfo = Path(video).with_suffix(".nfo")
    if not nfo.is_file():
        return None
    m = re.search(r"<imdbid>tt(\d+)</imdbid>", nfo.read_text(encoding="utf-8", errors="replace"))
    return m.group(1) if m else None


def first(value):
    return value[0] if isinstance(value, list) else value


def guess(video):
    """Title, year, season and episode from the path, through guessit when `just setup` vendored it."""
    path = Path(video)
    try:
        sys.path.insert(0, str(VENDOR))
        from guessit import guessit

        g = guessit(str(path))
        info = {k: first(g.get(k)) for k in ("title", "year", "season", "episode")}
    except ImportError:
        m = re.search(r"^(.*?)[ ._-]+s(\d{1,2})e(\d{1,3})", path.stem, re.I)
        if m:
            info = {"title": m.group(1), "year": None, "season": int(m.group(2)), "episode": int(m.group(3))}
        else:
            m = re.search(r"^(.*?)[ ._(\[]+((?:19|20)\d\d)\b", path.stem)
            info = {
                "title": m.group(1) if m else path.stem,
                "year": int(m.group(2)) if m else None,
                "season": None,
                "episode": None,
            }
        info["title"] = re.sub(r"[._]+", " ", info["title"]).strip()
    # "9 - Bug.mp4" inside a season folder: the leading number is the episode.
    if info["season"] and not info["episode"]:
        m = re.match(r"(\d{1,3})\b", path.stem)
        info["episode"] = int(m.group(1)) if m else None
    # Fansub names ("Frieren - 05") carry no season; a title-only search would list every episode.
    if info["episode"] and not info["season"]:
        info["season"] = 1
    return info


def parse_query(query):
    """A typed search: "Title S05E12" for an episode, "Title 1999" for a film, or just a title."""
    query = query.strip()
    m = re.match(r"^(.*?)\s+s(\d{1,2})e(\d{1,4})$", query, re.I)
    if m:
        return {"title": m.group(1), "year": None, "season": int(m.group(2)), "episode": int(m.group(3))}
    m = re.match(r"^(.*?)\s+((?:19|20)\d\d)$", query)
    if m:
        return {"title": m.group(1), "year": int(m.group(2)), "season": None, "episode": None}
    return {"title": query or None, "year": None, "season": None, "episode": None}


def as_query(info):
    """The inverse of parse_query, so the menu can show the guess as editable text."""
    if not info["title"]:
        return ""
    if info["season"] and info["episode"]:
        return f"{info['title']} S{info['season']:02d}E{info['episode']:02d}"
    return " ".join(str(x) for x in (info["title"], info["year"]) if x)


def title_key(info):
    if not info["title"]:
        return None
    if info["season"] and info["episode"]:
        name = urllib.parse.quote(str(info["title"]))
        return f"searchonlytvseries-on/season-{info['season']}/episode-{info['episode']}/moviename-{name}"
    name = urllib.parse.quote(" ".join(str(x) for x in (info["title"], info["year"]) if x))
    return f"moviename-{name}"


def rss(lang, key):
    for item in ET.fromstring(fetch(SITE.format(lang=lang, key=key))).iter("item"):
        m = re.search(r"/subtitles/(\d+)/", item.findtext("link") or "")
        if not m:
            continue
        desc = item.findtext("description") or ""
        release = re.search(r"Released as:\s*(.*?);", desc, re.S)
        downloads = re.search(r"-\s*(\d+)x", desc)
        yield {
            "id": m.group(1),
            "lang": lang,
            "release": release.group(1).strip() if release else "",
            "downloads": int(downloads.group(1)) if downloads else 0,
        }


def tokens(text):
    return set(re.findall(r"[a-z0-9]+", text.lower()))


def search(video, langs, query=None):
    found = {}
    file_hash = movie_hash(video)
    # A typed query overrides both the .nfo and the guess from the file name.
    imdb = None if query else imdb_id(video)
    info = parse_query(query) if query else guess(video)
    key = f"imdbid-{imdb}" if imdb else title_key(info)
    stem = tokens(Path(video).stem)
    for lang in langs:
        if file_hash:
            for c in rss(lang, f"moviehash-{file_hash}"):
                found[c["id"]] = {**c, "hash_match": True}
        if key:
            for c in rss(lang, key):
                found.setdefault(c["id"], {**c, "hash_match": False})
    for c in found.values():
        rel = tokens(c["release"])
        c["similarity"] = round(len(rel & stem) / len(rel | stem), 3) if rel else 0.0

    rank = {lang: i for i, lang in enumerate(langs)}
    ordered = sorted(
        found.values(),
        key=lambda c: (rank[c["lang"]], not c["hash_match"], -c["similarity"], -c["downloads"]),
    )
    answer({"hash": file_hash, "imdb": imdb, "guess": info, "query": as_query(info), "results": ordered})


def decode(raw):
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            pass
    return raw.decode("latin-1")


def download(sub_id, lang, video):
    data = fetch(DOWNLOAD.format(id=sub_id))
    if not data.startswith(b"PK"):
        raise ValueError(f"subtitle {sub_id} did not come back as a zip")
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = [n for n in z.namelist() if n.lower().endswith(SUB_EXTS)]
        if not names:
            raise ValueError(f"subtitle {sub_id} has no .srt or .ass inside")
        name = names[0]
        body = decode(z.read(name)).replace("\r\n", "\n")

    ext = Path(name).suffix.lower()
    base = Path(video).with_suffix("")
    tag = LANG_TAGS.get(lang, lang)
    dest = Path(f"{base}.{tag}{ext}")
    if dest.exists():
        dest = Path(f"{base}.{tag}.{sub_id}{ext}")
    if dest.exists():
        answer({"path": str(dest), "existed": True})
        return
    dest.write_text(body, encoding="utf-8")
    answer({"path": str(dest), "existed": False})


def main():
    try:
        if sys.argv[1] == "--search":
            search(sys.argv[2], [l for l in sys.argv[3].split(",") if l], sys.argv[4] if len(sys.argv) > 4 else None)
        elif sys.argv[1] == "--download":
            download(sys.argv[2], sys.argv[3], sys.argv[4])
        else:
            raise ValueError(f"unknown command {sys.argv[1]}")
    except Exception as e:  # main.lua shows the message on screen instead of failing silently
        answer({"error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    main()
