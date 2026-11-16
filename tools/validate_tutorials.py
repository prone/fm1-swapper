#!/usr/bin/env python3
"""Check Tutorials/*.json against the format in Tutorials/README.md.

  python3 tools/validate_tutorials.py [file ...]

Exit 1 when any file has errors. Warnings (e.g. a note the app cannot press) do not fail.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTROLS = {"SCREEN", "KEYS", "MASTER", "SELECT", "PRESETS", "ALGORITHM", "KNOB1", "KNOB2", "KNOB3", "KNOB4",
            "OCT-", "OCT+", "FX", "SCL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP", "SEQ", "PLAY", "REC"}
TURNABLE = {"MASTER", "SELECT", "PRESETS", "ALGORITHM", "KNOB1", "KNOB2", "KNOB3", "KNOB4"}
PRESSABLE = {"OCT-", "OCT+", "FX", "SCL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP", "SEQ", "PLAY", "REC"}
NOTE = re.compile(r"^([A-Ga-g])(#|b)?(-?\d)$")
ACTION_KEYS = {"press", "hold", "release", "turn", "note", "wait"}


def midi(name):
    m = NOTE.match(name)
    if not m:
        return None
    pc = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}[m[1].upper()] + {"#": 1, "b": -1}.get(m[2], 0)
    return (int(m[3]) + 1) * 12 + pc


def check(path):
    errors, warnings = [], []
    try:
        t = json.loads(path.read_text())
    except Exception as e:  # noqa: BLE001
        return [f"not valid JSON: {e}"], []

    def need(key, kind):
        if not isinstance(t.get(key), kind):
            errors.append(f"'{key}' missing or not a {kind.__name__}")

    for key, kind in [("format", int), ("id", str), ("title", str), ("summary", str), ("match", dict),
                      ("sources", list), ("reviewed", bool), ("steps", list)]:
        need(key, kind)
    if errors:
        return errors, warnings
    if t["format"] != 1:
        errors.append("format must be 1")
    if path.stem != t["id"]:
        warnings.append(f"file name {path.name} differs from id '{t['id']}'")
    if not t["sources"]:
        errors.append("sources is empty: every tutorial must cite where its facts come from")
    if not any(t["match"].get(k) for k in ("sha256", "repos", "productPrefixes", "families", "names")):
        errors.append("match has no criteria")
    if "felucca" in (t["match"].get("families") or []) and t["id"] != "felucca-family":
        warnings.append("matching the whole 'felucca' family also catches every Felucca fork")

    def control(name, where, turn=False, act=False):
        if name in CONTROLS:
            if turn and name not in TURNABLE:
                errors.append(f"{where}: {name} cannot be turned")
            if act and not turn and name not in PRESSABLE:
                errors.append(f"{where}: {name} cannot be pressed")
            return
        n = midi(name)
        if n is None:
            errors.append(f"{where}: unknown control '{name}'")
        elif not 53 <= n <= 79:
            errors.append(f"{where}: {name} is not on the FM-1's keys (F3-G5)")
        elif act and not 60 <= n <= 77:
            warnings.append(f"{where}: the app can only play C4-F5, not {name}")
        elif turn:
            errors.append(f"{where}: a note cannot be turned")

    def actions(lst, where):
        if not isinstance(lst, list):
            errors.append(f"{where}: must be a list")
            return
        held = set()
        for i, a in enumerate(lst):
            w = f"{where}[{i}]"
            keys = ACTION_KEYS & a.keys()
            if len(keys) != 1:
                errors.append(f"{w}: needs exactly one of {sorted(ACTION_KEYS)}")
                continue
            k = keys.pop()
            v = a[k]
            if k == "wait":
                if not isinstance(v, int) or not 0 < v <= 10000:
                    errors.append(f"{w}: wait must be 1-10000 ms")
            elif k == "turn":
                control(v, w, turn=True, act=True)
                if not isinstance(a.get("clicks", 1), int) or a.get("clicks") == 0:
                    errors.append(f"{w}: clicks must be a non-zero integer")
            else:
                control(v, w, act=True)
                if k == "hold":
                    held.add(v)
                if k == "release":
                    held.discard(v)
        if held:
            warnings.append(f"{where}: still holding {sorted(held)} at the end")

    if "setup" in t:
        actions(t["setup"], "setup")
    if not t["steps"]:
        errors.append("no steps")
    for i, s in enumerate(t["steps"]):
        w = f"steps[{i}]"
        if not s.get("title") or not s.get("text"):
            errors.append(f"{w}: needs title and text")
        if len(s.get("text", "")) > 600:
            warnings.append(f"{w}: text is long ({len(s['text'])} chars); the card shows about 300 without scrolling")
        for h in s.get("highlight", []):
            control(h, f"{w}.highlight")
        if "show" in s:
            actions(s["show"], f"{w}.show")
        aw = s.get("await")
        if aw is not None:
            if not any(k in aw for k in ("press", "turn", "anyNote")):
                errors.append(f"{w}.await: needs press, turn or anyNote")
            for p in aw.get("press", []):
                control(p, f"{w}.await.press")
            if "turn" in aw:
                control(aw["turn"], f"{w}.await.turn", turn=True)
    return errors, warnings


def main():
    files = [pathlib.Path(a) for a in sys.argv[1:]] or sorted((ROOT / "Tutorials").glob("*.json"))
    bad = 0
    for f in files:
        errors, warnings = check(f)
        status = "FAIL" if errors else "ok"
        print(f"{status:4}  {f.name}")
        for e in errors:
            print(f"      error: {e}")
        for w in warnings:
            print(f"      warn:  {w}")
        bad += bool(errors)
    if not files:
        print("no tutorials found")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
