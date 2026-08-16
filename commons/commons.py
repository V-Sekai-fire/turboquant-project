#!/usr/bin/env python3
"""Commons, rung 0: a settlement you can watch and type into.

No engine, no containers, no model. The only question this rung answers is
whether the world is worth watching, because that is the question the whole
project rests on and the one all the infrastructure was deferring.

Every action goes through submit_action, and the driver is a scripted greedy
policy. A genie and a player are later drivers of the same surface, so this is
also the reference the A/A equity test compares against.

    python3 commons.py                 # watch a day
    python3 commons.py --speed 40      # faster
    python3 commons.py --seed 7        # a different settlement
"""

import argparse
import random
import sys
import time

TICK_MIN = 15                      # in-world minutes per tick
DAY_TICKS = 96                     # 24h
NEEDS = ("rest", "food", "company", "purpose")

# Decay per tick. Rest drains slowest, company fastest -- people get lonely
# before they get tired, which is what makes them travel.
DECAY = {"rest": 0.010, "food": 0.022, "company": 0.028, "purpose": 0.016}

SKILLS = ("cook", "mend", "garden", "teach")

# name -> (satisfies, amount, minutes, skill required, where)
ACTIONS = {
    "sleep":  ("rest",    0.95, 480, None,     "room"),
    "cook":   ("food",    0.80,  45, "cook",   "kitchen"),
    "eat":    ("food",    0.55,  15, None,     "kitchen"),
    "mend":   ("purpose", 0.60,  30, "mend",   "workshop"),
    "garden": ("purpose", 0.70,  60, "garden", "garden"),
    "talk":   ("company", 0.65,  30, None,     "commons"),
    "teach":  ("company", 0.50,  60, "teach",  "commons"),
}

FIRST = ["Wren", "Ash", "Juniper", "Rook", "Sorrel", "Fen", "Marlow", "Bay"]


class Resident:
    def __init__(self, name, home, skills, rng):
        self.name, self.home, self.skills = name, home, skills
        self.needs = {n: rng.uniform(0.55, 0.9) for n in NEEDS}
        self.at = home
        self.busy_until = 0
        self.doing = None
        self.journal = []

    @property
    def urgent(self):
        return min(self.needs.items(), key=lambda kv: kv[1])


class Commons:
    """One settlement. Places are km apart, so travel costs real time."""

    def __init__(self, seed, n=6):
        self.rng = random.Random(seed)
        self.tick = 0
        self.events = []
        names = self.rng.sample(FIRST, n)
        self.places = ["north commons", "mill commons", "south commons"]
        # Distances in km between commons; walking is 5 km/h.
        self.dist = {}
        for i, a in enumerate(self.places):
            for b in self.places[i + 1:]:
                d = self.rng.choice([9, 14, 22])
                self.dist[(a, b)] = self.dist[(b, a)] = d
        self.people = []
        for nm in names:
            home = self.rng.choice(self.places)
            # Skill scarcity is the engine: nobody has everything.
            sk = set(self.rng.sample(SKILLS, self.rng.choice([1, 1, 2])))
            self.people.append(Resident(nm, home, sk, self.rng))

    # -- the one action surface -------------------------------------------
    def submit_action(self, who, action, arg=None):
        """Every driver goes through here. Returns (ok, detail)."""
        if self.tick < who.busy_until:
            return False, "busy"
        if action == "goto":
            if arg == who.at:
                return False, "already there"
            km = self.dist[(who.at, arg)]
            mins = int(km / 5 * 60)
            who.busy_until = self.tick + max(1, mins // TICK_MIN)
            who.doing, who.at = f"walking to {arg}", arg
            self.emit(who, f"sets out for {arg}, {km} km, {mins // 60}h{mins % 60:02d}")
            return True, "walking"
        if action not in ACTIONS:
            return False, "unknown action"
        need, amt, mins, skill, _ = ACTIONS[action]
        if skill and skill not in who.skills:
            return False, f"cannot {action}"
        who.busy_until = self.tick + max(1, mins // TICK_MIN)
        who.doing = action
        who.needs[need] = min(1.0, who.needs[need] + amt)
        return True, action

    def emit(self, who, text):
        self.events.append((self.tick, who.name, text))

    def clock(self):
        m = self.tick * TICK_MIN
        return f"{(m // 60) % 24:02d}:{m % 60:02d}"

    # -- the scripted greedy driver, and the 1.0 baseline ------------------
    def greedy(self, who):
        need, val = who.urgent
        if val > 0.45:
            return
        for name, (sat, _a, _m, skill, where) in ACTIONS.items():
            if sat != need:
                continue
            if skill and skill not in who.skills:
                continue
            ok, _ = self.submit_action(who, name)
            if ok:
                self.emit(who, f"{self._phrase(name)} ({need} was {val:.2f})")
                return
        # Nobody here can fix it. Find someone who can, and walk.
        for name, (sat, _a, _m, skill, _w) in ACTIONS.items():
            if sat == need and skill:
                for other in self.people:
                    if skill in other.skills and other.at != who.at:
                        ok, _ = self.submit_action(who, "goto", other.at)
                        if ok:
                            self.emit(who, f"  needs {need}; only {other.name} can {name}")
                        return

    def _phrase(self, a):
        return {"sleep": "turns in", "cook": "starts cooking", "eat": "eats",
                "mend": "sits down to mend", "garden": "goes to the garden",
                "talk": "falls into conversation", "teach": "starts teaching"}[a]

    def step(self):
        self.tick += 1
        for p in self.people:
            for n in NEEDS:
                p.needs[n] = max(0.0, p.needs[n] - DECAY[n])
            if self.tick >= p.busy_until:
                if p.doing and p.doing.startswith("walking"):
                    self.emit(p, f"arrives at {p.at}")
                p.doing = None
                self.greedy(p)

    def score(self):
        """Settlement-seconds of met need. The number a policy is judged on."""
        return sum(sum(1 for v in p.needs.values() if v > 0.3) for p in self.people)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--speed", type=float, default=12.0, help="ticks per second")
    ap.add_argument("--ticks", type=int, default=DAY_TICKS)
    a = ap.parse_args()

    w = Commons(a.seed)
    print(f"\n  COMMONS  seed {a.seed}  ·  {len(w.people)} residents  ·  "
          f"{len(w.places)} settlements\n")
    for p in w.people:
        print(f"    {p.name:<8} {p.home:<16} {'/'.join(sorted(p.skills))}")
    print()

    seen = 0
    for _ in range(a.ticks):
        w.step()
        for t, who, text in w.events[seen:]:
            m = t * TICK_MIN
            print(f"  {(m // 60) % 24:02d}:{m % 60:02d}  {who:<8} {text}")
        seen = len(w.events)
        time.sleep(1.0 / a.speed)

    print(f"\n  day ends  ·  met-need score {w.score()}"
          f"  ·  {len(w.events)} events\n")


if __name__ == "__main__":
    sys.exit(main())
