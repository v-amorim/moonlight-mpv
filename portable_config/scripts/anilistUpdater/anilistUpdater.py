# https://github.com/AzuredBlue/mpv-anilist-updater

import json
import os
import re
import sys
import webbrowser

# Piped to mpv, stdout defaults to the ANSI codepage, so one CJK character in a
# filename kills the process before it can print anything useful.
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# mpv launches this by absolute path from whatever directory it happens to be
# in, so none of these can be left to the working directory or to PATH.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
# `just setup` fills vendor/. The Lib beside mpv.exe is the fallback, since SVP
# ships one and an existing install may still be relying on it.
sys.path.insert(1, os.path.join(_HERE, "vendor"))
sys.path.append(os.path.join(_HERE, "..", "..", "..", "Lib"))
import overrides
import token_store

# A missing package used to surface as a raw traceback, which the menu could
# only report as "it did not open". Named plainly instead, with the fix.
MISSING_DEPS = None
try:
    import requests
    from guessit import guessit
except ImportError as error:
    MISSING_DEPS = str(error)

# main.lua greps stdout for these, so it can theme the message it puts on screen.
NOT_LINKED = "ANILIST_NOT_LINKED"
EXPIRED = "ANILIST_EXPIRED"
NO_MATCH = "ANILIST_NO_MATCH"

# guessit prints a MatchesDict full of braces, so the payload needs a marker
# main.lua can anchor on rather than hunting for the first bracket.
JSON_PREFIX = "ANILIST_JSON:"
API_DOWN = "ANILIST_API_DOWN"


class AniListUpdater:
    ANILIST_API_URL = "https://graphql.anilist.co"

    # Load token and user id
    def __init__(self):
        self.access_token, self.cached_user_id, self.account_name = token_store.load()
        if not self.access_token:
            raise RuntimeError(f"{NOT_LINKED}: no AniList token stored, run the setup binding")
        self.user_id = self.get_user_id()

    # Load user id from the store, if not then make api request and save it.
    def get_user_id(self):
        if self.cached_user_id:
            return self.cached_user_id

        query = """
        query {
            Viewer {
                id
            }
        }
        """
        response = self.make_api_request(query, None, self.access_token)
        if response and "data" in response:
            user_id = response["data"]["Viewer"]["id"]
            self.save_user_id(user_id)
            return user_id
        return None

    # Cache user id
    def save_user_id(self, user_id):
        token_store.save(self.access_token, user_id, self.account_name)

    # Function to make an api request to AniList's api
    def make_api_request(self, query, variables=None, access_token=None):
        headers = {"Content-Type": "application/json", "Accept": "application/json"}

        # AniList refuses anonymous queries, so every request carries the token,
        # not just the ones that write to your list.
        token = access_token or self.access_token
        if token:
            headers["Authorization"] = f"Bearer {token}"

        response = requests.post(
            self.ANILIST_API_URL,
            json={"query": query, "variables": variables},
            headers=headers,
        )
        if response.status_code == 200:
            return response.json()

        # AniList tokens last a year, so a rejected one is almost always expired.
        if response.status_code in (400, 401):
            raise RuntimeError(f"{EXPIRED}: AniList rejected the token, run the setup binding again")

        # Their side, not ours. Must not read as "no match", or the picker opens
        # asking you to fix a guess that was never made.
        if response.status_code == 403 or response.status_code >= 500:
            raise RuntimeError(f"{API_DOWN}: AniList returned {response.status_code}, try again later")

        print(f"API request failed: {response.status_code} - {response.text}")
        return None

    # Fetches one anime plus its PREQUEL/SEQUEL relations, for chain walking
    def _fetch_with_relations(self, anime_id):
        query = """
        query ($id: Int) {
            Media(id: $id, type: ANIME) {
                id
                title { romaji }
                season
                seasonYear
                episodes
                duration
                status
                relations {
                    edges {
                        relationType
                        node { id format }
                    }
                }
            }
        }
        """
        response = self.make_api_request(query, {"id": anime_id})
        if response and "data" in response:
            return response["data"]["Media"]
        return None

    # Gets just enough seasons around an anime to cover an absolute episode
    # number, by walking its PREQUEL/SEQUEL relation chain outward from it.
    # Title search breaks once a season's own title (e.g. "2nd Season") no
    # longer fuzzy-matches its prequel, so this walks relations instead.
    # Stopping as soon as the chain covers the target also keeps it from
    # wandering into unrelated bonus prequels/sequels (side stories, recaps)
    # that sit further out on the same relation graph.
    def get_anime_seasons(self, anime_id, absolute_episode):
        def linked(media, relation_type):
            for edge in media["relations"]["edges"]:
                if edge["relationType"] == relation_type and edge["node"]["format"] in ("TV", "ONA"):
                    return edge["node"]["id"]
            return None

        anchor = self._fetch_with_relations(anime_id)
        if anchor is None:
            return []

        chain = [anchor]
        total = anchor["episodes"] or 0
        visited = {anime_id}

        node = anchor
        while total < absolute_episode:
            prequel_id = linked(node, "PREQUEL")
            if not prequel_id or prequel_id in visited:
                break
            visited.add(prequel_id)
            node = self._fetch_with_relations(prequel_id)
            chain.insert(0, node)
            total += node["episodes"] or 0

        node = chain[-1]
        while total < absolute_episode:
            sequel_id = linked(node, "SEQUEL")
            if not sequel_id or sequel_id in visited:
                break
            visited.add(sequel_id)
            node = self._fetch_with_relations(sequel_id)
            chain.append(node)
            total += node["episodes"] or 0

        return chain

    # Finds the season and episode of an anime with absolute numbering
    def find_season_and_episode(self, anime_id, absolute_episode):
        seasons = self.get_anime_seasons(anime_id, absolute_episode)
        accumulated_episodes = 0
        for season_number, season in enumerate(seasons, start=1):
            season_episodes = season["episodes"]
            if season_episodes and accumulated_episodes + season_episodes >= absolute_episode:
                return (
                    season["title"]["romaji"],
                    season["id"],
                    absolute_episode - accumulated_episodes,
                    season_number,
                )
            accumulated_episodes += season_episodes or 0
        return None

    # When the raw file episode is above the matched entry's total, resolves
    # what season/episode it actually corresponds to, for the menu to display.
    def season_hint(self, match, episode):
        entry = match.get("entry") if match else None
        if isinstance(episode, list):
            episode = min(episode)
        if not entry or not entry.get("episodes") or episode <= entry["episodes"]:
            return None
        result = self.find_season_and_episode(match["id"], episode)
        if not result:
            return None
        _, _, new_episode, season_number = result
        return {"season": season_number, "episode": new_episode}

    def handle_filename(self, filename):
        file_info = self.parse_filename(filename)

        pinned = overrides.get(file_info["key"])
        if pinned:
            anime_id, actual_name = pinned["id"], pinned["title"]
        else:
            found = self.get_anime_info(file_info["name"], file_info["year"])
            if not found:
                # main.lua opens the picker on this, seeded with what was guessed.
                print(f"{NO_MATCH}: {file_info['name']}")
                return
            anime_id, actual_name = found

        self.update_episode_count(anime_id, file_info["episode"], actual_name)

    # Hardcoded exceptions to fix detection
    # Easier than just renaming my files 1 by 1 on Qbit
    # Every exception I find will be added here
    def fix_filename(self, filename):
        guess = guessit(
            filename, {"type": "episode"}
        )  # Simply easier for fixing the filename if we have what it is detecting.

        # Ranma 1/2 1 detected as episodes [1,2]
        if "Ranma" in guess["title"] and guess["episode"] == [1, 2]:
            filename = filename.replace("1_2", "").replace("1/2", "")

        # Chi - Chikyuu no Undou ni Tsuite detected as 'Chi'
        if guess["title"] == "Chi":
            filename = filename.replace(" - ", " ")

        # Bleach TYBW, TYBW gets detected as alternative_title.
        # This doesn't fix some, you'd have to manually rename the files to Bleach Thousand Year Blood War E${i}
        if (
            guess["title"] == "Bleach"
            and "alternative_title" in guess
            and (
                "Thousand Year Blood War" in guess["alternative_title"]
                or "Sennen Kessen-hen" in guess["alternative_title"]
            )
        ):
            filename = filename.replace("-", " ")

        if "language" in guess and (guess["language"] == "ko" and guess["title"] == "Oshi no"):
            filename = filename.replace("Oshi no Ko", "Oshi noKo")

        return filename

    # Parse the file name using guessit
    def parse_filename(self, filepath):
        path_parts = filepath.replace("\\", "/").split("/")
        filename = self.fix_filename(path_parts[-1])
        folder_name = path_parts[-2] if len(path_parts) > 1 else ""

        name, season, part, year = "", "", "", ""
        episode = 1

        # First, try to guess from the filename
        guess = guessit(filename, {"type": "episode"})
        print(f"File name guess: {guess!s}")

        # Episode guess from the title.
        # Usually, releases are formated [Release Group] Title - S01EX

        # If the episode index is 0, that would mean that the episode is before the title in the filename
        # Which is a horrible way of formatting it, so assume its wrong

        # If its 1, then the title is probably 0, so its okay. (Unless season is 0)
        # Really? What is the format "S1E1 - {title}"? That's almost psycopathic.

        # If its >2, theres probably a Release Group and Title / Season / Part, so its good

        episode = guess.get("episode", 1)
        season = str(guess.get("season", ""))
        part = str(guess.get("part", ""))
        year = str(guess.get("year", ""))

        keys = list(guess.keys())
        episode_index = keys.index("episode") if "episode" in guess else 1
        season_index = keys.index("season") if "season" in guess else -1
        title_in_filename = "title" in guess and (episode_index > 0 and (season_index > 0 or season_index == -1))

        # If the title is not in the filename or episode index is 0, try the folder name
        # If the episode index > 0 and season index > 0, its safe to assume that the title is in the file name

        if title_in_filename:
            name = guess["title"]
        else:
            # If it isnt in the name of the file, try to guess using the name of the folder it is stored in
            folder_guess = guessit(folder_name, {"type": "episode"})
            print(f"Folder guess: {folder_guess!s}")

            name = str(folder_guess.get("title", ""))
            season = season or str(folder_guess.get("season", ""))
            part = part or str(folder_guess.get("part", ""))
            year = year or str(folder_guess.get("year", ""))

        # Add season and part if there are
        if season and (int(season) > 1 or part):
            name += f" Season {season}"

        if part:
            name += f" Part {part}"

        print(f"Guessed name: {name}")

        # Cours of the same show share a title, so a pin keyed on the name alone
        # would drag every other Bleach onto whichever one was picked. The
        # subtitle fields are what actually tell them apart.
        key = "|".join(
            field.strip().lower()
            for field in (
                str(guess.get("title", "")),
                str(guess.get("episode_title", "")),
                str(guess.get("alternative_title", "")),
                str(season),
                str(part),
            )
        )

        return {
            "name": name,
            "episode": episode,
            "year": year,
            "key": key,
        }

    # Candidate entries for the picker, richest first field being what it shows
    def search(self, query, limit=15):
        graphql = """
        query ($search: String, $perPage: Int) {
            Page(perPage: $perPage) {
                media(search: $search, type: ANIME) {
                    id
                    siteUrl
                    format
                    episodes
                    startDate { year }
                    title { romaji english }
                    coverImage { medium }
                }
            }
        }
        """
        response = self.make_api_request(graphql, {"search": query, "perPage": limit})
        return [self._entry(media) for media in response["data"]["Page"]["media"]]

    # What the user already has saved for this anime. Read-only, and its own
    # query because get_episode_count changes shape when there is no entry.
    def list_entry(self, anime_id):
        graphql = """
        query ($mediaId: Int, $userId: Int) {
            MediaList(mediaId: $mediaId, userId: $userId) {
                status
                progress
                media {
                    episodes
                    status
                    nextAiringEpisode { episode timeUntilAiring }
                }
            }
        }
        """
        try:
            response = self.make_api_request(graphql, {"mediaId": anime_id, "userId": self.user_id})
        except Exception:
            return None

        entry = (response or {}).get("data", {}).get("MediaList")
        if not entry:
            return None

        media = entry["media"] or {}
        upcoming = media.get("nextAiringEpisode") or {}
        return {
            "status": entry["status"],
            "progress": entry["progress"],
            "episodes": media.get("episodes"),
            # Airing state of the show itself, not of the user's list entry.
            "airing": media.get("status"),
            "next_episode": upcoming.get("episode"),
            "next_in": upcoming.get("timeUntilAiring"),
        }

    # Takes a bare id or anything pasted that contains one, such as a siteUrl.
    def resolve(self, anime_id):
        if not str(anime_id).isdigit():
            found = re.search(r"anime/(\d+)|(\d+)", str(anime_id))
            if not found:
                raise ValueError(f"no AniList id in {anime_id!r}")
            anime_id = found.group(1) or found.group(2)

        graphql = """
        query ($id: Int) {
            Media(id: $id, type: ANIME) {
                id
                siteUrl
                format
                episodes
                startDate { year }
                title { romaji english }
                coverImage { medium }
            }
        }
        """
        response = self.make_api_request(graphql, {"id": int(anime_id)})
        return self._entry(response["data"]["Media"])

    @staticmethod
    def _entry(media):
        return {
            "id": media["id"],
            "title": media["title"]["romaji"] or media["title"]["english"],
            "english": media["title"]["english"],
            "format": media["format"],
            "episodes": media["episodes"],
            "year": (media["startDate"] or {}).get("year"),
            "url": media["siteUrl"],
            "cover": (media["coverImage"] or {}).get("medium"),
        }

    # Get the anime's id from the guessed name
    def get_anime_info(self, name, year=None):
        if year:
            query = """
            query ($search: String, $year: Int) {
                Media (search: $search, type: ANIME, seasonYear: $year) {
                    id
                    siteUrl
                    title {
                        romaji
                    }
                }
            }
            """
            variables = {"search": name, "year": year}
        else:
            query = """
            query ($search: String) {
                Media (search: $search, type: ANIME) {
                    id
                    siteUrl
                    title {
                        romaji
                    }
                }
            }
            """
            variables = {"search": name}

        response = self.make_api_request(query, variables)
        if response and "data" in response:
            return (
                response["data"]["Media"]["id"],
                response["data"]["Media"]["title"]["romaji"],
            )
        return None

    # Gets episode count from id. Returns [progress, totalEpisodes]
    def get_episode_count(self, anime_id):
        query = """
        query ($mediaId: Int, $userId: Int) {
            MediaList(mediaId: $mediaId, userId: $userId) {
                status
                progress
                media {
                    episodes
                }
            }
        }
        """
        variables = {"mediaId": anime_id, "userId": self.user_id}

        response = self.make_api_request(query, variables)

        if response and "data" in response and response["data"]["MediaList"]:
            media_list = response["data"]["MediaList"]
            return (
                media_list["progress"],
                media_list["media"]["episodes"],
                media_list["status"],
            )

        if sys.argv[2] == "launch":
            webbrowser.open_new_tab(f"https://anilist.co/anime/{anime_id}")
            return None
        return None, None

    # Update the anime based on file progress
    def update_episode_count(self, anime_id, file_progress, anime_name):
        result = self.get_episode_count(anime_id)

        if result is None:
            return

        current_progress, total_episodes, current_status = result

        # 'episode': [86, 13], lol.
        # I don't know of a way to actually fix this in fix_filename, since it takes episode_title as title, and 86 as the episode.
        if isinstance(file_progress, list):
            file_progress = min(file_progress)

        # If the episode in the file name is larger than the total amount of episodes
        # Then they are using absolute numbering format for episodes (looking at you SubsPlease)
        # Try to guess season and episode.
        if total_episodes is not None and file_progress > total_episodes:
            print("Episode number is in absolute value. Converting to season and episode.")
            result = self.find_season_and_episode(anime_id, file_progress)
            if result is None:
                raise Exception(
                    f"Could not resolve absolute episode {file_progress} to a season "
                    f"for {anime_name} (relation chain has no season covering it)"
                )
            title, new_anime_id, new_episode, _season_number = result
            print(f"Absolute episode {file_progress} corresponds to Anime: {title}, Episode: {new_episode}")
            # Call the function again with the updated anime id and episode.
            self.update_episode_count(new_anime_id, new_episode, title)
            return

        # Only launch anilist
        if sys.argv[2] == "launch":
            webbrowser.open_new_tab(f"https://anilist.co/anime/{anime_id}")
            return

        # If its lower than the current progress, dont update.
        if file_progress <= current_progress:
            raise Exception(f"Episode was not new. Not updating ({file_progress} <= {current_progress})")

        # If the file progress isnt the next episode, don't update. Was not sure whether to make it or not but I don't think there'd be any unintended effects

        # Decided against it. Useful for skipping filler. Also I don't think anyone watches the wrong episode by mistake.
        # if file_progress != current_progress + 1:
        # raise Exception(f'Episode was not the next one. Not updating ({file_progress} != {current_progress + 1})')

        # Handle changing "Planned to watch" animes to "Watching"
        query = """
        mutation ($mediaId: Int, $progress: Int, $status: MediaListStatus) {
            SaveMediaListEntry (mediaId: $mediaId, progress: $progress, status: $status) {
                status
                id
                progress
            }
        }
        """

        variables = {"mediaId": anime_id, "progress": file_progress}

        if current_status == "PLANNING" and file_progress != total_episodes:
            variables["status"] = "CURRENT"  # Set to "CURRENT" if it's on planning and it isn't the final episode.

        response = self.make_api_request(query, variables, self.access_token)
        if response and "data" in response:
            updated_progress = response["data"]["SaveMediaListEntry"]["progress"]
            print(f"Episode count updated successfully! New progress: {updated_progress}")
        else:
            print("Failed to update episode count.")


def link_account():
    """Store the token handed over on stdin, so it never reaches the process list."""
    token = sys.stdin.read().strip()
    if not token:
        print("ERROR: nothing on the clipboard to read a token from")
        sys.exit(1)

    token_store.save(token)
    updater = AniListUpdater()  # its user id lookup doubles as the token check
    response = updater.make_api_request("query { Viewer { name } }", None, token)
    name = response["data"]["Viewer"]["name"]
    token_store.save(token, updater.user_id, name)
    print(f"LINKED: {name}")


def main():
    try:
        command = sys.argv[1]

        if command == "--deps":
            if MISSING_DEPS:
                print(f"ERROR: {MISSING_DEPS}. Run `just setup`.")
                sys.exit(1)
            print(f"requests {requests.__version__} from {os.path.dirname(requests.__file__)}")
            print(f"guessit from {os.path.dirname(sys.modules['guessit'].__file__)}")
            return

        if MISSING_DEPS:
            raise RuntimeError(f"{MISSING_DEPS}. Run `just setup` in the config repo.")

        if command == "--setup":
            link_account()
            return

        # One call for everything the menu draws: who you are, what this file
        # resolved to, and what your list already says. Two calls meant two
        # process spawns before a single row could be drawn.
        if command == "--menu":
            token, user_id, name = token_store.load()

            if token and not name:
                try:
                    probe = AniListUpdater()
                    reply = probe.make_api_request("query { Viewer { name } }", None, token)
                    name = reply["data"]["Viewer"]["name"]
                    token_store.save(token, user_id or probe.user_id, name)
                except Exception:
                    name = None

            payload = {"linked": bool(token), "name": name}

            if token and len(sys.argv) > 2 and sys.argv[2]:
                updater = AniListUpdater()
                file_info = updater.parse_filename(sys.argv[2])
                pinned = overrides.get(file_info["key"])

                if pinned:
                    match = {"id": pinned["id"], "title": pinned["title"], "source": "pinned"}
                else:
                    found = updater.get_anime_info(file_info["name"], file_info["year"])
                    match = (
                        {"id": found[0], "title": found[1], "source": "guessed"} if found else None
                    )

                if match:
                    match["entry"] = updater.list_entry(match["id"])

                payload.update(
                    {
                        "guess": file_info["name"],
                        "episode": file_info["episode"],
                        "match": match,
                        "season_hint": updater.season_hint(match, file_info["episode"]),
                    }
                )

            print(JSON_PREFIX + json.dumps(payload))
            return

        # Answered from the encrypted store alone, so the menu opens instantly
        # and still says who you are while AniList is unreachable.
        if command == "--status":
            token, user_id, name = token_store.load()

            # Accounts linked before the name was cached backfill it once, and
            # stay merely "linked" if AniList cannot be reached to ask.
            if token and not name:
                try:
                    updater = AniListUpdater()
                    response = updater.make_api_request("query { Viewer { name } }", None, token)
                    name = response["data"]["Viewer"]["name"]
                    token_store.save(token, user_id or updater.user_id, name)
                except Exception:
                    name = None

            print(JSON_PREFIX + json.dumps({"linked": bool(token), "name": name}))
            return

        # What this file would update, without updating it.
        if command == "--match":
            updater = AniListUpdater()
            file_info = updater.parse_filename(sys.argv[2])
            pinned = overrides.get(file_info["key"])

            if pinned:
                match = {"id": pinned["id"], "title": pinned["title"], "source": "pinned"}
            else:
                found = updater.get_anime_info(file_info["name"], file_info["year"])
                match = (
                    {"id": found[0], "title": found[1], "source": "guessed"} if found else None
                )

            if match:
                match["entry"] = updater.list_entry(match["id"])

            print(
                JSON_PREFIX
                + json.dumps(
                    {
                        "guess": file_info["name"],
                        "episode": file_info["episode"],
                        "match": match,
                        "season_hint": updater.season_hint(match, file_info["episode"]),
                    }
                )
            )
            return

        if command == "--search":
            updater = AniListUpdater()
            print(JSON_PREFIX + json.dumps(updater.search(sys.argv[2])))
            return

        if command == "--resolve":
            updater = AniListUpdater()
            print(JSON_PREFIX + json.dumps(updater.resolve(sys.argv[2])))
            return

        if command == "--guess":
            updater = AniListUpdater()
            print(JSON_PREFIX + json.dumps(updater.parse_filename(sys.argv[2])))
            return

        if command == "--pin":
            # argv: --pin <path> <anime_id>
            updater = AniListUpdater()
            file_info = updater.parse_filename(sys.argv[2])
            entry = updater.resolve(sys.argv[3])
            overrides.put(file_info["key"], entry["id"], entry["title"])
            updater.update_episode_count(entry["id"], file_info["episode"], entry["title"])
            print(f"PINNED: {entry['title']}")
            return

        updater = AniListUpdater()
        updater.handle_filename(command)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
