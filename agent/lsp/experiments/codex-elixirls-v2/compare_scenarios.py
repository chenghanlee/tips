#!/usr/bin/env python3
"""Compare settled scenario outcomes between arms and summarize dependency-project purges."""

import json
import re
import sys
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads((path / "results.json").read_text())


def outcome(step: dict) -> dict:
    return {
        "status": step["status"],
        "diagnostics": [(d["path"], d["line"], d["severity"], d["message"]) for d in step["diagnostics"]],
        "build_results": sorted(set(step["builds"])),
    }


def purges(step: dict) -> list[str]:
    """From [warm-apps] logs: dependency projects loaded before prune and after prune."""
    rows = []
    for log in step["logs"]:
        if not log.startswith("[warm-apps] "):
            continue
        text = log[len("[warm-apps] "):]
        phases = {}
        for name, cached, loaded in re.findall(r"\{:(\w+), (\d+), \[([^\]]*)\]\}", text):
            apps = [a.strip().lstrip(":") for a in loaded.split(",") if a.strip()]
            phases[name] = (int(cached), apps)
        before, after = phases.get("cached_deps"), phases.get("prune")
        if before and after:
            rows.append(f"cached={before[0]} loaded_before_prune={len(before[1])} "
                        f"loaded_after_prune={len(after[1])} sample={before[1][:4]}")
    return rows


def main() -> None:
    arms = [Path(p) for p in sys.argv[1:]]
    runs = {arm.name: load(arm) for arm in arms}
    names = [s["step"] for s in next(iter(runs.values()))["steps"]]
    report = {"arms": list(runs), "steps": [], "equal": True}
    for index, name in enumerate(names):
        per_arm = {}
        for arm, run in runs.items():
            step = run["steps"][index]
            assert step["step"] == name, (arm, step["step"], name)
            per_arm[arm] = outcome(step)
        values = list(per_arm.values())
        equal = all(v == values[0] for v in values)
        report["equal"] &= equal
        row = {"step": name, "equal": equal, "status": {a: v["status"] for a, v in per_arm.items()},
               "diagnostics": values[0]["diagnostics"] if equal else {a: v["diagnostics"] for a, v in per_arm.items()},
               "build_results": {a: v["build_results"] for a, v in per_arm.items()},
               "starts": {a: r["steps"][index].get("starts") for a, r in runs.items()}}
        for arm, run in runs.items():
            rows = purges(run["steps"][index])
            if rows:
                row.setdefault("purges", {})[arm] = rows
        report["steps"].append(row)
    for arm, run in runs.items():
        initial = run.get("initial", {})
        rows = purges({"logs": initial.get("logs", [])})
        report.setdefault("initial_purges", {})[arm] = rows
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
