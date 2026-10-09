"""A bounded tool loop for a resident's answer: up to MAX_STEPS fenced-JSON tool calls within BUDGET seconds."""
import asyncio
import json
import re
import time

from . import library

FENCE = re.compile(r"```tool_call\s*\n(.*?)```", re.S)
FENCE_OPEN = "```tool_call"

MAX_STEPS = 3           # tool calls in one answer; the fourth is the answer
BUDGET = 9.0            # seconds for the whole loop, including the last word


def protocol(names: list) -> str:
    return (
        "\n## When you do not know\n"
        "You may go and find something out before you answer. To do it, reply "
        "with NOTHING but one fenced block:\n"
        "```tool_call\n"
        '{"name": "<one of the below>", "arguments": {…}}\n'
        "```\n"
        "You will be told what you found and asked again. Then answer normally, "
        "in character, in your own voice.\n"
        "Reach for something only when you genuinely do not know and it matters "
        "for what was said to you. Small talk needs nothing. Never mention the "
        "looking, never describe these tools, never say the word 'tool' — a "
        "person does not narrate remembering. If what you find is nothing, say "
        "plainly that you do not know: that is an honest answer and a better one "
        "than inventing.\n"
        "What you can reach for:\n" + library.describe(names) + "\n")


def parse(reply: str):
    """(name, arguments, error) for a reply that is a tool call, else None."""
    m = FENCE.search(reply or "")
    if not m:
        return None
    raw = m.group(1).strip()
    try:
        call = json.loads(raw)
    except json.JSONDecodeError as e:
        return ("", {}, f"that was not valid JSON ({e.msg}); write the block again")
    if not isinstance(call, dict):
        return ("", {}, "the block must be a JSON object with name and arguments")
    name = str(call.get("name") or call.get("tool") or "").strip()
    args = call.get("arguments", call.get("args", {}))
    if not name:
        return ("", {}, "the block needs a \"name\"")
    return (name, args if isinstance(args, dict) else {}, None)


def _truncated_call(reply: str) -> bool:
    """True for a tool block that opened and never closed (out of tokens)."""
    return FENCE_OPEN in (reply or "") and FENCE.search(reply or "") is None


async def _observe(call, ctx: dict, log: str) -> str:
    """Run a parsed tool call (or return its parse error) in a thread."""
    name, args, err = call
    if err:
        return err
    t0 = time.monotonic()
    observation = await asyncio.to_thread(library.execute, name, args, ctx)
    if log:
        print(f"[React] {log}: {name}({json.dumps(args, ensure_ascii=False)[:70]}) "
              f"→ {len(observation)} chars in {time.monotonic() - t0:.1f}s")
    return observation


async def run(llm, system: str, messages: list, ctx: dict, *,
              names: list = None, model: str = "",
              max_steps: int = MAX_STEPS, budget: float = BUDGET,
              tier: str = "live", log: str = "") -> str:
    """One answer with up to `max_steps` look-ups; ctx carries "who", lore, memory and the loop; "" only if the LLM gave nothing."""
    names = names or []
    deadline = time.monotonic() + budget
    ctx = dict(ctx or {})
    ctx["allowed"] = names
    ctx.setdefault("loop", asyncio.get_running_loop())
    turns = list(messages)
    sys_with_tools = system + (protocol(names) if names else "")
    steps = 0

    while True:
        left = deadline - time.monotonic()
        last = steps >= max_steps or left <= 2.0
        reply = await llm.chat(system if last else sys_with_tools, turns,
                               tier=tier, model=model)
        reply = (reply or "").strip()
        if last or not reply:
            if reply and FENCE_OPEN in reply:
                reply = reply.split(FENCE_OPEN)[0].strip()
            return reply

        call = parse(reply)
        if call is None:
            if _truncated_call(reply):
                turns = turns + [
                    {"role": "assistant", "content": reply},
                    {"role": "user", "content":
                     "That block was cut off. Either write it again complete, "
                     "or simply answer with what you already know."}]
                steps += 1
                continue
            return reply

        steps += 1
        observation = await _observe(call, ctx, log)
        turns = turns + [
            {"role": "assistant", "content": reply},
            {"role": "user", "content":
             f"What you found:\n{observation}\n\n"
             "Now answer the person, in character, in your own voice. Do not "
             "mention looking anything up."}]
