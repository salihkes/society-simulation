"""Set phrases the residents speak: lines.json in the world folder, else these defaults."""
import json
import os

DEFAULTS = {
    "sitting_open": "The sitting is open.",
    "sitting_matter": "The first item on the agenda: {matter}.",
    "sitting_debate": "We now move to the debate.",
    "sitting_call": "{name}.",
    "sitting_vote": "We now move to the vote. Those in favour, please rise.",
    "sitting_carried": "The majority has risen. The motion is carried.",
    "sitting_rejected": "The minority has risen. The motion is rejected.",
    "sitting_carried_elsewhere": "By the decision of the other house, the motion is carried.",
    "sitting_rejected_elsewhere": "By the decision of the other house, the motion is rejected.",
    "sitting_adjourn": "The sitting is adjourned.",
    "lesson_end": "That is all for today. Well done, everyone.",
    "lesson_later": "Good question. Let's talk about it later.",
    "lesson_defer": "Good question, {student}. We will come to that a little later, so hold on.",
    "lesson_callback": "{student}, about your question earlier: this is where it is answered.",
}


class Lines:
    def __init__(self, world_dir: str):
        try:
            with open(os.path.join(world_dir, "lines.json"), encoding="utf-8") as f:
                self.values = json.load(f)
        except (OSError, ValueError):
            self.values = {}

    def get(self, key: str, **values) -> str:
        return str(self.values.get(key, DEFAULTS[key])).format(**values)
