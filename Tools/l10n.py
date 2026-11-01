#!/usr/bin/env python3
"""Traductions de l'interface.

Le code écrit les textes en français dans L("…") ; chaque interpolation \\(…) devient « %@ » dans la clé.
Les traductions vivent dans Tools/l10n/<langue>.json ({clé française: traduction}).

    Tools/l10n.py keys FICHIER.swift…      clés L("…") des fichiers, une par ligne (JSON)
    Tools/l10n.py missing en [FICHIERS…]   clés sans traduction anglaise (ou missing chemin.json FICHIERS…)
    Tools/l10n.py build                    écrit Resources/<langue>.lproj/Localizable.strings
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
TRANSLATIONS = ROOT / "Tools" / "l10n"
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def literal_end(text, i):
    """Fin (indice après le guillemet fermant) d'un littéral simple commençant en text[i] == '"'."""
    i += 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            if text[i + 1] == "(":
                depth, i = 1, i + 2
                while depth:
                    if text[i] == '"':
                        i = literal_end(text, i)
                        continue
                    depth += {"(": 1, ")": -1}.get(text[i], 0)
                    i += 1
                continue
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    raise ValueError("littéral non terminé")


def key_of(literal):
    """Clé d'un littéral Swift (avec ses guillemets), comme la calcule LocalizedText."""
    body, key, i = literal[1:-1], "", 0
    while i < len(body):
        c = body[i]
        if c == "\\":
            n = body[i + 1]
            if n == "(":
                depth, i = 1, i + 2
                while depth:
                    if body[i] == '"':
                        i = literal_end(body, i)
                        continue
                    depth += {"(": 1, ")": -1}.get(body[i], 0)
                    i += 1
                key += "%@"
                continue
            if n == "u":
                end = body.index("}", i)
                key += chr(int(body[i + 3:end], 16))
                i = end + 1
                continue
            key += ESCAPES.get(n, n)
            i += 2
            continue
        key += "%%" if c == "%" else c
        i += 1
    return key


def keys_in(path):
    text = path.read_text(encoding="utf-8")
    keys = []
    for match in re.finditer(r'(?<![\w.])L\(\s*"', text):
        start = match.end() - 1
        if text.startswith('"""', start):
            raise SystemExit(f"{path}: littéral multiligne interdit dans L(…)")
        keys.append(key_of(text[start:literal_end(text, start)]))
    return keys


def all_keys(files=None):
    paths = [pathlib.Path(f) for f in files] if files else sorted(SOURCES.rglob("*.swift"))
    seen = {}
    for path in paths:
        for key in keys_in(path):
            seen.setdefault(key, path)
    return seen


def load(language):
    path = pathlib.Path(language) if language.endswith(".json") else TRANSLATIONS / f"{language}.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def main():
    command, args = sys.argv[1], sys.argv[2:]
    if command == "keys":
        for key in all_keys(args):
            print(json.dumps(key, ensure_ascii=False))
    elif command == "missing":
        translations = load(args[0])
        missing = [k for k in all_keys(args[1:]) if k not in translations]
        for key in missing:
            print(json.dumps(key, ensure_ascii=False))
        print(f"{len(missing)} clé(s) sans traduction", file=sys.stderr)
    elif command == "build":
        keys = all_keys()
        for path in sorted(TRANSLATIONS.glob("*.json")):
            language = path.stem
            translations = load(language)
            lines = ["/* Généré par Tools/l10n.py depuis Tools/l10n/%s.json : ne pas modifier à la main. */" % language]
            missing = 0
            for key in sorted(keys):
                if key in translations:
                    if translations[key].count("%@") + len(re.findall(r"%\d+\$@", translations[key])) != key.count("%@"):
                        print(f"{language}: nombre de %@ différent pour {key!r}", file=sys.stderr)
                    lines.append(f'"{escape(key)}" = "{escape(translations[key])}";')
                else:
                    missing += 1
            folder = ROOT / "Resources" / f"{language}.lproj"
            folder.mkdir(exist_ok=True)
            (folder / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
            print(f"{language}: {len(keys) - missing}/{len(keys)} textes traduits")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
