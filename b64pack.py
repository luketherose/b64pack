#!/usr/bin/env python3
"""Comprime file o cartelle in uno zip e lo trasforma in testo base64, e viceversa.

Esempi:
  b64pack pack contratto.pdf                -> contratto.zip.b64.txt
  b64pack pack ~/dev/biblioteca --split 1   -> biblioteca.zip.b64.part1of3.txt, ...
  b64pack unpack biblioteca.zip.b64.part1of3.txt -x biblioteca

Il testo e' base64 puro a righe di 76 caratteri, quindi si decodifica anche senza
questo script (le parti, in ordine, vanno solo concatenate):
  macOS e Linux:  cat contratto.zip.b64*.txt | base64 -d > contratto.zip
"""

import argparse
import base64
import binascii
import fnmatch
import glob
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import zipfile
import zlib
from pathlib import Path

LINE_WIDTH = 76

# Mai utili in un archivio di sorgenti: controllo versione, IDE, cache.
ALWAYS_SKIPPED_DIRS = {
    ".git", ".svn", ".hg", ".idea", ".vscode", ".gradle",
    "node_modules", "__pycache__", "__MACOSX",
}
ALWAYS_SKIPPED_FILES = {".DS_Store", "Thumbs.db"}
SKIPPED_FILE_PATTERNS = ("*.class",)

# target/, build/ e out/ si saltano solo accanto a un file di build: altrove
# (per esempio src/main/java/com/acme/build) possono essere un package vero.
BUILD_OUTPUT_DIRS = {"target", "build", "out"}
BUILD_FILES = {
    "pom.xml", "build.gradle", "build.gradle.kts",
    "settings.gradle", "settings.gradle.kts", "build.xml",
}

PART_RE = re.compile(r"^(?P<prefix>.+)\.part(?P<index>\d+)of(?P<total>\d+)\.txt$")


def fail(message):
    print(f"b64pack: errore: {message}", file=sys.stderr)
    sys.exit(1)


def human(size):
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------- pack

def collect(sources, include_all):
    entries = []
    skipped_dirs = []
    skipped_files = 0
    for src in sources:
        if src.is_file():
            entries.append((src, src.name))
            continue
        for dirpath, dirnames, filenames in os.walk(src):
            current = Path(dirpath)
            has_build_file = bool(BUILD_FILES.intersection(filenames))
            kept = []
            for name in sorted(dirnames):
                skip = name in ALWAYS_SKIPPED_DIRS or (has_build_file and name in BUILD_OUTPUT_DIRS)
                if skip and not include_all:
                    skipped_dirs.append((Path(src.name) / (current / name).relative_to(src)).as_posix() + "/")
                else:
                    kept.append(name)
            dirnames[:] = kept
            for name in sorted(filenames):
                skip = name in ALWAYS_SKIPPED_FILES or any(fnmatch.fnmatch(name, p) for p in SKIPPED_FILE_PATTERNS)
                if skip and not include_all:
                    skipped_files += 1
                    continue
                path = current / name
                arcname = (Path(src.name) / path.relative_to(src)).as_posix()
                entries.append((path, arcname))
    return entries, skipped_dirs, skipped_files


def build_zip(entries):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9,
                         strict_timestamps=False) as archive:
        for path, arcname in entries:
            archive.write(path, arcname)
    return buffer.getvalue()


def zip_base(args, sources):
    if args.output:
        name = Path(os.path.abspath(os.path.expanduser(args.output)))
        stem = name.name
        for suffix in (".txt", ".b64", ".zip"):
            if stem.endswith(suffix):
                stem = stem[: -len(suffix)]
        return name.with_name(stem + ".zip")
    if len(sources) > 1:
        stem = "archivio"
    elif sources[0].is_file():
        stem = sources[0].stem
    else:
        stem = sources[0].name
    return Path.cwd() / (stem + ".zip")


def existing_outputs(base):
    pattern = glob.escape(str(base)) + ".b64.part*of*.txt"
    found = [Path(p) for p in glob.glob(pattern)]
    single = Path(str(base) + ".b64.txt")
    if single.exists():
        found.append(single)
    return sorted(found)


def pack(args):
    sources = []
    for raw in args.paths:
        src = Path(os.path.abspath(os.path.expanduser(raw)))
        if not src.exists():
            fail(f"non trovo {raw}")
        sources.append(src)

    base = zip_base(args, sources)
    old = existing_outputs(base)
    if old and not args.force:
        fail(f"esiste gia' {old[0].name} (usa --force per sovrascrivere)")
    for path in old:
        path.unlink()

    single_zip = len(sources) == 1 and sources[0].is_file() and zipfile.is_zipfile(sources[0])
    if single_zip:
        data = sources[0].read_bytes()
        print(f"{sources[0].name} e' gia' uno zip: lo codifico cosi' com'e'")
    else:
        entries, skipped_dirs, skipped_files = collect(sources, args.all)
        if not entries:
            fail("nessun file da comprimere")
        arcnames = [arcname for _, arcname in entries]
        if len(set(arcnames)) != len(arcnames):
            dup = next(a for a in arcnames if arcnames.count(a) > 1)
            fail(f"due input finirebbero nello zip con lo stesso nome: {dup}")
        data = build_zip(entries)
        print(f"{len(entries)} file compressi")
        if skipped_dirs or skipped_files:
            shown = skipped_dirs[:8]
            more = f" e altre {len(skipped_dirs) - 8}" if len(skipped_dirs) > 8 else ""
            files = f", {skipped_files} file (.class, .DS_Store)" if skipped_files else ""
            print(f"esclusi (--all per includerli): {', '.join(shown)}{more}{files}")

    text = base64.b64encode(data).decode("ascii")
    lines = [text[i:i + LINE_WIDTH] for i in range(0, len(text), LINE_WIDTH)]
    if args.split:
        per_part = max(1, int(args.split * 1024 * 1024) // (LINE_WIDTH + 1))
        chunks = [lines[i:i + per_part] for i in range(0, len(lines), per_part)]
    else:
        chunks = [lines]

    if len(chunks) == 1:
        outputs = [Path(str(base) + ".b64.txt")]
    else:
        width = len(str(len(chunks)))
        outputs = [Path(f"{base}.b64.part{i:0{width}d}of{len(chunks)}.txt") for i in range(1, len(chunks) + 1)]
    outputs[0].parent.mkdir(parents=True, exist_ok=True)
    for path, chunk in zip(outputs, chunks):
        path.write_text("\n".join(chunk) + "\n", encoding="ascii")

    check = base64.b64decode("".join(p.read_text(encoding="ascii") for p in outputs).replace("\n", ""))
    if check != data:
        fail("verifica fallita: il testo scritto non restituisce lo zip")

    total_text = sum(p.stat().st_size for p in outputs)
    print(f"zip {human(len(data))}, testo {human(total_text)} in {len(outputs)} file:")
    for path in outputs:
        print(f"  {os.path.relpath(path, Path.cwd())}")
    print(f"sha256 dello zip: {sha256(data)}")

    if args.copy:
        if len(outputs) > 1:
            print("--copy vale solo con un file: copia le parti una alla volta (pbcopy < parte)")
        elif shutil.which("pbcopy"):
            subprocess.run(["pbcopy"], input=outputs[0].read_bytes(), check=True)
            print("testo copiato negli appunti")
        else:
            print("pbcopy non c'e' su questo sistema: apri il file e copialo a mano")


# ---------------------------------------------------------------- unpack

def resolve_parts(paths):
    """Con una sola parte indicata trova le altre nella stessa cartella."""
    matches = [PART_RE.match(p.name) for p in paths]
    if not any(matches):
        return sorted(paths, key=lambda p: p.name) if len(paths) > 1 else paths
    first = next(m for m in matches if m)
    prefix, total = first.group("prefix"), int(first.group("total"))
    folder = paths[matches.index(first)].parent
    width = len(first.group("index"))
    expected = [folder / f"{prefix}.part{i:0{width}d}of{total}.txt" for i in range(1, total + 1)]
    missing = [p.name for p in expected if not p.exists()]
    if missing:
        fail(f"mancano {len(missing)} parti su {total}: {', '.join(missing)}")
    return expected


def zip_name(first):
    name = first.name
    match = PART_RE.match(name)
    if match:
        name = match.group("prefix")
    elif name.endswith(".txt"):
        name = name[: -len(".txt")]
    if name.endswith(".b64"):
        name = name[: -len(".b64")]
    if not name.endswith(".zip"):
        name += ".zip"
    return Path.cwd() / name


def unpack(args):
    paths = [Path(os.path.expanduser(raw)) for raw in args.files]
    for path in paths:
        if not path.is_file():
            fail(f"non trovo {path}")
    paths = resolve_parts(paths)

    pieces = []
    for path in paths:
        compact = re.sub(r"\s+", "", path.read_text(encoding="utf-8-sig", errors="replace"))
        bad = re.search(r"[^A-Za-z0-9+/=]", compact)
        if bad:
            fail(f"{path.name} contiene un carattere che non e' base64: {bad.group()!r}")
        pieces.append(compact)
    try:
        data = base64.b64decode("".join(pieces), validate=True)
    except binascii.Error:
        fail("il testo e' incompleto o troncato (manca un pezzo dell'incolla?)")

    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            broken = archive.testzip()
            count = len(archive.infolist())
    except (zipfile.BadZipFile, zlib.error, EOFError, OSError):
        broken, count = "(indice dello zip)", 0
    if broken:
        fail(f"lo zip decodificato e' danneggiato, primo file rotto: {broken}")

    if args.extract:
        target = Path(os.path.expanduser(args.extract))
        if target.exists() and any(target.iterdir()) and not args.force:
            fail(f"{target} non e' vuota (usa --force per estrarci dentro lo stesso)")
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            archive.extractall(target)
        print(f"{count} file estratti in {target}")
    else:
        output = Path(os.path.expanduser(args.output)) if args.output else zip_name(paths[0])
        if output.exists() and not args.force:
            fail(f"esiste gia' {output} (usa --force per sovrascrivere)")
        output.write_bytes(data)
        print(f"zip con {count} file scritto in {os.path.relpath(output, Path.cwd())}")
    print(f"sha256 dello zip: {sha256(data)}")


# ---------------------------------------------------------------- cli

def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="b64pack",
        description="Zip in testo base64 da incollare (per esempio su GitHub), e ritorno.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("\n", 2)[2],
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("pack", help="file o cartelle -> zip -> testo base64")
    p.add_argument("paths", nargs="+", help="file (PDF, zip, ...) o cartelle (progetti Java, ...)")
    p.add_argument("-o", "--output", help="nome base dell'output (default: nome del primo input)")
    p.add_argument("--split", type=float, metavar="MB",
                   help="spezza il testo in parti da al massimo MB megabyte")
    p.add_argument("--all", action="store_true",
                   help="includi anche .git, .idea, target/, build/, *.class, ...")
    p.add_argument("--copy", action="store_true", help="copia il testo negli appunti (macOS)")
    p.add_argument("--force", action="store_true", help="sovrascrivi un output esistente")
    p.set_defaults(func=pack)

    u = sub.add_parser("unpack", help="testo base64 -> zip (o cartella con -x)")
    u.add_argument("files", nargs="+", help="il file .b64.txt, oppure una o tutte le parti")
    u.add_argument("-o", "--output", help="percorso dello zip da scrivere")
    u.add_argument("-x", "--extract", metavar="CARTELLA", help="estrai il contenuto invece di scrivere lo zip")
    u.add_argument("--force", action="store_true", help="sovrascrivi o estrai in una cartella non vuota")
    u.set_defaults(func=unpack)

    args = parser.parse_args(argv)
    if getattr(args, "split", None) is not None and args.split <= 0:
        parser.error("--split vuole un numero di MB maggiore di zero")
    args.func(args)


if __name__ == "__main__":
    main()
