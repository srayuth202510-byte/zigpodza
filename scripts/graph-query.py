#!/usr/bin/env python3
"""Offline Knowledge Graph indexer & query CLI for ZigPod.

Indexes Obsidian notes in docs/vault/*.md and Zig source modules in src/*.zig,
caches the graph at .zig-cache/knowledge-graph.json, and answers `update`,
`query`, `explain`, and `path` requests with exact `file:line` citations.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import deque
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
VAULT_DIR = ROOT / "docs" / "vault"
SRC_DIR = ROOT / "src"
CACHE_PATH = ROOT / ".zig-cache" / "knowledge-graph.json"

WIKILINK_RE = re.compile(r"\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]")
MD_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
INLINE_TAG_RE = re.compile(r"(?:^|\s)(#[a-zA-Z0-9_-]+)")
BUG_HEADING_RE = re.compile(r"^##\s+(BUG-\d+):\s*(.+?)(?:\s+#.*)?$")
ZIG_IMPORT_RE = re.compile(r'@import\("([^"]+\.zig)"\)')
ZIG_PUB_RE = re.compile(r"^\s*pub\s+(?:fn|const)\s+([A-Za-z_][A-Za-z0-9_]*)")
ZIG_TEST_RE = re.compile(r'^\s*test\s+"([^"]+)"')


def rel_posix(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def parse_frontmatter(lines: list[str]) -> tuple[list[str], list[str], int]:
    """Extracts YAML frontmatter tags & aliases; returns (tags, aliases, body_start_idx)."""
    tags: list[str] = []
    aliases: list[str] = []
    if not lines or lines[0].strip() != "---":
        return tags, aliases, 0

    end_idx = None
    section: str | None = None
    for idx in range(1, len(lines)):
        stripped = lines[idx].strip()
        if stripped == "---":
            end_idx = idx
            break
        if stripped.startswith("tags:"):
            section = "tags"
            inline = stripped[len("tags:") :].strip()
            if inline.startswith("[") and inline.endswith("]"):
                tags.extend(t.strip().strip("\"'") for t in inline[1:-1].split(",") if t.strip())
                section = None
        elif stripped.startswith("aliases:"):
            section = "aliases"
        elif stripped.startswith("- ") and section == "tags":
            tags.append(stripped[2:].strip().strip("\"'"))
        elif stripped.startswith("- ") and section == "aliases":
            aliases.append(stripped[2:].strip().strip("\"'"))
        elif ":" in stripped:
            section = None

    if end_idx is None:
        return [], [], 0
    return tags, aliases, end_idx + 1


def build_graph() -> dict[str, Any]:
    nodes: dict[str, dict[str, Any]] = {}
    edges: list[dict[str, Any]] = []
    seen_edges: set[tuple[str, str, str, str]] = set()

    def add_node(node_id: str, **attrs: Any) -> None:
        if node_id not in nodes:
            nodes[node_id] = {"id": node_id, **attrs}
        else:
            for k, v in attrs.items():
                if v and not nodes[node_id].get(k):
                    nodes[node_id][k] = v

    def add_edge(src: str, dst: str, kind: str, cite: str) -> None:
        key = (src, dst, kind, cite)
        if key not in seen_edges:
            seen_edges.add(key)
            edges.append({"src": src, "dst": dst, "kind": kind, "cite": cite})

    # 1. Index Zig source modules and exported symbols first so vault links can resolve cleanly.
    zig_files = sorted(SRC_DIR.glob("*.zig"))
    symbol_index: dict[str, set[str]] = {}
    for zpath in zig_files:
        rpath = rel_posix(zpath)
        mod_id = f"module:{rpath}"
        lines = zpath.read_text(encoding="utf-8").splitlines()
        symbols: list[dict[str, Any]] = []
        tests: list[dict[str, Any]] = []
        imports: list[tuple[str, int]] = []

        for lineno, line in enumerate(lines, start=1):
            m_imp = ZIG_IMPORT_RE.search(line)
            if m_imp:
                target_rel = f"src/{m_imp.group(1)}"
                imports.append((target_rel, lineno))

            m_pub = ZIG_PUB_RE.match(line)
            if m_pub:
                sym_name = m_pub.group(1)
                symbols.append({"name": sym_name, "line": lineno, "cite": f"{rpath}:{lineno}"})
                symbol_index.setdefault(sym_name, set()).add(mod_id)

            m_test = ZIG_TEST_RE.match(line)
            if m_test:
                tests.append({"name": m_test.group(1), "line": lineno, "cite": f"{rpath}:{lineno}"})

        add_node(
            mod_id,
            kind="module",
            title=zpath.name,
            file=rpath,
            line=1,
            cite=f"{rpath}:1",
            tags=["zig", zpath.stem],
            aliases=[zpath.name, zpath.stem],
            symbols=symbols,
            tests=tests,
            lines_count=len(lines),
        )

        for target_rel, lineno in imports:
            add_edge(mod_id, f"module:{target_rel}", "imports", f"{rpath}:{lineno}")

    # 2. Index Obsidian vault markdown notes and BUG-NNN records.
    md_files = sorted(VAULT_DIR.glob("*.md"))
    for mpath in md_files:
        rpath = rel_posix(mpath)
        note_id = f"vault:{mpath.stem}"
        raw_lines = mpath.read_text(encoding="utf-8").splitlines()
        fm_tags, fm_aliases, body_idx = parse_frontmatter(raw_lines)
        title = mpath.stem
        inline_tags: set[str] = set(fm_tags)
        sections: list[dict[str, Any]] = []
        current_bug_id: str | None = None

        for idx in range(body_idx, len(raw_lines)):
            lineno = idx + 1
            line = raw_lines[idx]
            if line.startswith("# ") and title == mpath.stem:
                title = line[2:].strip()

            m_bug = BUG_HEADING_RE.match(line)
            if m_bug:
                bug_code = m_bug.group(1)
                bug_title = m_bug.group(2).strip()
                current_bug_id = f"bug:{bug_code}"
                bug_tags = [t.lstrip("#") for t in INLINE_TAG_RE.findall(line)]
                add_node(
                    current_bug_id,
                    kind="bug",
                    title=f"{bug_code}: {bug_title}",
                    file=rpath,
                    line=lineno,
                    cite=f"{rpath}:{lineno}",
                    tags=sorted(set(bug_tags + ["bug-pattern"])),
                    aliases=[bug_code, bug_code.lower()],
                    symbols=[],
                    tests=[],
                )
                add_edge(note_id, current_bug_id, "defines", f"{rpath}:{lineno}")
            elif line.startswith("## "):
                current_bug_id = None
                sections.append({"heading": line[3:].strip(), "line": lineno, "cite": f"{rpath}:{lineno}"})

            for t in INLINE_TAG_RE.findall(line):
                inline_tags.add(t.lstrip("#"))

            owner = current_bug_id or note_id
            for wiki in WIKILINK_RE.findall(line):
                add_edge(owner, f"vault:{wiki.strip()}", "wikilink", f"{rpath}:{lineno}")

            for href in MD_LINK_RE.findall(line):
                cleaned = href.split("#", 1)[0].strip()
                if not cleaned or cleaned.startswith("http"):
                    continue
                resolved = (mpath.parent / cleaned).resolve()
                try:
                    target_rel = rel_posix(resolved)
                except ValueError:
                    continue
                if target_rel.startswith("src/") and target_rel.endswith(".zig"):
                    add_edge(owner, f"module:{target_rel}", "references", f"{rpath}:{lineno}")
                elif target_rel.startswith("docs/vault/") and target_rel.endswith(".md"):
                    add_edge(owner, f"vault:{resolved.stem}", "links", f"{rpath}:{lineno}")

            for sym_name, mod_ids in symbol_index.items():
                if len(sym_name) >= 7 and len(mod_ids) == 1 and re.search(rf"\b{re.escape(sym_name)}\b", line):
                    mod_id = next(iter(mod_ids))
                    add_edge(owner, mod_id, "mentions_symbol", f"{rpath}:{lineno}")

        add_node(
            note_id,
            kind="vault",
            title=title,
            file=rpath,
            line=1,
            cite=f"{rpath}:1",
            tags=sorted(inline_tags),
            aliases=sorted(set(fm_aliases + [mpath.stem, mpath.name])),
            sections=sections,
            symbols=[],
            tests=[],
            lines_count=len(raw_lines),
        )

    return {
        "version": 1,
        "nodes": nodes,
        "edges": edges,
    }


def latest_input_mtime() -> float:
    mtimes = [p.stat().st_mtime for p in list(VAULT_DIR.glob("*.md")) + list(SRC_DIR.glob("*.zig"))]
    mtimes.append(Path(__file__).stat().st_mtime)
    return max(mtimes) if mtimes else 0.0


def load_or_update(force_update: bool = False) -> dict[str, Any]:
    if not force_update and CACHE_PATH.exists():
        if CACHE_PATH.stat().st_mtime >= latest_input_mtime():
            return json.loads(CACHE_PATH.read_text(encoding="utf-8"))

    graph = build_graph()
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    CACHE_PATH.write_text(json.dumps(graph, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return graph


def resolve_node(graph: dict[str, Any], raw: str) -> str | None:
    nodes: dict[str, dict[str, Any]] = graph["nodes"]
    q = raw.strip()
    if q in nodes:
        return q

    ql = q.lower()
    for candidate in (f"module:{q}", f"module:src/{q}", f"vault:{q}", f"bug:{q}", f"bug:{q.upper()}"):
        if candidate in nodes:
            return candidate

    for nid, data in nodes.items():
        if data.get("title", "").lower() == ql or data.get("file", "").lower() == ql:
            return nid
        for alias in data.get("aliases", []):
            if alias.lower() == ql:
                return nid
        for sym in data.get("symbols", []):
            if sym["name"].lower() == ql:
                return nid

    # Substring fallback when unambiguous or highest priority match
    matches = [
        nid
        for nid, data in nodes.items()
        if ql in nid.lower()
        or ql in data.get("title", "").lower()
        or any(ql == s["name"].lower() for s in data.get("symbols", []))
    ]
    return sorted(matches)[0] if len(matches) == 1 else (sorted(matches)[0] if matches else None)


def cmd_update(args: argparse.Namespace) -> int:
    graph = load_or_update(force_update=True)
    payload = {
        "cache": rel_posix(CACHE_PATH),
        "nodes": len(graph["nodes"]),
        "edges": len(graph["edges"]),
    }
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(
            f"knowledge-graph updated: {payload['nodes']} nodes, "
            f"{payload['edges']} edges -> {payload['cache']}"
        )
    return 0


def cmd_query(args: argparse.Namespace) -> int:
    graph = load_or_update()
    q = args.term.strip().lstrip("#").lower()
    hits: list[dict[str, Any]] = []

    for nid, data in sorted(graph["nodes"].items()):
        score = 0
        matched_cites: list[str] = []
        if q in nid.lower() or q in data.get("title", "").lower():
            score += 4
            matched_cites.append(data["cite"])
        for tag in data.get("tags", []):
            if q in tag.lower():
                score += 3
                matched_cites.append(data["cite"])
        for sym in data.get("symbols", []):
            if q in sym["name"].lower():
                score += 3
                matched_cites.append(f"{sym['cite']} ({sym['name']})")
        for t in data.get("tests", []):
            if q in t["name"].lower():
                score += 2
                matched_cites.append(f"{t['cite']} (test: {t['name']})")
        for sec in data.get("sections", []):
            if q in sec["heading"].lower():
                score += 2
                matched_cites.append(f"{sec['cite']} ({sec['heading']})")

        # Line-level text scan on backing file for exact line citations.
        fpath = ROOT / data["file"]
        if fpath.exists():
            start_l = data.get("line", 1)
            lines = fpath.read_text(encoding="utf-8").splitlines()
            end_l = len(lines)
            if data["kind"] == "bug":
                for off in range(start_l, len(lines)):
                    if lines[off].startswith("## "):
                        end_l = off
                        break
            for lno in range(start_l, end_l + 1):
                if q in lines[lno - 1].lower():
                    score += 1
                    matched_cites.append(f"{data['file']}:{lno}")
                    if len(matched_cites) >= 8:
                        break

        if score > 0:
            dedup_cites = list(dict.fromkeys(matched_cites))
            hits.append({
                "id": nid,
                "kind": data["kind"],
                "title": data["title"],
                "cite": data["cite"],
                "tags": data.get("tags", []),
                "score": score,
                "citations": dedup_cites[:6],
            })

    hits.sort(key=lambda h: (-h["score"], h["id"]))
    if args.json:
        print(json.dumps({"query": args.term, "count": len(hits), "results": hits}, indent=2, ensure_ascii=False))
        return 0 if hits else 1

    if not hits:
        print(f"No knowledge graph matches for '{args.term}'.")
        return 1

    print(f"Query '{args.term}' -> {len(hits)} matching node(s):")
    for item in hits[:15]:
        tags_str = " ".join(f"#{t}" for t in item["tags"][:5])
        print(f"  - [{item['kind']}] {item['id']} ({item['title']}) @ {item['cite']} {tags_str}")
        for cite in item["citations"]:
            if cite != item["cite"]:
                print(f"      cite: {cite}")
    return 0


def cmd_explain(args: argparse.Namespace) -> int:
    graph = load_or_update()
    nid = resolve_node(graph, args.node)
    if nid is None or nid not in graph["nodes"]:
        print(f"Node not found: '{args.node}'", file=sys.stderr)
        return 1

    data = graph["nodes"][nid]
    outgoing = [e for e in graph["edges"] if e["src"] == nid]
    incoming = [e for e in graph["edges"] if e["dst"] == nid]

    if args.json:
        print(json.dumps({"node": data, "outgoing": outgoing, "incoming": incoming}, indent=2, ensure_ascii=False))
        return 0

    print(f"{nid} ({data['kind']}): {data['title']}")
    print(f"  Source: {data['cite']}")
    if data.get("tags"):
        print("  Tags: " + ", ".join(f"#{t}" for t in data["tags"]))
    if data.get("symbols"):
        print("  Public symbols:")
        for sym in data["symbols"][:15]:
            print(f"    - {sym['name']} ({sym['cite']})")
    if data.get("tests"):
        print(f"  Unit tests ({len(data['tests'])}):")
        for t in data["tests"][:10]:
            print(f"    - {t['name']} ({t['cite']})")
    if outgoing:
        print("  Outgoing links:")
        for e in outgoing[:20]:
            print(f"    - [{e['kind']}] -> {e['dst']} ({e['cite']})")
    if incoming:
        print("  Incoming links:")
        for e in incoming[:20]:
            print(f"    - [{e['kind']}] <- {e['src']} ({e['cite']})")
    return 0


def cmd_path(args: argparse.Namespace) -> int:
    graph = load_or_update()
    src = resolve_node(graph, args.src)
    dst = resolve_node(graph, args.dst)
    if src is None or dst is None:
        missing = args.src if src is None else args.dst
        print(f"Node not found: '{missing}'", file=sys.stderr)
        return 1

    adj: dict[str, list[tuple[str, dict[str, Any]]]] = {nid: [] for nid in graph["nodes"]}
    for e in graph["edges"]:
        if e["src"] in adj and e["dst"] in adj:
            adj[e["src"]].append((e["dst"], e))
            adj[e["dst"]].append((e["src"], e))

    queue: deque[str] = deque([src])
    parent: dict[str, tuple[str, dict[str, Any]] | None] = {src: None}
    while queue:
        cur = queue.popleft()
        if cur == dst:
            break
        for nxt, edge in sorted(adj.get(cur, []), key=lambda x: x[0]):
            if nxt not in parent:
                parent[nxt] = (cur, edge)
                queue.append(nxt)

    if dst not in parent:
        print(f"No path found between '{src}' and '{dst}'.", file=sys.stderr)
        return 1

    hops: list[tuple[str, dict[str, Any] | None]] = []
    cur_id: str | None = dst
    while cur_id is not None:
        prev = parent[cur_id]
        if prev is None:
            hops.append((cur_id, None))
            cur_id = None
        else:
            hops.append((cur_id, prev[1]))
            cur_id = prev[0]
    hops.reverse()

    if args.json:
        print(
            json.dumps(
                {
                    "src": src,
                    "dst": dst,
                    "hops": [
                        {
                            "node": nid,
                            "cite": graph["nodes"][nid]["cite"],
                            "via": edge,
                        }
                        for nid, edge in hops
                    ],
                },
                indent=2,
                ensure_ascii=False,
            )
        )
        return 0

    print(f"Shortest path ({len(hops) - 1} hop(s)): {src} -> {dst}")
    for idx, (nid, edge) in enumerate(hops):
        node_cite = graph["nodes"][nid]["cite"]
        if edge is None:
            print(f"  {idx}. {nid} ({node_cite})")
        else:
            direction = "->" if edge["dst"] == nid else "<-"
            print(f"  {idx}. {direction} [{edge['kind']} @ {edge['cite']}] {nid} ({node_cite})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="ZigPod Offline Knowledge Graph CLI")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_up = sub.add_parser("update", help="Rebuild .zig-cache/knowledge-graph.json")
    p_up.add_argument("--json", action="store_true")

    p_q = sub.add_parser("query", help="Search nodes, symbols, bugs, tags, and files")
    p_q.add_argument("term")
    p_q.add_argument("--json", action="store_true")

    p_ex = sub.add_parser("explain", help="Inspect node details and links with file:line citations")
    p_ex.add_argument("node")
    p_ex.add_argument("--json", action="store_true")

    p_path = sub.add_parser("path", help="Find shortest relationship path between two nodes")
    p_path.add_argument("src")
    p_path.add_argument("dst")
    p_path.add_argument("--json", action="store_true")

    args = parser.parse_args()
    if args.cmd == "update":
        return cmd_update(args)
    if args.cmd == "query":
        return cmd_query(args)
    if args.cmd == "explain":
        return cmd_explain(args)
    if args.cmd == "path":
        return cmd_path(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
