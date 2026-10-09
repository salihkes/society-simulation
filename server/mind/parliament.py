"""Stages a sitting of parliament in the city; the council project decides seats, votes and the record."""
import asyncio
import base64
import importlib
import json
import os
import random
import sys
import time

from core import identity

SPEECH = identity.get("speech_language")
SPEECH_RULES = identity.get("speech_rules")

SPEAKERS = 4                 # members called to the rostrum in debate (half against, half for)
UNANSWERED = "no answer returned"   # the council's reason on a ballot no model answered
BEAT = 1.1                   # pause between spoken lines, seconds
WAIT_FOR_SLOT = 600.0        # a spoken line waits for a model slot this long


def _council_dir(mind_dir: str) -> str:
    """The council project folder: <repo>/server/mind -> <repo>/council."""
    server = os.path.dirname(os.path.abspath(mind_dir))
    return os.path.join(os.path.dirname(server), "council")


class Sitting:
    def __init__(self, mind, brain, matter: str, house: str = "both",
                 speaker_key: str = "", as_of: str = None, members: int = 0):
        self.mind = mind
        self.brain = brain
        self.matter = matter
        self.house = house
        self.as_of = as_of
        self.members = int(members or 0)   # cap on each roster (0 = the whole house)
        # Empty: resolved from the elected Speaker when the sitting opens.
        self.speaker = speaker_key or ""
        self.task = None
        self.running = False
        self.started = 0.0
        self.result: dict | None = None
        self.seated: dict = {}          # house -> [resident keys, in roster order]

    def _key(self, rid: str) -> str:
        return str((self.mind.store.residents or {}).get(rid, {}).get("key")
                   or f"r_{rid}")

    def _resolve_speaker(self, diet) -> str:
        """The key of the elected Speaker, lower house first; "" if vacant."""
        for house in ("representatives", "councillors"):
            if self.house not in ("both", house):
                continue
            chair = diet.speaker(house)
            if chair:
                return self._key(chair.get("resident") or chair["id"])
        return ""

    def _council(self):
        """Import the council package, give it this process's pool, and return a Diet."""
        path = _council_dir(os.path.dirname(os.path.abspath(__file__)))
        if path not in sys.path:
            sys.path.insert(0, path)
        package = identity.get("council_package")
        bridge = importlib.import_module(package + ".bridge")
        session = importlib.import_module(package + ".session")
        if self.members > 0:
            session.MAX_MEMBERS = self.members
        # The pool's HTTP session belongs to this loop; the council's threads submit calls to it.
        bridge.use_llm(self.brain.llm, loop=asyncio.get_running_loop())
        return importlib.import_module(package + ".bodies.diet").Diet()

    def status(self) -> dict:
        return {"matter": self.matter[:80], "house": self.house,
                "running": self.running, "seated": {h: len(v) for h, v in self.seated.items()},
                "verdict": (self.result or {}).get("verdict")}

    def start(self):
        """Start the sitting task unless one is running; returns the task."""
        if self.task is None or self.task.done():
            self.running = True
            self.started = time.time()
            self.task = asyncio.create_task(self._run())
        return self.task

    def stop(self):
        self.running = False
        if self.task and not self.task.done():
            self.task.cancel()

    async def _say(self, key: str, spoken: str):
        """A resident says a line (script bubble and voice); returns its estimated duration, seconds."""
        if not key or not spoken:
            return 0.0
        text = await self.brain._render(key, spoken)
        audio = await self.brain.tts.synth(self.brain._voice_for(key), spoken)
        await self.mind.say(key, text, audio)
        dur = 2.0 + len(spoken) * 0.13
        if audio:
            try:
                raw = base64.b64decode(audio)
                dur = max(dur * 0.5, (len(raw) - 44) / (2 * 24000.0))
            except Exception:
                pass
        return dur

    async def _line(self, key: str, brief: str) -> str:
        """Ask a resident for one spoken line."""
        system = (
            f"You are {self.brain._persona(key)[:900]}\n\n"
            "You are in the chamber of parliament. Say ONE short sentence aloud, "
            f"in plain {SPEECH}. {SPEECH_RULES} No preamble, no "
            "quotation marks, nothing but the sentence."
        )
        try:
            out = await self.brain.llm.chat(system, [{"role": "user", "content": brief}],
                                            priority=False,
                                            model=self.brain._model_for(key),
                                            wait=WAIT_FOR_SLOT)
        except Exception as e:
            print(f"[Parliament] {key} could not be asked: {type(e).__name__}: {e}")
            return ""
        if not out:
            print(f"[Parliament] {key} had nothing to say (no model answered)")
        return (out or "").strip().splitlines()[0] if out else ""

    def _built(self) -> dict:
        """Chairs per house from the world's place report; {} before any report."""
        places = getattr(self.mind.store, "places", None) or {}
        entry = places.get("parliament") if isinstance(places, dict) else None
        seats = (entry or {}).get("seats") or {}
        return seats if isinstance(seats, dict) else {}

    def _sits_in_world(self, house: str) -> bool:
        """True when the world has chairs for this house (or has not reported)."""
        built = self._built()
        return not built or bool(built.get(house))

    async def _seat(self, house: str, members: list):
        """Send members to the house's chairs, the Speaker to the Speaker's chair, and tell clients who sits."""
        keys = []
        i = 0
        for m in members:
            key = self._key(m.get("resident") or m.get("id"))
            keys.append(key)
            if key == self.speaker:
                place = "parliament.speaker"
            else:
                place = f"parliament.{house}.{i}"
                i += 1
            await self.mind.push_intents(key, [
                {"do": "go", "place": "parliament.door"},
                {"do": "sit", "place": place, "then": "stay"},
            ], replace=True)
        self.seated[house] = keys
        print(f"[Parliament] {house}: {len(keys)} sent for"
              + (f", {self.speaker} presiding" if self.speaker else ", no Speaker elected"))
        await self.mind.send_all({"type": "par", "op": "seat", "house": house,
                                  "members": keys, "speaker": self.speaker})

    async def _seat_presiding(self):
        """Seat a Speaker who is on no roster that was sent for."""
        if not self.speaker or any(self.speaker in keys for keys in self.seated.values()):
            return
        await self.mind.push_intents(self.speaker, [
            {"do": "go", "place": "parliament.door"},
            {"do": "sit", "place": "parliament.speaker", "then": "stay"},
        ], replace=True)
        self.seated["speaker"] = [self.speaker]
        print(f"[Parliament] {self.speaker} presides from the other house")
        await self.mind.send_all({"type": "par", "op": "seat", "house": "speaker",
                                  "members": [self.speaker], "speaker": self.speaker})

    async def _run(self):
        try:
            diet = self._council()
            self.speaker = self.speaker or self._resolve_speaker(diet)
            print(f"[Parliament] committee stage on: {self.matter[:80]}"
                  + (f" ({self.members} members per house)" if self.members else ""))

            # The council is synchronous and slow, so it runs off the loop.
            self.result = await asyncio.to_thread(
                diet.convene, self.matter, False, self.as_of)
            self._report_division()

            rosters = {h: diet.rosters[h] for h in diet.houses
                       if self.house in ("both", h)}
            for house, members in rosters.items():
                if self._sits_in_world(house):
                    await self._seat(house, members)
            await self._seat_presiding()
            await asyncio.sleep(BEAT * 2)
            await self._plenary()
        except asyncio.CancelledError:
            raise
        except Exception as e:
            print(f"[Parliament] sitting failed: {type(e).__name__}: {e}")
            await self.mind.send_all({"type": "par", "op": "adjourn"})
        finally:
            self.running = False
            self._save()

    def _report_division(self):
        """Log ballots and unanswered counts per house, and the verdict."""
        for house, votes in (self.result.get("houses") or {}).items():
            unanswered = sum(1 for v in votes if v.get("reason") == UNANSWERED)
            print(f"[Parliament] {house}: {len(votes)} ballots, {unanswered} unanswered"
                  + (" — the pool never answered them; that is not a division" if unanswered == len(votes) else ""))
        print(f"[Parliament] committee reports: {self.result.get('verdict', '')}")

    def _votes_here(self) -> list:
        """The ballots of the houses that sit in the world, in roster order."""
        houses = self.result.get("houses") or {}
        return [v for h in self.seated if h != "speaker" for v in houses.get(h, [])]

    @staticmethod
    def _answered(v: dict) -> bool:
        """True for an Approve/Reject ballot a model actually answered."""
        return v.get("vote") in ("Approve", "Reject") and v.get("reason") != UNANSWERED

    def _vote_key(self, v: dict) -> str:
        return self._key(v.get("id") or v.get("name"))

    @staticmethod
    def _name(v: dict) -> str:
        return str(v.get("name") or v.get("id") or "")

    def _debaters(self, votes: list) -> list:
        """Up to SPEAKERS answered ballots, random within each side, alternating against then for."""
        against = [v for v in votes if v.get("vote") == "Reject" and self._answered(v)]
        for_ = [v for v in votes if v.get("vote") == "Approve" and self._answered(v)]
        random.shuffle(against)
        random.shuffle(for_)
        order = []
        for i in range((SPEAKERS + 1) // 2):
            if i < len(against):
                order.append(against[i])
            if i < len(for_):
                order.append(for_[i])
        return order[:SPEAKERS]

    async def _chair(self, line: str, **values):
        """The Speaker says a set phrase from lines.json; with the chair vacant it is only logged."""
        spoken = self.mind.lines.get(line, **values)
        if not self.speaker:
            print(f"[Parliament] (chair vacant) {spoken}")
            return
        await asyncio.sleep(await self._say(self.speaker, spoken) + BEAT)

    async def _plenary(self):
        votes = self._votes_here()
        ayes = [self._vote_key(v) for v in votes if v.get("vote") == "Approve"]
        noes = [self._vote_key(v) for v in votes if v.get("vote") == "Reject"]
        await self.mind.send_all({"type": "par", "op": "open",
                                  "matter": self.matter[:200], "speaker": self.speaker})
        await self._chair("sitting_open")
        await self._chair("sitting_matter", matter=self.matter)
        await self._debate(votes)
        passed_here = await self._vote(votes, ayes, noes)
        await self._declare(passed_here, ayes, noes)
        await self._chair("sitting_adjourn")
        for keys in self.seated.values():
            for key in keys:
                await self.mind.push_intents(key, [], replace=True)
        await self.mind.send_all({"type": "par", "op": "adjourn"})

    async def _debate(self, votes: list):
        debaters = self._debaters(votes)
        if debaters:
            await self._chair("sitting_debate")
        for v in debaters:
            key = self._vote_key(v)
            side = "against" if v["vote"] == "Reject" else "for"
            await self._chair("sitting_call", name=self._name(v))
            await self.mind.send_all({"type": "par", "op": "rostrum", "member": key})
            print(f"[Parliament] {key} at the rostrum, {side}")
            said = await self._line(
                key,
                f"The matter before the house: {self.matter}\n"
                f"You are at the rostrum speaking {side} "
                f"the matter. Your reason, in your own words: {v['reason']}\n"
                f"Say it aloud to the chamber, as a member speaking in debate.")
            await asyncio.sleep(await self._say(key, said) + BEAT)
            await self.mind.send_all({"type": "par", "op": "sit", "member": key})

    async def _vote(self, votes: list, ayes: list, noes: list) -> bool:
        """Those in favour rise and the chair judges; True when it passed here."""
        await self._chair("sitting_vote")
        await self.mind.send_all({"type": "par", "op": "rise", "members": ayes})
        await asyncio.sleep(BEAT * 3)
        passed_here = len(ayes) > len(noes)
        if not votes:
            print("[Parliament] no house sits in the world; the vote is on paper only")
        await self._chair("sitting_carried" if passed_here else "sitting_rejected")
        await self.mind.send_all({"type": "par", "op": "sit", "members": ayes})
        return passed_here

    async def _declare(self, passed_here: bool, ayes: list, noes: list):
        """Announce parliament's verdict, which another house may have decided."""
        verdict = self.result.get("verdict", "")
        if (verdict == "Passed") != passed_here:
            await self._chair("sitting_carried_elsewhere" if verdict == "Passed"
                              else "sitting_rejected_elsewhere")
        await self.mind.send_all({"type": "par", "op": "result", "verdict": verdict,
                                  "record": os.path.basename(self.result.get("record", ""))})
        print(f"[Parliament] {len(ayes)} for, {len(noes)} against here; parliament: {verdict}")

    def _save(self):
        """Write the sitting's outcome to parliament_state.json."""
        path = os.path.join(self.mind.data_dir, "parliament_state.json")
        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"matter": self.matter, "house": self.house,
                           "as_of": self.as_of, "at": time.time(),
                           "verdict": (self.result or {}).get("verdict"),
                           "record": (self.result or {}).get("record")},
                          f, ensure_ascii=False, indent=2)
        except OSError:
            pass
