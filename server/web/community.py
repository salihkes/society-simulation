"""Community boards (subreddit style): a JSON store in data/community.json, its sorting, and its API."""

import json
import math
import os
import threading
import time
import uuid

from core import identity
from core import paths
from web import roles
from web.reply import body, fail, ok, text
from web.session import user

DATA_PATH = paths.data("community.json")
SORTS = ("hot", "new", "rising", "controversial", "top")
HOT_EPOCH = 1134028003
RISING_MAX_AGE_MINUTES = 60 * 24

_LOCK = threading.RLock()


def home_board():
    """The board that always exists, from identity community_home; created by the root user."""
    home = identity.get("community_home")
    return {
        "name": home["name"],
        "title": home["title"],
        "description": home["description"],
        "wiki": f"# welcome to r/{home['name']}\n\nadmins can edit this page from the wiki tab.\n",
        "created": int(time.time()),
        "creator": identity.get("root_user"),
    }


def _save(db):
    os.makedirs(os.path.dirname(DATA_PATH), exist_ok=True)
    tmp = DATA_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(db, f, indent=2)
    os.replace(tmp, DATA_PATH)


def _load():
    db = {}
    if os.path.exists(DATA_PATH):
        with open(DATA_PATH, encoding="utf-8") as f:
            try:
                db = json.load(f)
            except json.JSONDecodeError:
                db = {}
    for key, empty in (("subreddits", {}), ("posts", []), ("comments", [])):
        db.setdefault(key, empty)
    home = home_board()
    if home["name"] not in db["subreddits"]:
        db["subreddits"][home["name"]] = home
        _save(db)
    return db


def list_subreddits():
    with _LOCK:
        return sorted(_load()["subreddits"].values(), key=lambda s: s["name"])


def get_subreddit(name):
    with _LOCK:
        return _load()["subreddits"].get(name)


def create_subreddit(name, title, description, creator):
    name = name.strip().lower()
    if not name or not name.replace("_", "").isalnum():
        return False, "subreddit name must be alphanumeric"
    with _LOCK:
        db = _load()
        if name in db["subreddits"]:
            return False, "subreddit already exists"
        db["subreddits"][name] = {
            "name": name,
            "title": title.strip() or name,
            "description": description.strip(),
            "wiki": f"# r/{name}\n\nstart writing your wiki here.\n",
            "created": int(time.time()),
            "creator": creator,
        }
        _save(db)
        return True, name


def set_wiki(name, text_body):
    with _LOCK:
        db = _load()
        if name not in db["subreddits"]:
            return False
        db["subreddits"][name]["wiki"] = text_body
        _save(db)
        return True


def create_post(subreddit, author, title, text_body, url=""):
    title = title.strip()
    if not title:
        return False, "title required"
    with _LOCK:
        db = _load()
        if subreddit not in db["subreddits"]:
            return False, "subreddit not found"
        post = {
            "id": uuid.uuid4().hex[:10],
            "subreddit": subreddit,
            "author": author,
            "title": title,
            "body": text_body.strip(),
            "url": url.strip(),
            "created": int(time.time()),
            "votes": {author: 1},
        }
        db["posts"].append(post)
        _save(db)
        return True, post


def get_post(post_id):
    with _LOCK:
        return next((p for p in _load()["posts"] if p["id"] == post_id), None)


def posts_in(subreddit):
    with _LOCK:
        return [p for p in _load()["posts"] if p["subreddit"] == subreddit]


def create_comment(post_id, author, text_body, parent_id=None):
    text_body = text_body.strip()
    if not text_body:
        return False, "comment body required"
    with _LOCK:
        db = _load()
        if not any(p["id"] == post_id for p in db["posts"]):
            return False, "post not found"
        if parent_id and not any(c["id"] == parent_id for c in db["comments"]):
            return False, "parent comment not found"
        comment = {
            "id": uuid.uuid4().hex[:10],
            "post_id": post_id,
            "parent_id": parent_id,
            "author": author,
            "body": text_body,
            "created": int(time.time()),
            "votes": {author: 1},
        }
        db["comments"].append(comment)
        _save(db)
        return True, comment


def comments_for(post_id):
    with _LOCK:
        return [c for c in _load()["comments"] if c["post_id"] == post_id]


def vote(kind, item_id, voter, value):
    """Set `voter`'s vote (-1, 0 clears, +1); the updated item, or None."""
    if value not in (-1, 0, 1):
        return None
    with _LOCK:
        db = _load()
        bucket = "posts" if kind == "post" else "comments"
        item = next((i for i in db[bucket] if i["id"] == item_id), None)
        if item is None:
            return None
        if value == 0:
            item["votes"].pop(voter, None)
        else:
            item["votes"][voter] = value
        _save(db)
        return item


def score(item):
    return sum(item.get("votes", {}).values())


def user_vote(item, voter):
    if not voter:
        return 0
    return int(item.get("votes", {}).get(voter, 0))


def _hot(item):
    s = score(item)
    order = math.log10(max(abs(s), 1))
    sign = 1 if s > 0 else (-1 if s < 0 else 0)
    return round(sign * order + (item["created"] - HOT_EPOCH) / 45000, 7)


def _controversy(item):
    votes = item.get("votes", {}).values()
    ups = sum(1 for v in votes if v > 0)
    downs = sum(1 for v in votes if v < 0)
    if ups + downs == 0:
        return 0.0
    if ups > downs:
        balance = downs / ups
    else:
        balance = ups / downs if downs > 0 else 0
    return (ups + downs) ** balance


def _rising(item):
    """Score per minute of age; nothing older than a day is rising."""
    age = max((time.time() - item["created"]) / 60.0, 1.0)
    if age > RISING_MAX_AGE_MINUTES:
        return -1.0
    return score(item) / age


def sort_key(item, sort):
    if sort == "new":
        return item["created"]
    if sort == "top":
        return score(item)
    if sort == "controversial":
        return _controversy(item)
    if sort == "rising":
        return _rising(item)
    return _hot(item)


def sorted_posts(subreddit, sort="hot"):
    items = posts_in(subreddit)
    items.sort(key=lambda p: sort_key(p, sort), reverse=True)
    return items


def _public(item, viewer):
    """An item as the API shows it: score and the viewer's vote instead of every voter."""
    out = {k: v for k, v in item.items() if k != "votes"}
    out["score"] = score(item)
    out["user_vote"] = user_vote(item, viewer)
    return out


def threaded_comments(post_id, viewer, sort="top"):
    """The post's comments as a tree: each node has a "children" list."""
    raw = {c["id"]: c for c in comments_for(post_id)}
    by_id = {cid: dict(_public(c, viewer), children=[]) for cid, c in raw.items()}
    roots = []
    for c in by_id.values():
        parent = by_id.get(c["parent_id"]) if c["parent_id"] else None
        (parent["children"] if parent else roots).append(c)

    def order(nodes):
        nodes.sort(key=lambda n: sort_key(raw[n["id"]], sort), reverse=True)
        for n in nodes:
            order(n["children"])

    order(roots)
    return roots


async def boards(request):
    return ok(subreddits=list_subreddits(), default=identity.get("community_home")["name"],
              sorts=list(SORTS))


async def board_create(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    if not roles.can_admin(name):
        return fail(403, "not permitted")
    data = await body(request)
    success, result = create_subreddit(text(data, "name"), text(data, "title"),
                                       text(data, "description"), name)
    return ok(name=result) if success else fail(400, result)


async def board_view(request):
    sub = get_subreddit(request.match_info["name"])
    if not sub:
        return fail(404, "subreddit not found")
    sort = request.query.get("sort", "hot")
    if sort not in SORTS:
        sort = "hot"
    viewer = user(request)
    posts = []
    for p in sorted_posts(sub["name"], sort):
        posts.append(dict(_public(p, viewer), comment_count=len(comments_for(p["id"]))))
    return ok(subreddit=sub, sort=sort, posts=posts)


async def post_create(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    if not get_subreddit(request.match_info["name"]):
        return fail(404, "subreddit not found")
    if not roles.can_post(name):
        return fail(403, "your account does not have posting privileges in this community.")
    data = await body(request)
    success, result = create_post(request.match_info["name"], name, text(data, "title"),
                                  text(data, "body"), text(data, "url"))
    return ok(post=_public(result, name)) if success else fail(400, result)


def _post_in_board(request):
    post = get_post(request.match_info["post_id"])
    if not post or post["subreddit"] != request.match_info["name"]:
        return None
    return post


async def post_view(request):
    sub = get_subreddit(request.match_info["name"])
    post = _post_in_board(request)
    if not sub or not post:
        return fail(404, "post not found")
    viewer = user(request)
    return ok(subreddit=sub, post=_public(post, viewer),
              comments=threaded_comments(post["id"], viewer))


async def comment_create(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    post = _post_in_board(request)
    if not post:
        return fail(404, "post not found")
    data = await body(request)
    success, result = create_comment(post["id"], name, text(data, "body"),
                                     text(data, "parent_id") or None)
    return ok(comment=_public(result, name)) if success else fail(400, result)


async def wiki_save(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    if not roles.can_admin(name):
        return fail(403, "not permitted")
    data = await body(request)
    wiki = data.get("body") if isinstance(data.get("body"), str) else ""
    if not set_wiki(request.match_info["name"], wiki):
        return fail(404, "subreddit not found")
    return ok()


async def vote_api(request):
    name = user(request)
    if not name:
        return fail(401, "not authenticated")
    data = await body(request)
    kind = data.get("kind")
    item_id = data.get("id")
    try:
        value = int(data.get("value", 0))
    except (TypeError, ValueError):
        return fail(400, "bad value")
    if kind not in ("post", "comment") or not item_id:
        return fail(400, "bad request")
    item = vote(kind, item_id, name, value)
    if item is None:
        return fail(404, "not found")
    return ok(score=score(item), user_vote=user_vote(item, name))


def add_routes(app):
    r = app.router
    r.add_get("/api/r", boards)
    r.add_post("/api/r", board_create)
    r.add_get("/api/r/{name}", board_view)
    r.add_post("/api/r/{name}/posts", post_create)
    r.add_get("/api/r/{name}/posts/{post_id}", post_view)
    r.add_post("/api/r/{name}/posts/{post_id}/comments", comment_create)
    r.add_post("/api/r/{name}/wiki", wiki_save)
    r.add_post("/api/vote", vote_api)
