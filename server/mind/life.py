"""Resident agency: the world reports a life_view, the model picks an action, the world reports its life_result."""
import asyncio
import copy
import json
import math
import os
import time
import uuid

from core import identity


PROMPT = """You are living one resident's life, not writing a story or directing a cast.
Choose ONE next action from the physical opportunities in your situation. You may
follow your responsibilities, change your mind, seek company, ask for help, study,
or leave. Others have their own agency: you cannot decide their answers or feelings.
Use your personality, private concerns, relationships, recent experiences and memories.
Continue a meaningful activity when appropriate; do not manufacture drama each turn.
A lesson excerpt is something you heard, NOT proof you understood it. Learning notes
are your own questions/understanding, not objective grades. Never invent witnessed events.
A timetable is your schedule, not proof you are sitting in a classroom. Your actual
attendance is reported by in_school, seated and teaching. A reason or old memory is
a belief, not evidence that an event happened.
While a lesson is running, keep "learning" current in your own words — a sentence is
plenty, and "I have lost the thread at X" is a real note. Afterwards it is the only
thing you keep: the teacher's sentences are not yours to carry out of the room.
Speech/question text must be {SPEECH}. Internal notes may be in any language.
Write "reason", "goal", "concern" and your notes as yourself, in the first person ("I…"),
even when your character description below speaks of you as "she" or "he".
Only JSON, no markdown:
{"action":{"do":"<available verb>","target":"<nearby id if needed>",
"place":"<allowed place id for go/invite>","object":"<objects id for use>","household":"<households id for visit>","at":16.5,"invitation":"<id for accept/decline>","text":"<speech/question, otherwise empty>",
"seconds":60},"reason":"why this matters now","goal":"your ongoing intention",
"concern":"what is on your mind","relationship":{"target":"<known id>",
"note":"your own impression, or empty"},"learning":{"lesson":"<current_lesson id, or empty>","note":"your understanding of that lesson, or empty"}}
Use empty strings for notes that need no change. Available actions:
continue: carry on without interfering; listen/study/rest: spend time quietly;
attend: take a desk; yard: spend time outside; approach: walk to a nearby person;
say: speak to a nearby person (they choose their own response);
ask: ask the current teacher a lesson question; go: visit an allowed city place;
eat: seek a meal at an allowed restaurant; sleep: go to a named place and sleep.
buy: get food (a snack, not a full meal) at an allowed shop — a konbini or grocery; its place is marked "(shop)".
Travel and meals run until completed; seconds controls quiet activities, not their deadline.
Sleeping at home is usually sensible; choose a personal routine destination or your room.
invite: ask a nearby person to meet at a public place later today (at is game hour);
accept/decline: answer an invitation by its id while the inviter is nearby.
play: join a yard football game (wait for enough willing players); leave_game: stop playing.
use: use a thing in the house you are in, by its id from "objects" (a bed to sleep in, the stove,
the table, the sofa, the television, the bath…); what it restores is listed with it.
visit: call at a home in "households" (a friend's or a relative's): you knock; they decide.
welcome: let in the person knocking at your door (their id is in "knocking").
"needs" run from 0 (fine) to 1 (pressing): hunger, hygiene, comfort, fun, bladder; fatigue too.
Only the needs your life can answer are listed; one that is absent is not a concern of yours.
Someone "ill" belongs in bed; a household member may sit with them (care).
"weather" reports the world's actual type, whether you are exposed outdoors,
and whether you have an umbrella open. Account for rain, wind and slippery snow
when choosing whether to linger outside, continue travelling, or use an available
indoor place. Shelter and weather do not cancel commitments automatically.
An accepted invitation is a shared commitment, not permission to control the other person.
Never claim the chosen action succeeded: the world will tell you what happened.
""".replace("{SPEECH}", identity.get("speech_language"))


def parse_decision(raw):
    """The one JSON object in a model reply (fenced or not); ValueError otherwise."""
    raw = raw.strip()
    if raw.startswith("```"):
        if "\n" not in raw:
            raise ValueError("incomplete JSON fence")
        raw = raw.split("\n", 1)[1].rsplit("```", 1)[0].strip()
    data, end = json.JSONDecoder().raw_decode(raw)
    # Trailing text is ignored; a second JSON object is ambiguous.
    if raw[end:].lstrip().startswith("{"):
        raise ValueError("choose one action, not multiple decision objects")
    if not isinstance(data, dict):
        raise ValueError("decision must be one object")
    return data


def key_of(value):
    """A resident key ("r_" prefix) for an id or key."""
    value = str(value)
    return value if value.startswith("r_") else "r_" + value


def _hhmm(h: float) -> str:
    h = float(h) % 24.0
    return f"{int(h):02d}:{int(round((h - int(h)) * 60)) % 60:02d}"


def place_label(pid: str, place: dict, hour: float) -> str:
    """A place's name as a resident reads it; food places add their kind and whether they are open now."""
    name = str(place.get("name", pid))
    kind = place.get("kind")
    if kind not in ("restaurant", "shop"):
        return name
    if name.endswith(f"({kind})"):
        name = name[: -len(f"({kind})")].rstrip()
    o = place.get("open")
    if not o or len(o) < 2:
        return f"{name} ({kind})"
    if float(o[0]) <= hour <= float(o[1]):
        return f"{name} ({kind}, open until {_hhmm(o[1])})"
    return f"{name} ({kind}, closed — opens {_hhmm(o[0])})"


def _open_at(place: dict, hour: float) -> bool:
    """True when a place has no opening hours or is open at hour."""
    return not place.get("open") or float(place["open"][0]) <= hour <= float(place["open"][1])


class ResidentLife:
    def __init__(self, brain):
        self.brain = brain
        self.mind = brain.mind
        self.path = os.path.join(self.mind.data_dir, "resident_life.json")
        self.wake_requested = set()
        self._last_game_time = None
        self.states = {}
        self.views = {}  # key -> (monotonic time, latest life_view)
        self.busy = set()
        self.next_at = {}
        self.revisions = {}
        self.enabled = True
        self.concurrency = max(1, min(16, int(os.environ.get("MIND_LIFE_CONCURRENCY", "2"))))
        self.interval = max(10.0, float(os.environ.get("MIND_LIFE_INTERVAL", "60")))
        self._buy_checked = False   # said once per run if the world never offers "buy"
        self._last_save = 0.0
        self._load()

    def _load(self):
        """Read resident_life.json; a corrupt file raises rather than being overwritten."""
        try:
            with open(self.path, encoding="utf-8") as f:
                saved = json.load(f)
            if saved.get("version") != 1 or not isinstance(saved.get("residents"), dict):
                raise ValueError("unsupported resident life state")
            self.states = saved["residents"]
            self.enabled = bool(saved.get("enabled", True))
            for state in self.states.values():
                if state.get("pending"):
                    state["last_result"] = {"status": "interrupted", "reason": "server restarted"}
                    state["pending"] = None
        except FileNotFoundError:
            pass

    def reload(self):
        """Re-read the state file (after a rehearsal) and invalidate thoughts in progress."""
        self.states = {}
        self.enabled = True
        self.views.clear()
        self.next_at.clear()
        self._load()
        for key in self.states:
            self.revisions[key] = self.revisions.get(key, 0) + 1

    def managed(self, key):
        """True when this resident's life is run here (not scripted, an event, or opted out)."""
        r = self.brain._resident(key)
        return self.enabled and key.removeprefix("r_") in self.mind.store.residents and not r.get("script") and not key.startswith("r_evt_") and r.get("life", True) is not False

    def state(self, key):
        """A resident's life state, created with defaults."""
        return self.states.setdefault(key, {"goal": "", "concern": "", "relationships": {},
            "learning": {}, "invitations": {}, "commitments": [], "events": [], "pending": None, "last_result": {},
            "mode": "auto", "reason": "", "decisions": 0, "fatigue": 0.2, "social_need": 0.2})

    def save(self):
        """Write every state (with current hunger) atomically."""
        for key, state in self.states.items():
            if key in self.brain.needs:
                state["hunger"] = self.brain.needs[key].get("hunger", 0.3)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"version": 1, "enabled": self.enabled, "residents": self.states},
                      f, ensure_ascii=False, indent=2)
        os.replace(tmp, self.path)
        self._last_save = time.monotonic()

    def context(self, key):
        """A prompt block with the resident's private intentions and impressions."""
        if not self.managed(key):
            return ""
        s = self.state(key)
        return "Your ongoing life (private intentions and impressions):\n" + json.dumps(
            {k: s[k] for k in ("goal", "concern", "relationships", "learning", "commitments", "fatigue", "social_need", "last_result")},
            ensure_ascii=False)

    def event(self, key, event):
        """Add an event to a resident's working memory and the stream; think again soon."""
        if not self.managed(key):
            return
        s = self.state(key)
        if len(s["invitations"]) > 20:
            s["invitations"] = dict(list(s["invitations"].items())[-20:])
        e = dict(event, day=self.mind.clock.day(), hour=round(self.mind.clock.hour(), 3))
        s["events"] = (s["events"] + [e])[-24:]
        # observe(): lesson beats go to perception, not the durable stream.
        self.mind.store.observe(key, e)
        self.next_at[key] = min(self.next_at.get(key, 0), time.monotonic() + 8)

    def observe(self, key, rec):
        """Take a world observation: a life_view, a life_result, or an event."""
        if not self.managed(key):
            return
        s = self.state(key)
        if isinstance(rec.get("life_view"), dict):
            self._on_view(key, s, rec["life_view"])
            return
        result = rec.get("life_result")
        if isinstance(result, dict):
            self._on_result(key, s, result)
            return
        self._on_event(key, s, rec)

    def _on_view(self, key, s, view):
        """Keep the latest view; correct the world if its manual flag disagrees."""
        self.views[key] = (time.monotonic(), view)
        if bool(view.get("manual")) != (s["mode"] == "manual"):
            self.brain._spawn(self.mind.send_world({"type": "life_cmd", "cmd": "life_control",
                "school": view.get("school", "School"), "id": key,
                "manual": s["mode"] == "manual"}))

    def _on_result(self, key, s, result):
        """Apply the outcome of the pending action, if it is the one reported."""
        pending = s.get("pending")
        if not pending or result.get("id") != pending["id"]:
            return
        s["last_result"] = result
        if result.get("status") == "completed":
            self.social_result(key, pending)
        if result.get("status") == "completed" and pending["action"]["do"] == "ask":
            lesson = self.brain.school.lesson_of(key)
            if lesson and lesson.running and lesson.paused.is_set():
                lesson.on_question(self.brain._display_name(key), pending["action"]["text"])
        if result.get("status") == "failed" and pending["action"]["do"] in ("eat", "buy"):
            result = self._with_food_hint(key, s, pending, result)
        if result.get("status") in ("completed", "failed", "cancelled"):
            s["pending"] = None
            self.next_at[key] = time.monotonic() + 5
            print(f"[Life] {key} {pending['action']['do']}: {result.get('status')} ({result.get('reason', '')})")
        self.event(key, {"life_outcome": result})
        self.save()

    def _food_open_now(self, key, hour, exclude) -> list:
        """Labels of the restaurants and shops (other than exclude) open at hour."""
        return [place_label(q, p, hour) for q, p in self.places(key).items()
                if p.get("kind") in ("restaurant", "shop") and q != exclude and _open_at(p, hour)]

    def _with_food_hint(self, key, s, pending, result):
        """A failed meal's result, extended with where food is available now."""
        hour = self.mind.clock.hour()
        alt = self._food_open_now(key, hour, pending["action"].get("place"))
        if not alt:
            return result
        result = dict(result, reason=f"{result.get('reason', '')} — open for food now: " + "; ".join(alt)
                      + ' (use "eat" at a restaurant, "buy" at a shop)')
        s["last_result"] = result
        return result

    def _on_event(self, key, s, rec):
        """Keep notable events in working memory and wake the resident for some."""
        if not any(k in rec for k in ("heard", "did", "failed", "saw", "lost", "knock", "worried", "came_home",
                                      "missed_meal", "cared_by", "ill", "recovered", "welcomed_by", "pantry_empty")):
            return
        s["events"] = (s["events"] + [dict(rec)])[-24:]
        if rec.get("heard") and rec.get("addressed"):
            s["social_need"] = max(0, s["social_need"] - 0.1)
            self.wake_requested.add(key)
        if any(k in rec for k in ("knock", "worried", "welcomed_by", "ill")):
            self.wake_requested.add(key)
        if rec.get("heard") or rec.get("failed"):
            self.next_at[key] = min(self.next_at.get(key, 0), time.monotonic() + 8)

    def social_result(self, key, pending):
        """Social effects of a completed action: needs, invitations, commitments."""
        action = pending["action"]
        verb = action["do"]
        if verb in ("say", "ask", "invite", "accept", "decline"):
            self.state(key)["social_need"] = max(0, self.state(key)["social_need"] - 0.15)
        if verb == "invite":
            target = action["target"]
            invitation = {"id": pending["id"], "from": key, "to": target,
                "place": action["place"], "day": action["day"], "at": action["at"], "status": "offered"}
            self.state(target)["invitations"][pending["id"]] = invitation
            self.event(target, {"invited": invitation})
            self.wake_requested.add(target)
        elif verb in ("accept", "decline"):
            invitation = self.state(key)["invitations"].get(action["invitation"])
            if not invitation or invitation["status"] != "offered":
                return
            invitation["status"] = "accepted" if verb == "accept" else "declined"
            for person in (key, invitation["from"]):
                self.event(person, {"invitation_reply": dict(invitation)})
                if verb == "accept":
                    commitments = self.state(person)["commitments"]
                    commitments.append(dict(invitation))
                    self.state(person)["commitments"] = commitments[-12:]
            self.wake_requested.add(invitation["from"])

    def on_reset(self):
        """The world reconnected: drop views and interrupt pending actions."""
        self.views.clear()
        for key, s in self.states.items():
            self.revisions[key] = self.revisions.get(key, 0) + 1
            if s.get("pending"):
                s["last_result"] = {"status": "interrupted", "reason": "world reconnected"}
                s["pending"] = None
        self.save()

    def on_clock_jump(self):
        """The clock was set: interrupt pending actions and let everyone think again."""
        self.views.clear()
        self.next_at.clear()
        for key, s in self.states.items():
            self.revisions[key] = self.revisions.get(key, 0) + 1
            if s.get("pending"):
                s["last_result"] = {"status": "interrupted", "reason": "the clock was set"}
                s["pending"] = None
        self.save()

    def lesson_heard(self, lesson, text):
        """Give a lesson beat to every resident freshly seen seated in its room."""
        for key, (seen, view) in self.views.items():
            if time.monotonic() - seen < 15 and view.get("seated") and view.get("school") == lesson.school:
                lesson.heard_by[key] = lesson.heard_by.get(key, 0) + 1
                self.event(key, {"lesson_heard": text[:1600], "lesson": lesson.id, "beat": lesson.pos})

    def places(self, key):
        """Places this resident may go: public kinds plus their routine destinations."""
        places = self.brain._places_for(self.brain._resident(key), self.mind.store.places)
        out = {pid: p for pid, p in places.items() if p.get("kind") in ("marker", "district", "restaurant", "shop")}
        for i, entry in enumerate(self.brain._resident(key).get("routine", [])):
            pos = entry.get("pos")
            if isinstance(pos, list) and len(pos) == 3:
                out[f"routine:{i}"] = {"kind": "personal", "name": entry.get("name", "usual destination"), "pos": pos}
        return out

    def situation(self, key):
        """The prompt's view of the resident's situation; ValueError when the view is stale."""
        seen, view = self.views.get(key, (0, {}))
        if time.monotonic() - seen > 15:
            raise ValueError("waiting for a fresh world observation")
        view = copy.deepcopy(view)
        view["timetable"] = self.brain.school.status_for(key, self.mind.clock.hour())
        view["hour"] = self.mind.clock.hour()
        view["day"] = self.mind.clock.day()
        if "hunger" in self.brain.needs.get(key, {}):
            view["hunger"] = self.brain.needs[key]["hunger"]
        view["needs"] = {k: round(float(v), 2) for k, v in self.brain.needs.get(key, {}).items()
                         if k != "eat_block_until" and isinstance(v, (int, float)) and not isinstance(v, bool)}
        if getattr(self.brain, "health", {}).get(key, {}).get("ill"):
            view["ill"] = True
        view["routine"] = self.brain._resident(key).get("routine", [])
        view["responsibilities"] = "School attendance is expected; you may choose otherwise and face the consequences." if self.brain._resident(key).get("student") else "Your routine describes your usual responsibilities, not a forced script."
        view["places"] = {pid: place_label(pid, p, view["hour"]) for pid, p in self.places(key).items()}
        if not self._buy_checked and any(p.get("kind") == "shop" for p in self.places(key).values()):
            self._buy_checked = True
            if "buy" not in view.get("available", []):
                print(f"[Life] shops exist but the world does not offer {key} 'buy' (available: {view.get('available')})")
        lesson = self.brain.school.lesson_of(key)
        view["current_lesson"] = None
        if lesson and lesson.running and view.get("seated") and view.get("school") == lesson.school:
            heard = [e for e in self.state(key)["events"] if e.get("lesson_heard") and e.get("lesson") == lesson.id]
            if heard:
                view["current_lesson"] = {"id": lesson.id, "heard": [e["lesson_heard"] for e in heard[-3:]]}
        if "say" in view.get("available", []):
            view["available"] += ["invite", "accept", "decline"]
        if lesson and lesson.running and lesson.paused.is_set() and view.get("seated") and "listen" in view.get("available", []):
            view["available"] = list(view.get("available", [])) + ["ask"]
            if "director_available" in view:
                view["director_available"] = list(view["director_available"]) + ["ask"]
        return view

    def validate(self, key, data, view, director=False):
        """The checked action for a decision, or ValueError saying why it cannot be done."""
        if not isinstance(data, dict) or not isinstance(data.get("action"), dict):
            raise ValueError("decision must contain an action object")
        action = data["action"]
        verb = action.get("do")
        available = view.get("director_available", view.get("available", [])) if director else view.get("available", [])
        if verb not in available:
            raise ValueError(f"action unavailable here: {verb}")
        seconds = float(action.get("seconds", 60))
        if not math.isfinite(seconds):
            raise ValueError("invalid duration")
        out = {"do": verb, "seconds": max(10, min(300, seconds))}
        if verb in ("say", "approach", "invite", "accept", "decline"):
            target = str(action.get("target", ""))
            if target not in view.get("nearby", {}):
                raise ValueError("that person is no longer nearby")
            out["target"] = target
        if verb in ("go", "eat", "buy", "sleep"):
            out["place"] = self._valid_destination(key, verb, action, view)
        if verb == "invite":
            pid = str(action.get("place", ""))
            at = float(action.get("at", -1))
            if pid not in view["places"] or self.places(key)[pid].get("kind") not in ("district", "restaurant"):
                raise ValueError("choose a public meeting place")
            if not math.isfinite(at) or not view["hour"] < at < 24:
                raise ValueError("choose a later hour today")
            out.update(place=pid, at=at, day=view["day"])
        if verb in ("accept", "decline"):
            out["invitation"] = self._valid_invitation(key, action, view, out["target"])
        if verb in ("say", "ask", "invite", "accept", "decline"):
            txt = str(action.get("text", "")).strip()
            if not txt or len(txt) > 600:
                raise ValueError("speech must contain 1 to 600 characters")
            out["text"] = txt
        self._validate_household(verb, action, view, out)
        return out

    def _valid_destination(self, key, verb, action, view) -> str:
        """The place of a go/eat/buy/sleep action; a food place must be the right kind and open now."""
        pid = str(action.get("place", ""))
        if pid not in view.get("places", {}):
            raise ValueError("unknown or private destination")
        if verb == "eat" and self.places(key)[pid].get("kind") != "restaurant":
            raise ValueError("meals require a restaurant")
        if verb == "buy" and self.places(key)[pid].get("kind") != "shop":
            raise ValueError("buying requires a shop")
        if verb not in ("eat", "buy"):
            return pid
        place = self.places(key)[pid]
        o = place.get("open")
        if o and len(o) >= 2 and not float(o[0]) <= view["hour"] <= float(o[1]):
            open_now = self._food_open_now(key, view["hour"], pid)
            raise ValueError(f"{place_label(pid, place, view['hour'])} is not serving now. Open for food now: "
                             + ("; ".join(open_now) + ' — use "eat" at a restaurant, "buy" at a shop' if open_now else "nothing"))
        return pid

    def _valid_invitation(self, key, action, view, target) -> str:
        """The id of an open, unexpired invitation from target."""
        ident = str(action.get("invitation", ""))
        invite = self.state(key)["invitations"].get(ident)
        if not invite or invite["from"] != target or invite["status"] != "offered":
            raise ValueError("invitation is not open")
        if (invite["day"], invite["at"]) <= (view["day"], view["hour"]):
            raise ValueError("invitation has expired")
        return ident

    @staticmethod
    def _validate_household(verb, action, view, out):
        """Check use/visit/welcome against what the house in view offers."""
        if verb == "use":
            obj = str(action.get("object", ""))
            if obj not in (view.get("objects") or {}):
                raise ValueError("no such thing to use here")
            out["object"] = obj
        if verb == "visit":
            hid = str(action.get("household", action.get("place", "")))
            if hid not in (view.get("households") or {}):
                raise ValueError("no such home to call at")
            out["household"] = hid
        if verb == "welcome":
            target = str(action.get("target", ""))
            if target not in (view.get("knocking") or []):
                raise ValueError("nobody by that name is at the door")
            out["target"] = target

    async def tick(self):
        """Advance fatigue and social need and start due decisions (at most concurrency at once, never blocking)."""
        now = time.monotonic()
        game_time = self.mind.clock.day() * 24.0 + self.mind.clock.hour()
        dt = 0.0 if self._last_game_time is None else game_time - self._last_game_time
        self._last_game_time = game_time
        if 0 < dt < 6:
            self._drift(now, dt)
        for key in sorted(self.views, key=lambda k: self.next_at.get(k, 0)):
            if len(self.busy) >= self.concurrency:
                break
            if not self.managed(key) or key in self.busy:
                continue
            s = self.state(key)
            await self._wake_or_expire(key, s)
            if s["mode"] != "auto" or s.get("pending") or now < self.next_at.get(key, 0):
                continue
            if now - self.views[key][0] > 15 or not self.brain.llm.available:
                continue
            self.busy.add(key)
            self.next_at[key] = now + self.interval
            self.brain._spawn(self.decide(key))
        if now - self._last_save > 15 and self.states:
            self.save()

    def _drift(self, now, dt):
        """Fatigue and social need over dt game hours for residents freshly seen."""
        for key, (seen, view) in self.views.items():
            if now - seen > 15 or not self.managed(key):
                continue
            s = self.state(key)
            activity = view.get("activity", "")
            fatigue_rate = -1 / 8 if activity == "sleep" else (-1 / 20 if activity == "rest" else 1 / 16)
            s["fatigue"] = max(0.0, min(1.0, s["fatigue"] + dt * fatigue_rate))
            s["social_need"] = max(0.0, min(1.0, s["social_need"] + dt / 12))

    async def _wake_or_expire(self, key, s):
        """Cancel the pending action if it timed out or someone woke the resident (not mid-meal)."""
        pending = s.get("pending")
        if key in self.wake_requested and s["mode"] == "auto" and key not in self.busy:
            # Spoken to while eating: answer after the meal.
            if not (pending and pending["action"]["do"] in ("eat", "buy")):
                self.wake_requested.discard(key)
                await self.cancel(key, "someone addressed me")
                pending = None
        if pending and pending.get("deadline") is not None and time.time() > pending["deadline"]:
            await self.cancel(key, "world action timed out")

    async def decide(self, key):
        """Ask the model for the resident's next action, apply it and execute it."""
        revision = self.revisions.get(key, 0)
        try:
            view = self.situation(key)
            s = self.state(key)
            chosen = await self._choose(key, s, view, revision)
            if chosen is None:
                return
            decision, action, fresh = chosen
            self._apply_decision(key, s, decision, view, fresh)
            self.event(key, {"life_decision": action, "reason": s["reason"]})
            await self.execute(key, action)
        except (ValueError, TypeError, KeyError) as e:
            self.state(key)["last_error"] = str(e)
            print(f"[Life] {key} decision rejected: {e}")
        finally:
            self.busy.discard(key)
            self.next_at[key] = max(self.next_at.get(key, 0), time.monotonic() + 25)
            self.save()

    async def _choose(self, key, s, view, revision):
        """(decision, action, fresh view) with one repair turn, or None if no reply or the situation moved on."""
        durable = await self.brain.memory.context(
            key, s["goal"] + " " + s["concern"], [f"resident:{key}"], top_k=5)
        prompt = {"situation": {k: v for k, v in view.items() if k != "director_available"}, "private_life": s, "memories": durable,
                  "friends": self.brain._resident(key).get("friends", [])}
        messages = [{"role": "user", "content": json.dumps(prompt, ensure_ascii=False)}]
        for attempt in range(2):
            raw = await self.brain.llm.chat(
                PROMPT + "\nYour character:\n" + self.brain._persona(key), messages,
                tier="bg", model=self.brain._model_for(key))
            if not raw:
                return None
            if revision != self.revisions.get(key, 0) or s["mode"] != "auto" or not self.managed(key):
                return None  # superseded by a director order or a world reset
            fresh = self.situation(key)
            if (fresh.get("phase"), fresh["day"], fresh["timetable"].get("period")) != (view.get("phase"), view["day"], view["timetable"].get("period")):
                return None  # the bell rang while the model was thinking
            try:
                decision = parse_decision(raw)
                action = self.validate(key, decision, fresh)
                return decision, action, fresh
            except (ValueError, TypeError, KeyError) as e:
                if attempt:
                    raise
                messages += [{"role": "assistant", "content": raw[:3500]},
                             {"role": "user", "content": f"That action could not be used: {e}. Choose one available action and return a single JSON object."}]
        return None

    def _apply_decision(self, key, s, decision, view, fresh):
        """Store the decision's goal, concern, relationship and learning notes."""
        for field in ("goal", "concern"):
            if decision.get(field):
                s[field] = str(decision[field])[:600]
        relationship = decision.get("relationship")
        if isinstance(relationship, dict):
            target = str(relationship.get("target", ""))
            known = set(fresh.get("nearby", {})) | {key_of(f) for f in self.brain._resident(key).get("friends", [])}
            if target in known and relationship.get("note"):
                s["relationships"][target] = str(relationship["note"])[:500]
        learning = decision.get("learning")
        offered = view.get("current_lesson") or {}
        current = fresh.get("current_lesson") or {}
        if isinstance(learning, dict) and learning.get("note") and learning.get("lesson") \
                and learning["lesson"] == offered.get("id") == current.get("id"):
            s["learning"][learning["lesson"]] = str(learning["note"])[:700]
        s.pop("last_error", None)
        s["reason"] = str(decision.get("reason", ""))[:600]
        s["decisions"] += 1

    async def execute(self, key, action, director=False):
        """Record the action as pending and send it (with rendered speech) to the world."""
        s = self.state(key)
        ident = uuid.uuid4().hex
        # Travel and meals report their own completion; only timed actions get a deadline.
        deadline = None if action["do"] in ("go", "eat", "buy", "sleep") else time.time() + action["seconds"] + 45
        s["pending"] = {"id": ident, "action": action, "deadline": deadline}
        print(f"[Life] {key} chooses {action['do']} {action.get('place', action.get('target', ''))}")
        self.save()  # record the attempt before crossing the process boundary
        msg = {"type": "life_cmd", "cmd": "life", "school": self.brain.school.place_of(key),
               "id": key, "action_id": ident, "director": director, "action": action}
        if action["do"] in ("go", "sleep") and action.get("place", "").startswith("routine:"):
            msg["destination"] = self.places(key)[action["place"]]["pos"]
        if action["do"] in ("say", "ask", "invite", "accept", "decline"):
            msg["text"] = await self.brain._render(key, action["text"])
            # Speech is delivered by the world only after it checks proximity again.
            try:
                msg["audio"] = await self.brain.tts.synth(self.brain._voice_for(key), action["text"])
            except Exception as e:
                print(f"[Life] {key} speaks without a voice: {type(e).__name__}")
                msg["audio"] = ""  # a failed voice must not stop a person speaking
        if (s.get("pending") or {}).get("id") != ident:
            return
        await self.mind.send_world(msg)

    async def cancel(self, key, reason):
        """Cancel the pending action in the world and invalidate thoughts in progress."""
        s = self.state(key)
        self.revisions[key] = self.revisions.get(key, 0) + 1
        pending = s.get("pending")
        if pending:
            await self.mind.send_world({"type": "life_cmd", "cmd": "life_cancel",
                "school": self.brain.school.place_of(key), "id": key,
                "action_id": pending["id"]})
            s["last_result"] = {"id": pending["id"], "status": "cancelled", "reason": reason}
            s["pending"] = None

    async def command(self, data):
        """A mindctl life command: status, enabled, pause/resume/order, or set."""
        op = data.get("op", "status")
        key = key_of(data["id"]) if data.get("id") else ""
        if key and not any(key_of(rid) == key for rid in self.mind.store.residents):
            raise ValueError("unknown resident")
        if op == "status":
            return self._status(key)
        if op == "enabled":
            self.enabled = bool(data.get("enabled", True))
            if not self.enabled:
                for k in list(self.states):
                    await self.cancel(k, "autonomy disabled")
                    self.states[k]["mode"] = "auto"
                    await self.mind.send_world({"type": "life_cmd", "cmd": "life_control", "id": k, "manual": False})
            self.save()
            return {"enabled": self.enabled}
        if not key:
            raise ValueError("choose a resident")
        s = self.state(key)
        if op in ("pause", "resume", "order"):
            await self._direct(key, s, op, data)
        elif op == "set":
            for field in ("goal", "concern"):
                if field in data:
                    s[field] = str(data[field])[:600]
            self.revisions[key] = self.revisions.get(key, 0) + 1
            self.next_at[key] = 0
        else:
            raise ValueError("unknown life operation")
        self.save()
        return copy.deepcopy(s)

    def _status(self, key):
        """One resident's state and situation, or everyone's states."""
        if not key:
            return copy.deepcopy({"enabled": self.enabled, "residents": self.states})
        result = copy.deepcopy(self.state(key))
        try:
            result["situation"] = self.situation(key)
        except ValueError as e:
            result["situation"] = str(e)
        return result

    async def _direct(self, key, s, op, data):
        """Pause, resume or give an order to a resident; a teaching teacher's lesson pauses with them."""
        action = None
        if op == "order":
            action = self.validate(key, {"action": data.get("action")}, self.situation(key), director=True)
        await self.cancel(key, "director intervention")
        s["mode"] = "auto" if op == "resume" else "manual"
        lesson = self.brain.school.lesson_of(key)
        day = self.brain.school.day_of_lesson(lesson) if lesson else None
        if lesson and lesson.running and lesson.teacher == key and day is not None:
            if op == "resume":
                day.in_period = False  # reopen this period from the saved beat
            else:
                lesson.pause()
                day.teacher_absent = True
            for task in day._late_tasks:
                task.cancel()
            day._late_tasks = []
        await self.mind.send_world({"type": "life_cmd", "cmd": "life_control",
            "school": self.brain.school.place_of(key), "id": key,
            "manual": s["mode"] == "manual"})
        if action:
            await self.execute(key, action, director=True)
        self.next_at[key] = 0


# The name the tests use.
StudentLife = ResidentLife
