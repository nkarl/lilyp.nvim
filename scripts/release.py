#!/usr/bin/env python3
"""Export a Git tree for a separate public repository, without Git history."""

import argparse
import io
from pathlib import Path, PurePosixPath
import subprocess
import tarfile


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def export(root, ref, destination):
    root = root.resolve()
    destination = destination.resolve()
    if destination == root or root in destination.parents:
        raise ValueError("The snapshot destination must be outside the development repository")
    if destination.exists():
        raise ValueError("The snapshot destination must not already exist")
    tree = git(root, "rev-parse", "--verify", "--end-of-options", ref + "^{tree}").decode().strip()
    archive = git(root, "archive", "--format=tar", tree)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        members = []
        for member in source.getmembers():
            parts = PurePosixPath(member.name).parts
            if parts and (parts[0] == "docs" or any(part.startswith("AGENTS") for part in parts)):
                continue
            # Reject unsafe links/paths before creating any output.
            tarfile.data_filter(member, str(destination))
            members.append(member)
        destination.mkdir(parents=True)
        source.extractall(destination, members=members, filter="data")
    return tree


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="new directory outside the development repository")
    parser.add_argument("--ref", default="HEAD", help="committed revision to export (default: HEAD)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        tree = export(root, args.ref, args.destination)
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        parser.exit(1, f"Snapshot export failed: {error}\n")
    print(f"Exported tree {tree} to {args.destination.resolve()}")
    print("Excluded docs/ and AGENTS* entries at every depth; no Git history was copied.")


if __name__ == "__main__":
    main()
