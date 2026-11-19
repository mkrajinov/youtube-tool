"""Extract Iconsax TwoTone SVGs from iconsax-react ESM files into a Swift source file."""
import re
import sys
from pathlib import Path

src_dir = Path(sys.argv[1])
out = Path(sys.argv[2])
names = sys.argv[3:]

ATTR = re.compile(r'(\w+):\s*("([^"]*)"|color|[\d.]+)')
CREATE = "React.createElement("


def skip_ws_comments(s, i):
    while True:
        while i < len(s) and s[i] in " \n\t,":
            i += 1
        if s.startswith("/*", i):
            i = s.index("*/", i) + 2
            continue
        return i


def balanced(s, i, open_ch, close_ch):
    """Return index just past the bracket matching s[i] (== open_ch), skipping strings."""
    depth = 0
    while i < len(s):
        c = s[i]
        if c == '"':
            i = s.index('"', i + 1)
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced")


def parse_element(s, i):
    """s[i:] starts with React.createElement( ; returns (svg_markup, next_index)."""
    i += len(CREATE)
    tag_end = s.index('"', i + 1)
    tag = s[i + 1:tag_end]
    i = skip_ws_comments(s, tag_end + 1)
    attrs = ""
    if s[i] == "{":
        end = balanced(s, i, "{", "}")
        attrs = render_attrs(s[i + 1:end - 1])
        i = end
    elif s.startswith("null", i):
        i += 4
    children = []
    while True:
        i = skip_ws_comments(s, i)
        if s[i] == ")":
            i += 1
            break
        if s.startswith(CREATE, i):
            child, i = parse_element(s, i)
            children.append(child)
        else:
            raise ValueError(f"unexpected {s[i:i+30]!r}")
    if tag == "React.Fragment" or not tag:
        return "".join(children), i
    if children:
        return f"<{tag}{attrs}>{''.join(children)}</{tag}>", i
    return f"<{tag}{attrs}/>", i


def render_attrs(body):
    out = []
    for key, raw, quoted in ATTR.findall(body):
        if raw == "color":
            val = "#000"
        elif raw.startswith('"'):
            val = quoted
        else:
            val = raw
        out.append(f' {kebab(key)}="{val}"')
    return "".join(out)


def kebab(s):
    return re.sub(r'([A-Z])', lambda m: '-' + m.group(1).lower(), s)


def twotone_svg(name):
    text = (src_dir / f"{name}.js").read_text()
    start = text.index("var TwoTone = function")
    end = text.index("var chooseVariant", start)
    block = text[start:end]
    # The variant returns React.createElement(React.Fragment, null, ...children)
    i = block.index("return") + len("return")
    i = skip_ws_comments(block, i)
    frag = block.index(CREATE, i)
    # Fragment's first arg is an identifier, not a string: parse children manually.
    j = block.index("null", frag) + 4
    parts = []
    while True:
        j = skip_ws_comments(block, j)
        if block[j] == ")":
            break
        child, j = parse_element(block, j)
        parts.append(child)
    if not parts:
        raise SystemExit(f"no elements for {name}")
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
            'viewBox="0 0 24 24" fill="none">' + "".join(parts) + "</svg>")


lines = [
    "// Generated from iconsax-react 0.0.8 (TwoTone variant). Do not edit by hand.",
    "// Regenerate with scripts/gen_icons.py.",
    "",
    "enum IconsaxSVG {",
    "    static let all: [String: String] = [",
]
for n in names:
    svg = twotone_svg(n).replace("\\", "\\\\").replace('"', '\\"')
    lines.append(f'        "{n}": "{svg}",')
lines += ["    ]", "}", ""]
out.write_text("\n".join(lines))
print(f"wrote {len(names)} icons to {out}")
