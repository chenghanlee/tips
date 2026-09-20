#!/usr/bin/env python3
"""Validate the initial task publication snapshot; GitHub owns live task state."""
import json
import re
from functools import cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOGUE = ROOT / "docs/implementation"
PACKAGES = {"P0", "P1", "P2", "P3", "P4a", "P4b", "P5", "P6", "P7", "P8", "P9a", "P9b", "P10", "P11", "P12", "P13a", "P13b", "P14", "P15", "P16"}


def load_tasks():
    return [task for path in sorted(CATALOGUE.glob("*-tasks.json"))
            for task in json.loads(path.read_text())]


def validate(tasks):
    ids = [task["id"] for task in tasks]
    assert len(ids) == len(set(ids)), "Duplicate task IDs"
    by_id = {task["id"]: task for task in tasks}
    assert {t["package"] for t in tasks} == PACKAGES, "Package coverage mismatch"
    assert all(f"M{i}" in by_id for i in range(5)), "Missing milestone gate"
    for task in tasks:
        for key in ("id", "package", "milestone", "kind", "title", "outcome", "reads", "scope", "acceptance", "verification", "ownership", "sizing"):
            assert task.get(key), f"{task['id']}: missing {key}"
        assert task["kind"] in {"code", "contract", "probe", "gate"}, task["id"]
        assert task["milestone"] in {f"M{i}" for i in range(5)}, task["id"]
        for dependency in task["depends_on"]:
            assert dependency in by_id, f"{task['id']}: unresolved dependency {dependency}"
            assert by_id[dependency]["milestone"] <= task["milestone"], f"{task['id']}: depends on later milestone {dependency}"
        for read in task["reads"]:
            path = ROOT / read["path"]
            assert path.is_file(), f"{task['id']}: missing {path}"
            headings = re.findall(r"^#{1,6} (.+)$", path.read_text(), re.M)
            assert read["section"] in headings, f"{task['id']}: unknown section {read}"
    visited, active = set(), set()

    def visit(task_id):
        assert task_id not in active, f"Dependency cycle at {task_id}"
        if task_id in visited:
            return
        active.add(task_id)
        for dependency in by_id[task_id]["depends_on"]:
            visit(dependency)
        active.remove(task_id)
        visited.add(task_id)

    for task_id in by_id:
        visit(task_id)

    @cache
    def prerequisites(task_id):
        result = set(by_id[task_id]["depends_on"])
        for dependency in by_id[task_id]["depends_on"]:
            result.update(prerequisites(dependency))
        return frozenset(result)

    for task in tasks:
        gate = task["milestone"]
        assert task["id"] == gate or task["id"] in prerequisites(gate), f"{task['id']}: not covered by {gate} gate"
    return by_id


def check_local_links():
    paths = [ROOT / "README.md", *CATALOGUE.glob("*.md")]
    for path in paths:
        for target in re.findall(r"\]\(([^)]+)\)", path.read_text()):
            target = target.strip("<>").split("#", 1)[0]
            if not target or "://" in target or target.startswith("mailto:"):
                continue
            assert (path.parent / target).is_file(), f"{path.relative_to(ROOT)}: broken local link {target}"


if __name__ == "__main__":
    tasks = load_tasks()
    validate(tasks)
    check_local_links()
    print(f"PASS: {len(tasks)} tasks, {len(PACKAGES)} packages, five milestone gates; IDs, dependencies, DAG and reading sections valid")
