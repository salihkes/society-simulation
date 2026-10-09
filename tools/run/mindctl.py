#!/usr/bin/env python3
"""mindctl — manual control of the city's mind, over text.

    tools/run/mindctl.py status
    tools/run/mindctl.py say <who> "Hello, everyone."               spoken (script bubble + voice)
    tools/run/mindctl.py say <who> --raw "<text>"                   shown as given, no voice
    tools/run/mindctl.py go <who> <place> [--at 15.0] [--then wander]
    tools/run/mindctl.py eat <who> <place>
    tools/run/mindctl.py emote <who> happy [--for 15]
    tools/run/mindctl.py plan <who> intents.json [--replace]         a full plan (ARCHITECTURE.md)
    tools/run/mindctl.py consolidate [<who>]                          the memory sleep, now
    tools/run/mindctl.py clock real | fixed 21 | scaled 60 8.0
    tools/run/mindctl.py weather [status | auto | clear | partly | overcast | fog | drizzle | rain | storm | windy | snow]
    tools/run/mindctl.py rehearsal start | end | status           the city forgets everything from start to end
    tools/run/mindctl.py residents                                     re-send residents.json
    tools/run/mindctl.py lesson start <lesson-id>                      the teacher begins the lesson
    tools/run/mindctl.py lesson status | stop

Talks to the server like a game client (env GAME_SERVER, default
ws://127.0.0.1:2053). Run with the server's venv:
    $GAME_DATA/venv/bin/python tools/run/mindctl.py …
"""
import argparse
import asyncio
import json
import os
import sys

SERVER = os.environ.get("GAME_SERVER", "ws://127.0.0.1:2053")
CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "server", "config")
IDENTITY = os.path.join(CONFIG, "identity.json")
if not os.path.exists(IDENTITY):
    IDENTITY = os.path.join(CONFIG, "identity.example.json")
with open(IDENTITY, encoding="utf-8") as _f:
    CK = json.load(_f)["client_key"]


async def send(cmd: dict, timeout: float = 180.0) -> dict:
    import websockets
    async with websockets.connect(SERVER, max_size=20_000_000) as ws:
        await ws.send(json.dumps({"type": "handshake", "ck": CK}))
        cmd["type"] = "mind_cmd"
        cmd["ck"] = CK
        await ws.send(json.dumps(cmd, ensure_ascii=False))
        loop = asyncio.get_event_loop()
        t0 = loop.time()
        while loop.time() - t0 < timeout:
            try:
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
            except asyncio.TimeoutError:
                break
            if m.get("type") == "mind_reply":
                return m
    return {"ok": False, "text": "no reply"}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p = sub.add_parser("life", help="resident autonomy and director controls")
    p.add_argument("op", choices=["status", "pause", "resume", "set", "order", "enabled"])
    p.add_argument("who", nargs="?", help="resident id; for enabled use on or off")
    p.add_argument("--goal")
    p.add_argument("--concern")
    p.add_argument("--action", help='JSON action, e.g. {"do":"study","seconds":90}')
    p = sub.add_parser("say"); p.add_argument("who"); p.add_argument("text"); p.add_argument("--raw", action="store_true")
    for verb in ("go", "eat"):
        p = sub.add_parser(verb); p.add_argument("who"); p.add_argument("place")
        p.add_argument("--at", type=float); p.add_argument("--then", default="wander")
    p = sub.add_parser("emote"); p.add_argument("who"); p.add_argument("emotion"); p.add_argument("--for", dest="secs", type=float, default=15)
    p = sub.add_parser("plan"); p.add_argument("who"); p.add_argument("file"); p.add_argument("--replace", action="store_true")
    p = sub.add_parser("consolidate"); p.add_argument("who", nargs="?")
    p = sub.add_parser("clock"); p.add_argument("mode", choices=["real", "fixed", "scaled"]); p.add_argument("a", nargs="?", type=float); p.add_argument("b", nargs="?", type=float)
    p = sub.add_parser("weather", help="show or set regional weather; auto restores seasonal climate")
    p.add_argument("weather", nargs="?", default="status", type=str.lower,
                   choices=["status", "auto", "clear", "partly", "overcast", "fog", "drizzle", "rain", "storm", "windy", "snow"])
    p.add_argument("--region", help="region ID (omit to change global defaults; regional overrides remain)")
    p.add_argument("--temperature", type=float, help="air temperature in Celsius (-80..60)")
    p.add_argument("--humidity", type=float, help="relative humidity percent (0..100)")
    p.add_argument("--snow-depth", type=float, help="set cover in metres (0..0.30); global depth commands also reset tracks")
    p.add_argument("--snow-max", type=float, help="maximum accumulated depth in metres (0..0.30)")
    p.add_argument("--snow-rate", type=float, help="snowfall in metres per real minute (0..0.10)")
    p.add_argument("--snow-melt", type=float, help="thaw in metres per real minute outside snow weather (0..0.10)")
    p = sub.add_parser("ask", help="a pupil asks the teacher this, in class, in their own voice; the teacher answers or defers"); p.add_argument("who"); p.add_argument("text")
    p = sub.add_parser("lore", help="common knowledge: list topics, or test which topics a sentence matches"); p.add_argument("text", nargs="?", default="")
    p = sub.add_parser("library", help="the city library: what a citizen can reach for, or run one tool by hand")
    p.add_argument("tool", nargs="?", default="", help="lore | recall | look_up | encyclopaedia | find_place | ...")
    p.add_argument("args", nargs="?", default="{}", help="JSON arguments, e.g. '{\"query\": \"harbour\"}'")
    p.add_argument("--as", dest="who", default="", help="which resident is asking (recall reads THEIR memory)")
    p = sub.add_parser("weekday", help="pretend it is this weekday (school on a Saturday): mon..sun, or auto"); p.add_argument("day")
    p = sub.add_parser("computer", help="the city's computers (machine room): status | use <who> <task> [--vars k=v,..] | open <id> | close <id> | shot <id> | act <id> '<json>' | files <who> [--path p] [--fop list|read|write|append] [--text t]")
    p.add_argument("op", nargs="?", default="status", choices=["status", "use", "open", "close", "shot", "act", "files"])
    p.add_argument("a", nargs="?", default=""); p.add_argument("b", nargs="?", default="")
    p.add_argument("--vars", default=""); p.add_argument("--path", default=""); p.add_argument("--fop", default="list"); p.add_argument("--text", default="")
    sub.add_parser("residents")
    p = sub.add_parser("rehearsal", help="a shoot the city forgets: snapshot the world's memory at start, put it back at end"); p.add_argument("op", choices=["start", "end", "status"])
    p = sub.add_parser("household", help="the homes: status | restock <household> [--n 4] | ill <who> [--days 2] | well <who>")
    p.add_argument("op", nargs="?", default="status", choices=["status", "restock", "ill", "well"])
    p.add_argument("who", nargs="?", default="")
    p.add_argument("--n", type=int, default=4, help="meals put in the cupboard")
    p.add_argument("--days", type=int, default=2, help="how long the illness runs without care")
    p = sub.add_parser("school", help="the timetable and period (no argument), or drive the room: bell | class | break | lunch | free | gather | assembly_am | assemble | closed | open")
    p.add_argument("--class", dest="klass", default="", help="one class (12B); default: every room")
    p.add_argument("sub", nargs="?", default="status")
    p = sub.add_parser("lesson"); p.add_argument("sub", choices=["start", "stop", "status"]); p.add_argument("id", nargs="?"); p.add_argument("--teacher", default="r_teacher_chem"); p.add_argument("--students", help="comma-separated resident ids (default: residents marked student)"); p.add_argument("--class", dest="klass", default="", help="the class whose room it is (default: the first)")
    p = sub.add_parser("sitting", help="the Diet sits on a matter: the city stages it, council decides it")
    p.add_argument("sub", choices=["start", "stop", "status"])
    p.add_argument("matter", nargs="?", help="what the house is asked to decide")
    p.add_argument("--house", default="both", choices=["both", "representatives", "councillors"])
    p.add_argument("--as-of", dest="as_of", help="hold the sitting as it stood on YYYYMMDD; nothing later is known to the house")
    p.add_argument("--members", type=int, default=0, help="a light rehearsal: only the first N members of each house sit (0 = the whole house)")
    a = ap.parse_args()
    if a.cmd == "life":
        cmd = {"cmd": "life", "op": a.op}
        if a.op == "enabled":
            if a.who not in ("on", "off"):
                ap.error("life enabled requires on or off")
            cmd["enabled"] = a.who == "on"
        elif a.who:
            cmd["id"] = a.who
        for field in ("goal", "concern"):
            if getattr(a, field) is not None:
                cmd[field] = getattr(a, field)
        if a.action:
            cmd["action"] = json.loads(a.action)
    elif a.cmd == "status":
        cmd = {"cmd": "status"}
    elif a.cmd == "say":
        cmd = {"cmd": "say", "id": a.who, "text": a.text, "convert": not a.raw, "voice": not a.raw}
    elif a.cmd in ("go", "eat"):
        it = {"do": a.cmd, "place": a.place, "then": a.then}
        if a.at is not None:
            it["at"] = a.at
        cmd = {"cmd": "plan", "id": a.who, "intents": [it]}
    elif a.cmd == "emote":
        cmd = {"cmd": "plan", "id": a.who, "intents": [{"do": "emote", "emotion": a.emotion, "for": a.secs}]}
    elif a.cmd == "plan":
        with open(a.file, encoding="utf-8") as f:
            data = json.load(f)
        cmd = {"cmd": "plan", "id": a.who, "intents": data.get("intents", data) if isinstance(data, dict) else data,
               "replace": a.replace}
    elif a.cmd == "sitting":
        cmd = {"cmd": "sitting", "op": a.sub, "matter": a.matter or "",
               "house": a.house, "as_of": a.as_of, "members": a.members}
    elif a.cmd == "consolidate":
        cmd = {"cmd": "consolidate", "id": a.who}
    elif a.cmd == "clock":
        cmd = {"cmd": "clock", "mode": a.mode}
        if a.mode == "fixed":
            cmd["hour"] = a.a if a.a is not None else 12.0
        elif a.mode == "scaled":
            cmd["rate"] = a.a if a.a is not None else 60.0
            cmd["hour"] = a.b if a.b is not None else 8.0
    elif a.cmd == "weather":
        cmd = {"cmd": "weather", "weather": a.weather}
        if a.region is not None or a.temperature is not None or a.humidity is not None:
            if a.weather == "status":
                ap.error("regional/climate settings need a weather type, e.g. weather auto --region the_city --temperature -10")
            cmd.update({key: value for key, value in (("region", a.region), ("temperature_c", a.temperature),
                        ("humidity_percent", a.humidity)) if value is not None})
        snow = {key: value for key, value in (("depth", a.snow_depth), ("max_depth", a.snow_max),
                ("rate", a.snow_rate), ("melt", a.snow_melt)) if value is not None}
        if snow:
            if a.weather == "status":
                ap.error("snow settings need a weather type, e.g. weather snow --snow-depth 0.12")
            cmd["snow"] = snow
    elif a.cmd == "ask":
        cmd = {"cmd": "ask", "id": a.who, "text": a.text}
    elif a.cmd == "library":
        cmd = {"cmd": "library", "tool": a.tool, "args": json.loads(a.args), "id": a.who}
    elif a.cmd == "lore":
        cmd = {"cmd": "lore", "text": a.text}
    elif a.cmd == "rehearsal":
        cmd = {"cmd": "rehearsal", "op": a.op}
    elif a.cmd == "weekday":
        cmd = {"cmd": "clock", "weekday": a.day}
    elif a.cmd == "school":
        cmd = {"cmd": "school", "sub": a.sub, "class": a.klass}
    elif a.cmd == "household":
        cmd = {"cmd": "household", "op": a.op, "id": a.who, "n": a.n, "days": a.days}
    elif a.cmd == "computer":
        cmd = {"cmd": "computer", "op": a.op, "id": a.a, "who": a.a, "task": a.b, "json": a.b,
               "vars": a.vars, "path": a.path, "fop": a.fop, "text": a.text}
    elif a.cmd == "lesson":
        cmd = {"cmd": "lesson", "sub": a.sub, "id": a.id, "teacher": a.teacher, "class": a.klass}
        if a.students:
            cmd["students"] = [s.strip() for s in a.students.split(",") if s.strip()]
    else:
        cmd = {"cmd": "residents"}
    r = asyncio.run(send(cmd))
    print(("ok: " if r.get("ok") else "FAILED: ") + str(r.get("text", "")))
    sys.exit(0 if r.get("ok") else 1)


if __name__ == "__main__":
    main()
