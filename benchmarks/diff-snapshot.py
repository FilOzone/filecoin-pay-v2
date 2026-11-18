#!/usr/bin/env python3
"""Group the .filecoin-gas-snapshot diff by gas delta, largest magnitude first.

Arguments are forwarded to `git diff`, so `--cached`, `HEAD`, or a revision range all work.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import textwrap
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SNAPSHOT = ".filecoin-gas-snapshot"
MEASUREMENT = re.compile(r"^([-+])(.*) \(gas: (\d+)\)$")


def sides(git_args: list[str]) -> tuple[dict[str, int], dict[str, int]]:
    """Gas by measurement for each side; unchanged measurements are absent from both."""
    diff = subprocess.run(
        ["git", "diff", "--no-color", "-U0", *git_args, "--", SNAPSHOT],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    if diff.returncode != 0:
        sys.exit(diff.stderr.strip() or f"git diff exited {diff.returncode}")

    old: dict[str, int] = {}
    new: dict[str, int] = {}
    for line in diff.stdout.splitlines():
        # the `--- a/`, `+++ b/` and `@@` headers carry no `(gas: n)`, so the regex drops them
        match = MEASUREMENT.match(line)
        if match:
            sign, name, gas = match.groups()
            (old if sign == "-" else new)[name] = int(gas)
    return old, new


def report(old: dict[str, int], new: dict[str, int]) -> None:
    groups: dict[int, list[str]] = defaultdict(list)
    for name, gas in new.items():
        if name in old and (delta := gas - old[name]):
            groups[delta].append(name)
    added = sorted(new.keys() - old.keys())
    removed = sorted(old.keys() - new.keys())

    if not (groups or added or removed):
        print("no measurement changes")
        return

    width = max((len(f"{delta:+,}") for delta in groups), default=len("delta"))
    columns = max(shutil.get_terminal_size((100, 24)).columns, width + 24)
    if groups:
        print(f"{'delta':>{width}}  measurements")
    for delta in sorted(groups, key=lambda d: (-abs(d), d)):
        print(
            textwrap.fill(
                ", ".join(sorted(groups[delta])),
                width=columns,
                initial_indent=f"{delta:>+{width},}  ",
                subsequent_indent=" " * (width + 2),
                break_long_words=False,
                break_on_hyphens=False,
            )
        )
    for label, names in (("added", added), ("removed", removed)):
        if names:
            print(f"\n{label}: {', '.join(names)}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    # no declared arguments: a positional would absorb revisions instead of forwarding them
    _, git_args = parser.parse_known_args()
    report(*sides(git_args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
