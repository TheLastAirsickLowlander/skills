#!/usr/bin/env python3
"""
Link checker for reqs/ documentation trees.

Verifies that every relative link in every markdown file resolves to an existing
file/directory, and that any in-document anchor fragment matches a real heading.

Usage:
    python link_checker.py <reqs-root-dir>
    python link_checker.py reqs/           # from repo root
    python link_checker.py .               # from inside reqs/

Exit code: 0 if all links resolve, 1 if any are broken.
"""

import os
import re
import glob
import sys
import argparse


def heading_to_anchor(heading: str) -> str:
    """Convert a markdown heading string to its GitHub-style anchor slug."""
    s = heading.strip().lower()
    s = re.sub(r'[^\w\s-]', '', s)
    s = re.sub(r'\s+', '-', s)
    return s


def collect_anchors(filepath: str) -> set:
    """Return the set of anchor slugs defined by headings in a markdown file."""
    anchors = set()
    with open(filepath, encoding='utf-8') as f:
        for line in f:
            m = re.match(r'#{1,6}\s+(.*)', line)
            if m:
                anchors.add(heading_to_anchor(m.group(1)))
    return anchors


def check_links(root: str) -> tuple[int, list, list]:
    """
    Walk all .md files under root and check every relative link.

    Returns:
        (checked_count, broken_list, missing_anchor_list)
        where each list item is (relative_file_path, raw_link_target)
    """
    root = os.path.abspath(root)
    md_files = glob.glob(os.path.join(root, '**/*.md'), recursive=True)

    # Pre-build anchor maps so each file is read only once
    anchor_map: dict[str, set] = {}
    for f in md_files:
        anchor_map[os.path.normpath(f)] = collect_anchors(f)

    link_re = re.compile(r'\[[^\]]*\]\(([^)]+)\)')
    broken: list[tuple[str, str]] = []
    anchor_miss: list[tuple[str, str]] = []
    checked = 0

    for filepath in md_files:
        file_dir = os.path.dirname(filepath)
        content = open(filepath, encoding='utf-8').read()

        for raw in link_re.findall(content):
            target_raw = raw.strip()

            # Skip absolute URLs and mailto
            if target_raw.startswith(('http://', 'https://', 'mailto:')):
                continue

            path_part, _, fragment = target_raw.partition('#')
            checked += 1

            # Resolve the file target
            if path_part == '':
                # Pure anchor reference — same file
                target_file = os.path.normpath(filepath)
            else:
                target_file = os.path.normpath(os.path.join(file_dir, path_part))

            if not os.path.exists(target_file):
                broken.append((
                    os.path.relpath(filepath, root),
                    target_raw,
                ))
                continue

            # If there's a fragment and the target is a markdown file, verify the anchor
            if fragment and target_file.endswith('.md'):
                known = anchor_map.get(target_file, set())
                if heading_to_anchor(fragment) not in known:
                    anchor_miss.append((
                        os.path.relpath(filepath, root),
                        target_raw,
                    ))

    return checked, broken, anchor_miss


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Check all relative links in a reqs/ markdown tree.'
    )
    parser.add_argument(
        'root',
        help='Root directory to scan (e.g., reqs/ or .)',
    )
    args = parser.parse_args()

    if not os.path.isdir(args.root):
        print(f"Error: {args.root!r} is not a directory", file=sys.stderr)
        return 2

    md_count = len(glob.glob(os.path.join(args.root, '**/*.md'), recursive=True))
    checked, broken, anchor_miss = check_links(args.root)

    print(f"Scanned {md_count} markdown files, checked {checked} relative links")
    print(f"Broken file targets : {len(broken)}")
    for filepath, link in broken:
        print(f"  {filepath} -> {link}")

    print(f"Missing anchors     : {len(anchor_miss)}")
    for filepath, link in anchor_miss:
        print(f"  {filepath} -> {link}")

    if broken or anchor_miss:
        print("\nResult: FAIL")
        return 1

    print("\nResult: OK — all links resolve")
    return 0


if __name__ == '__main__':
    sys.exit(main())
