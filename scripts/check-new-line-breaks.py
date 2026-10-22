#!/usr/bin/env python3
"""Flag newly-added Markdown lines that pack more than one sentence/clause onto
a single source line -- a diff-scoped check for semantic line breaks (one
clause/sentence per line).

Design notes:
- **Diff-scoped, always.** Only lines *added* since ``NLB_BASE_REF`` (a PR/MR's
  base SHA or target branch) are checked, so a corpus that has already accumulated
  long lines (commonly because markdownlint's MD013 is disabled for exactly this
  reason) never gets reflagged on every unrelated edit.
- **No base_ref to diff against, or the diff can't be computed** (e.g. an
  unset base-ref on a push run to default branch, or a shallow clone missing the
  base commit): the check is *skipped* with a warning. There is no whole-tree
  fallback, unlike PHI scanning -- this check's entire purpose is to avoid ever
  reflagging pre-existing drift, so a whole-tree scan here would defeat the point.
- **Blocking by default** (``NLB_FAIL`` defaults to true): a long line
  carrying multiple sentences/clauses on one source line fails CI.
- **Two checks, both on by default.** Rule 4 of the SemBr spec (the
  normative MUST: break after a sentence) always applies. A narrow slice of
  rule 5 (the SHOULD: break after an independent clause) applies too, and is
  opt-out via ``NLB_CLAUSE_BREAKS=false`` (or ``--no-clause-breaks``) -- see
  ``has_late_semicolon`` for why that slice is semicolons only, and why it is
  gated on line length.
- **Moved-content exemption (gha#684):** An added line whose exact text was also
  deleted somewhere in the same diff is treated as relocated content rather than
  new writing and is not reported. Tracked via a multiset so one deletion cannot
  launder unlimited duplicates.
- **GitLab Code Quality output:** Supports generating a GitLab Code Quality JSON
  report artifact via ``NLB_CODEQUALITY_REPORT`` or ``--codequality-report``.

Configuration (via environment variables or CLI flags):
  NLB_BASE_REF          / --base-ref            Git ref/SHA to diff against.
  NLB_GLOBS             / --globs               Space-separated git pathspecs to check (default: '*.md').
  NLB_PATHS_IGNORE      / --paths-ignore        Comma/newline-separated glob patterns to skip.
  NLB_FAIL              / --fail / --no-fail    "false" => non-blocking; default "true" => blocking.
  NLB_CLAUSE_BREAKS     / --clause-breaks       "false" => skip clause check; default "true".
  NLB_CLAUSE_MIN_LENGTH / --clause-min-length   Minimum visible line length for clause check (default: 80).
  NLB_CODEQUALITY_REPORT / --codequality-report Path to write GitLab Code Quality JSON report.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Dict, List, NamedTuple, Optional, Set, Tuple, Union

# ── Sentence splitting ──────────────────────────────────────────────────────

# Abbreviations whose trailing period should NOT trigger a sentence split.
#
# These are protected on BOTH sentence-break branches, in their conventional
# case only (`No.`, `Dr.`, `Sec.`, `Fig.`, `e.g.`): a title or label
# abbreviation is essentially never a sentence end, whatever follows it.
# `_ABBREV_RE` runs once, up front, so it reaches both branches -- which is why
# the lowercase forms are handled separately below rather than added here.
_ABBREVS = [
    "e.g", "i.e", "vs", "Dr", "Mr", "Mrs", "Ms", "Jr", "Sr",
    "Fig", "Eq", "Ref", "Sec", "Ch", "Vol", "pp", "No",
    "incl", "excl", "ca", "cf", "pt", "Dept",
    "a.m", "p.m", "am", "pm",
]


def _abbrev_pattern(forms) -> str:
    """A regex source matching any of `forms` as a whole token before a period."""
    return r"(?<!\w)(" + "|".join(re.escape(a) for a in forms) + r")\."


_ABBREV_RE = re.compile(_abbrev_pattern(_ABBREVS))

# Lowercase abbreviation forms, protected ONLY on the lowercase-follower branch
# (#389) -- applied *after* the uppercase branch has already run (see
# split_sentences). This is the fix for a cross-branch leak caught over three
# review rounds: the disambiguator for a lowercase unit abbreviation is the
# follower's case. `It took 300 ms. The next run ...` (uppercase follower) is a
# genuine sentence boundary and must still split, so this protection must not
# reach the uppercase branch; but `set it to 3 sec. then wait` (lowercase
# follower) is mid-sentence and must not split. Scoping the lowercase forms to
# the lowercase branch is exactly that distinction. `no` is excluded (a
# lowercase `no.` is the English word and should split on either branch), and
# `min`/`hr`/`hrs` are added because bare time units are common in this repo's
# timeout/duration prose and would otherwise false-split before a lowercase
# word. The list is curated, not exhaustive: since the lowercase branch's
# lookbehind only inspects the two trailing characters, ANY unlisted
# abbreviation ending in two lowercase letters -- regardless of its overall case
# (`Inc.`, `Prof.`, `Mon.`, `Jan.`) -- can still false-split before a lowercase
# word, which is a disclosed limitation.
_ABBREV_LOWER = {a.lower() for a in _ABBREVS if a != "No"} | {
    "min", "hr", "hrs", "etc", "al", "approx", "ibid", "op"
}
_ABBREV_LOWER_RE = re.compile(
    _abbrev_pattern(sorted(_ABBREV_LOWER, key=len, reverse=True))
)

_PROPER_NOUN_FOLLOWERS = {
    "Supreme", "Department", "Dept", "Senate", "Congress", "Government", "Govt",
    "District", "Court", "Courts", "Navy", "Army", "Air", "Coast", "Postal",
    "Border", "Customs", "Marshal", "Marshals", "Attorney", "Attorneys",
    "President", "Secretary", "Bank", "Dollar", "Dollars", "News", "Route",
    "Highway", "Virgin", "Circuit", "Mayor", "Parliament", "Prime",
    "Food", "Trade", "Securities", "Internal", "National", "Public",
    "First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth", "Tenth", "Eleventh", "Twelfth",
    "Constitution", "Law", "Laws", "Code", "Treaty", "Flag", "Embassy", "Consulate",
    "Capitol", "Treasury", "Commerce", "Labor", "Energy", "Education", "Veterans",
    "Homeland", "Agriculture", "Transportation", "Interior", "Defense", "State",
    "Health", "Human", "Housing", "Urban", "Justice", "Geological",
}
_INITIALISM_FOLLOW_RE = re.compile(
    r"(?P<det>\b(?:[Tt]he|[Aa]n?|[Ii]ts|[Oo]ur|[Tt]heir|[Hh]is|[Hh]er|[Tt]his|[Tt]hat)\s+)?(?P<init>(?:[A-Za-z]\.){2,})\s+(?P<follower>[A-Za-z]+)"
)
_INITIALISM_RE = re.compile(r"\b(?:[A-Za-z]\.){2,}")

_COMMON_NOUN_FOLLOWERS = {
    "economy", "market", "markets", "history", "population", "policy", "policies",
    "citizens", "government", "military", "dollars", "dollar", "laws", "law",
    "border", "borders", "infrastructure", "system", "systems", "patents",
    "forces", "courts", "court", "firms", "companies", "data", "standard", "standards",
    "census", "postal", "customs", "territory", "territories", "soil", "citizenship",
    "passport", "passports", "currency", "embassy", "embassies", "consulate",
}

# Sentence boundary: [.!?] + optional closing chars + whitespace + uppercase/digit/quote.
# The closing-char class includes `*` and `_` so a sentence ending in Markdown
# emphasis (`**Some claim.** Explanation...`, or the `__claim.__` / `_claim._`
# underscore forms) is recognized: the emphasis close sits between the period
# and the whitespace and would otherwise defeat the boundary. A lowercase word
# after the close still blocks this branch's split via the uppercase-or-markup
# lookahead, so mid-sentence emphasis is left intact.
_SENT_BREAK_RE = re.compile(r"([.!?][`\"')\]*_]*)\s+(?=[A-Z0-9\"'`*\[])")

# Lowercase-follower boundary (#389). Our prose routinely opens a sentence with
# a bare lowercase package or repo name (`renv`, `serodynamics`, `dplyr`), which
# the uppercase-or-markup lookahead above refuses -- so the check was silent on
# exactly the multi-sentence lines we most often write. This branch accepts a
# following lowercase letter.
#
# Two structural guards keep it from over-splitting:
#
#   1. The `(?<=[a-z][a-z])` lookbehind requires two lowercase letters
#      immediately before the terminal punctuation. It is the guard that refuses
#      a single-letter initial (`U.S.`, the `.` follows `S`), a dotted
#      abbreviation (`a.m.`, the `.` follows `.m`), a single-letter token
#      (`option a.`), a digit- or version-ending token (`plan9.`; and `v2.1.` at
#      a clause end, where the `.` DOES have a following space so only the
#      lookbehind blocks it), AND an ellipsis (`wait... foo`): the only dot with
#      a following space is the third, and the two characters before it are both
#      dots, so the lookbehind fails there. Dotted initialisms (`(?<=[A-Za-z][.\x00][A-Za-z])`)
#      are accepted when ending a sentence before a lowercase sentence starter.
#   2. The terminal `[.!?]` must be *immediately* followed by whitespace -- there
#      is no closing-character class here (unlike the uppercase branch). A
#      character wedged between the punctuation and the space blocks the split,
#      which is what keeps mid-sentence emphasis (`**critical.** yet`) and a
#      quoted or parenthesized fragment (`he said "stop." then`) on one line.
_SENT_BREAK_LOWER_RE = re.compile(
    r"(?:(?<=[a-z][a-z])|(?<=[A-Za-z][.\x00][A-Za-z]))([.!?])\s+(?=[a-z])"
)

_CODE_SPAN_RE = re.compile(r"(`+)(?:(?!\1)[\s\S])*?\1")
_LINK_TARGET_RE = re.compile(
    r"\]\(\s*(?:<[^>]*>|(?:[^()\s\\]|\([^()\s\\]*\)|\\.)*)"
    r"(?:\s+(?:"
    r'"(?:[^"\\]|\\.)*"'
    r"|'(?:[^'\\]|\\.)*'"
    r"|\((?:[^()\\]|\\.)*\)"
    r"))?\s*\)"
)
_REF_DEF_RE = re.compile(
    r"^\s{0,3}\[(?:[^\[\]\\]|\\.)+\]:\s*"
    r"(?:<[^\s>]*>|\S+)"
    r"(?:\s+(?:\"(?:[^\"]|\\.)*\"|'(?:[^']|\\.)*'|\((?:[^()]|\\.)*\)))?\s*$"
)
_REF_DEF_WITH_TITLE_RE = re.compile(
    r"^\s{0,3}\[(?:[^\[\]\\]|\\.)+\]:\s*"
    r"(?:<[^>]*>|\S+)"
    r"\s+"
    r"(?:\"(?:[^\"]|\\.)*\"|'(?:[^']|\\.)*'|\((?:[^()]|\\.)*\))\s*$"
)
_REF_TITLE_ONLY_RE = re.compile(
    r"^\s*(?:\"(?:[^\"]|\\.)*\"|'(?:[^']|\\.)*'|\((?:[^()]|\\.)*\))\s*$"
)
_AUTOLINK_RE = re.compile(r"<https?://[^>\s]*>")
_BARE_URL_RE = re.compile(r"https?://\S*[^\s.,;:!?)\]]")
_ENTITY_RE = re.compile(
    r"&(?:[A-Za-z][A-Za-z0-9]{1,31}|#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6});"
)
_INLINE_HTML_TAG_RE = re.compile(
    r"<[A-Za-z][A-Za-z0-9\-]*(?:\s+[A-Za-z_:][A-Za-z0-9_\.:\-]*(?:\s*=\s*(?:[^\s\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*\s*/?>"
    r"|</[A-Za-z][A-Za-z0-9\-]+\s*>"
    r"|<\?[\s\S]*?\?>"
    r"|<![A-Z][\s\S]*?>"
    r"|<!\[CDATA\[[\s\S]*?\]\]>"
)

# Defaults
_DEFAULT_FAIL = True
_DEFAULT_CLAUSE_BREAKS = True
_DEFAULT_CLAUSE_MIN_LENGTH = 80

_PLACEHOLDER = "\x00"


def _protect_inline_code(m: "re.Match[str]") -> str:
    """Replace sentence-ending punctuation inside backtick spans with placeholders."""
    return m.group(0).replace(".", _PLACEHOLDER).replace("!", "\x01").replace("?", "\x02")


def _protect_inline_html_tags(text: str) -> str:
    """Protect punctuation inside inline HTML tags and attributes."""
    def _repl(m: "re.Match[str]") -> str:
        return (
            m.group(0)
            .replace(".", _PLACEHOLDER)
            .replace("!", "\x01")
            .replace("?", "\x02")
            .replace(";", "\x03")
        )

    return _INLINE_HTML_TAG_RE.sub(_repl, text)


def find_link_targets(text: str) -> List[Tuple[int, int]]:
    """Find all (start_idx, end_idx) of ](...) link targets with nested balanced parens."""
    targets = []
    i = 0
    n = len(text)
    while i < n - 1:
        if text[i:i+2] == "](":
            start = i
            idx = i + 2
            while idx < n and text[idx] in (" ", "\t", "\n"):
                idx += 1
            depth = 1
            in_quote: Optional[str] = None
            in_angle = False
            if idx < n and text[idx] == "<":
                in_angle = True
                idx += 1
            while idx < n and depth > 0:
                ch = text[idx]
                if ch == "\\" and idx + 1 < n:
                    idx += 2
                    continue
                if in_angle:
                    if ch == ">":
                        in_angle = False
                elif in_quote:
                    if ch == in_quote:
                        in_quote = None
                else:
                    if ch in ('"', "'"):
                        in_quote = ch
                    elif ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                idx += 1
            if depth == 0:
                targets.append((start, idx))
                i = idx
                continue
        i += 1
    return targets


def _protect_link_targets(text: str) -> str:
    """Protect punctuation inside Markdown link destinations and optional titles."""
    targets = find_link_targets(text)
    if not targets:
        return text
    result = []
    last = 0
    for start, end in targets:
        result.append(text[last:start])
        target_str = text[start:end]
        prot = target_str.replace(".", _PLACEHOLDER).replace("!", "\x01").replace("?", "\x02").replace(";", "\x03")
        result.append(prot)
        last = end
    result.append(text[last:])
    return "".join(result)


def strip_link_targets(text: str) -> str:
    """Strip Markdown link targets ](...), leaving the leading ]."""
    targets = find_link_targets(text)
    if not targets:
        return text
    result = []
    last = 0
    for start, end in targets:
        result.append(text[last:start])
        result.append("]")
        last = end
    result.append(text[last:])
    return "".join(result)


def _protect_initialisms(text: str) -> str:
    """Protect internal dots in initialisms and contextual proper noun followers."""
    def _replace_follower(m: "re.Match[str]") -> str:
        det = m.group("det") or ""
        init = m.group("init")
        follower = m.group("follower")
        if follower[0].isupper():
            if follower in _PROPER_NOUN_FOLLOWERS:
                return det + init.replace(".", _PLACEHOLDER) + " " + follower
            return det + init[:-1].replace(".", _PLACEHOLDER) + init[-1] + " " + follower
        else:
            if det and follower in _COMMON_NOUN_FOLLOWERS:
                return det + init.replace(".", _PLACEHOLDER) + " " + follower
            return det + init[:-1].replace(".", _PLACEHOLDER) + init[-1] + " " + follower

    text = _INITIALISM_FOLLOW_RE.sub(_replace_follower, text)

    def _replace_internal(m: "re.Match[str]") -> str:
        val = m.group(0)
        return val[:-1].replace(".", _PLACEHOLDER) + val[-1]

    return _INITIALISM_RE.sub(_replace_internal, text)


def split_sentences(text: str) -> List[str]:
    """Split text at sentence boundaries; return the list of sentences."""
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return []
    protected = _ABBREV_RE.sub(lambda m: m.group(1) + _PLACEHOLDER, text)
    protected = _protect_initialisms(protected)
    protected = _protect_link_targets(protected)
    protected = _CODE_SPAN_RE.sub(_protect_inline_code, protected)
    protected = _protect_inline_html_tags(protected)
    protected = _SENT_BREAK_RE.sub(lambda m: m.group(1) + "\n", protected)
    # Protect lowercase abbreviation forms only now, after the uppercase branch
    # has run, so they suppress the lowercase branch below without stopping the
    # uppercase branch from splitting a genuine `... ms. The next ...` boundary.
    protected = _ABBREV_LOWER_RE.sub(lambda m: m.group(1) + _PLACEHOLDER, protected)
    protected = _SENT_BREAK_LOWER_RE.sub(lambda m: m.group(1) + "\n", protected)
    parts = [
        p.replace(_PLACEHOLDER, ".").replace("\x01", "!").replace("\x02", "?").replace("\x03", ";").strip()
        for p in protected.split("\n")
    ]
    return [p for p in parts if p]


# ── Clause breaks (on by default; SemBr rule 5) ─────────────────────────────


def strip_inline_markup(text: str) -> str:
    """Drop non-prose markup, leaving the prose around it.

    Removes inline code spans, link targets, autolinks, bare URLs, and HTML
    character entities -- every construct that can carry a ``;`` that is not a
    clause boundary, or inflate a line's length without adding visible text.
    """
    text = _CODE_SPAN_RE.sub("", text)
    text = strip_link_targets(text)
    text = re.sub(r"<!--.*?-->", "", text)
    text = re.sub(r"^.*?-->", "", text)
    text = _INLINE_HTML_TAG_RE.sub("", text)
    for pattern in (_AUTOLINK_RE, _BARE_URL_RE, _ENTITY_RE):
        text = pattern.sub("", text)
    return text


def has_late_semicolon(text: str, min_length: int = _DEFAULT_CLAUSE_MIN_LENGTH) -> bool:
    """True when ``text`` is long enough and carries a mid-line semicolon.

    Proxy for SemBr rule 5 (break after independent clause). Semicolon is used
    because its unparsed hit rate is low enough to be useful (unlike commas).
    """
    stripped = strip_inline_markup(text).strip()
    if len(stripped) < min_length:
        return False
    semicolon = stripped.find(";", 1)
    return 0 < semicolon < len(stripped) - 1


def classify_line(
    content: str,
    clause_breaks: bool = _DEFAULT_CLAUSE_BREAKS,
    clause_min_length: int = _DEFAULT_CLAUSE_MIN_LENGTH,
) -> Optional[str]:
    """Return the reason ``content`` is flagged, or None when it is clean.

    Rule 4 (the MUST) is checked first, so a line that breaks both rules is
    reported once, against the stronger one.
    """
    if len(split_sentences(content)) > 1:
        return "sentence"
    if clause_breaks and has_late_semicolon(content, clause_min_length):
        return "clause"
    return None


# ── Block detectors ─────────────────────────────────────────────────────────

_BULLET_RE = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)", re.DOTALL)
_HEADING_RE = re.compile(r"^ {0,3}#{1,6}(?:\s|$)")
_HR_RE = re.compile(
    r"^\s{0,3}(?:"
    r"-(?:[ \t]*-){2,}"
    r"|_(?:[ \t]*_){2,}"
    r"|\*(?:[ \t]*\*){2,}"
    r")[ \t]*$"
)
_FENCE_RE = re.compile(r"^( {0,3})(`{3,}|~{3,})")
_FENCE_CLOSE_RE = re.compile(r"^( {0,3})(`{3,}|~{3,})\s*$")
_BQ_RE = re.compile(r"^\s*>")
_BLANK_RE = re.compile(r"^\s*$")
_HTML_COMMENT_RE = re.compile(r"^\s*<!--")

_HTML_TYPE1_TAGS = r"script|pre|style|textarea"
_HTML_TYPE6_TAGS = (
    r"address|article|aside|base|basefont|blockquote|body|caption|center|"
    r"col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|"
    r"figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|"
    r"hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|"
    r"optgroup|option|p|param|section|source|summary|table|tbody|td|"
    r"tfoot|th|thead|title|tr|track|ul"
)

_HTML_BLOCK_START_TYPE1_RE = re.compile(
    rf"^\s{{0,3}}<(?:{_HTML_TYPE1_TAGS})(?:\s|>|$)", re.IGNORECASE
)
_HTML_BLOCK_START_TYPE3_RE = re.compile(r"^\s{0,3}<\?")
_HTML_BLOCK_START_TYPE4_RE = re.compile(r"^\s{0,3}<![A-Z]")
_HTML_BLOCK_START_TYPE5_RE = re.compile(r"^\s{0,3}<!\[CDATA\[")
_HTML_BLOCK_START_TYPE6_RE = re.compile(
    rf"^\s{{0,3}}</?(?:{_HTML_TYPE6_TAGS})(?:\s|>|/>|$)", re.IGNORECASE
)
_HTML_BLOCK_START_TYPE7_RE = re.compile(
    r"^\s{0,3}(?:"
    r"<[A-Za-z][A-Za-z0-9\-]*(?:\s+[A-Za-z_:][A-Za-z0-9_\.:\-]*(?:\s*=\s*(?:[^\s\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*\s*/?>"
    r"|</[A-Za-z][A-Za-z0-9\-]+\s*>"
    r")\s*$"
)
_INDENTED_CODE_RE = re.compile(r"^(?: {4}|\t)")
_TABLE_DELIM_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(?:\|\s*:?-{1,}:?\s*)+\|?\s*$")
_SETEXT_UNDERLINE_RE = re.compile(r"^ {0,3}(?:=+|-+)\s*$")
_FENCE_ANY_RE = re.compile(r"^(\s*)(`{3,}|~{3,})(.*)$")
_FENCE_CLOSE_ANY_RE = re.compile(r"^(\s*)(`{3,}|~{3,})\s*$")


def _find_heading_and_table_lines(lines: List[str]) -> Set[int]:
    """Identify 1-indexed line numbers of all headings and table rows."""
    excluded: Set[int] = set()
    n = len(lines)
    for idx, line in enumerate(lines, start=1):
        clean = re.sub(r"^(\s*>)+\s?", "", line).rstrip("\r\n")
        stripped = clean.strip()
        if _HEADING_RE.match(clean):
            excluded.add(idx)
        elif _SETEXT_UNDERLINE_RE.match(clean) and idx > 1:
            prev = re.sub(r"^(\s*>)+\s?", "", lines[idx - 2]).strip()
            if prev and not _HR_RE.match(prev) and not _TABLE_DELIM_RE.match(prev):
                excluded.add(idx)
                excluded.add(idx - 1)
        if _TABLE_DELIM_RE.match(stripped):
            excluded.add(idx)
            if idx > 1:
                prev = re.sub(r"^(\s*>)+\s?", "", lines[idx - 2]).strip()
                if prev and "|" in prev:
                    excluded.add(idx - 1)
            j = idx + 1
            while j <= n:
                nxt = re.sub(r"^(\s*>)+\s?", "", lines[j - 1]).strip()
                if not nxt or "|" not in nxt:
                    break
                excluded.add(j)
                j += 1
    return excluded


def prose_line_numbers(text_or_lines: Union[str, List[str]]) -> Set[int]:
    """Return the set of 1-based line numbers in `lines` that contain prose."""
    lines = text_or_lines.split("\n") if isinstance(text_or_lines, str) else text_or_lines
    excluded_structural = _find_heading_and_table_lines(lines)
    prose: Set[int] = set()
    has_frontmatter = False
    if lines and lines[0].strip() == "---":
        for l in lines[1:]:
            if l.strip() == "---":
                has_frontmatter = True
                break

    in_frontmatter = False
    frontmatter_done = False
    in_code = False
    fence_len = 0
    fence_char: Optional[str] = None
    fence_max_close_indent = 3
    in_html_comment = False
    html_block_kind: Optional[str] = None
    html_block_param: Optional[str] = None
    in_bq_code = False
    bq_fence_len = 0
    bq_fence_char: Optional[str] = None
    bq_fence_max_close_indent = 3
    in_bq_html_comment = False
    bq_html_block_kind: Optional[str] = None
    bq_html_block_param: Optional[str] = None
    bq_last_was_blank = False
    in_bq_indented_code = False
    bq_in_list = False
    bq_list_indent = 0
    bq_in_paragraph = False
    in_bq_ref_def = False
    in_list = False
    list_indent = 0
    in_indented_code = False
    last_was_blank = False
    in_paragraph = False
    in_ref_def = False

    for idx, line in enumerate(lines, start=1):
        stripped = line.strip()

        if has_frontmatter and not frontmatter_done and not in_frontmatter and idx == 1 and stripped == "---":
            in_frontmatter = True
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_paragraph = False
            in_ref_def = False
            continue
        if in_frontmatter:
            if stripped == "---":
                in_frontmatter = False
                frontmatter_done = True
            continue

        if _REF_DEF_RE.match(line):
            in_paragraph = False
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_ref_def = not bool(_REF_DEF_WITH_TITLE_RE.match(line))
            continue

        if in_ref_def:
            if _REF_TITLE_ONLY_RE.match(line):
                in_ref_def = False
                in_paragraph = False
                in_list = False
                in_indented_code = False
                last_was_blank = False
                continue
            in_ref_def = False

        if in_code:
            close_m = _FENCE_CLOSE_ANY_RE.match(line)
            if close_m:
                lead_len = len(close_m.group(1).replace("\t", "    "))
                if lead_len <= fence_max_close_indent:
                    fence_str = close_m.group(2)
                    fl, fc = len(fence_str), fence_str[0]
                    if fc == fence_char and fl >= fence_len:
                        in_code, fence_len, fence_char, fence_max_close_indent = False, 0, None, 3
            continue

        fence_m = _FENCE_ANY_RE.match(line)
        if fence_m:
            lead_len = len(fence_m.group(1).replace("\t", "    "))
            max_allowed = (list_indent + 3) if in_list else 3
            if lead_len <= max_allowed:
                fence_str = fence_m.group(2)
                fl, fc = len(fence_str), fence_str[0]
                info_string = fence_m.group(3)
                if not (fc == "`" and "`" in info_string):
                    in_code, fence_len, fence_char = True, fl, fc
                    fence_max_close_indent = max_allowed
                    in_list = False
                    in_indented_code = False
                    last_was_blank = False
                    in_paragraph = False
                    continue

        if html_block_kind is not None:
            if html_block_kind == "type1":
                if re.search(rf"</{html_block_param}>", line, re.IGNORECASE):
                    html_block_kind, html_block_param = None, None
            elif html_block_kind == "type3":
                if "?>" in line:
                    html_block_kind, html_block_param = None, None
            elif html_block_kind == "type4":
                if ">" in line:
                    html_block_kind, html_block_param = None, None
            elif html_block_kind == "type5":
                if "]]>" in line:
                    html_block_kind, html_block_param = None, None
            elif html_block_kind in ("type6", "type7"):
                if _BLANK_RE.match(line):
                    html_block_kind, html_block_param = None, None
                    last_was_blank = True
            in_paragraph = False
            continue

        if _HTML_BLOCK_START_TYPE1_RE.match(line):
            tag_m = re.search(r"<(script|pre|style|textarea)", line, re.IGNORECASE)
            tag = tag_m.group(1).lower() if tag_m else "script"
            if not re.search(rf"</{tag}>", line, re.IGNORECASE):
                html_block_kind, html_block_param = "type1", tag
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_paragraph = False
            continue

        if _HTML_BLOCK_START_TYPE3_RE.match(line):
            if "?>" not in line:
                html_block_kind = "type3"
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_paragraph = False
            continue

        if _HTML_BLOCK_START_TYPE4_RE.match(line):
            if ">" not in line:
                html_block_kind = "type4"
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_paragraph = False
            continue

        if _HTML_BLOCK_START_TYPE5_RE.match(line):
            if "]]>" not in line:
                html_block_kind = "type5"
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_paragraph = False
            continue

        if _HTML_BLOCK_START_TYPE6_RE.match(line):
            html_block_kind = "type6"
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_paragraph = False
            continue

        if not in_paragraph and _HTML_BLOCK_START_TYPE7_RE.match(line):
            html_block_kind = "type7"
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_paragraph = False
            continue

        if idx in excluded_structural:
            in_indented_code = False
            in_paragraph = False
            if _BLANK_RE.match(line):
                last_was_blank = True
            else:
                last_was_blank = False
            continue

        if _BQ_RE.match(line):
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_paragraph = False
            inner = re.sub(r"^(\s*>)+\s?", "", line)
            if in_bq_code:
                bq_close_m = _FENCE_CLOSE_ANY_RE.match(inner)
                if bq_close_m:
                    lead_len = len(bq_close_m.group(1).replace("\t", "    "))
                    if lead_len <= bq_fence_max_close_indent:
                        fence_str = bq_close_m.group(2)
                        fl, fc = len(fence_str), fence_str[0]
                        if fc == bq_fence_char and fl >= bq_fence_len:
                            in_bq_code, bq_fence_len, bq_fence_char, bq_fence_max_close_indent = False, 0, None, 3
                continue

            bq_fence_m = _FENCE_ANY_RE.match(inner)
            if bq_fence_m:
                lead_len = len(bq_fence_m.group(1).replace("\t", "    "))
                max_allowed = (bq_list_indent + 3) if bq_in_list else 3
                if lead_len <= max_allowed:
                    fence_str = bq_fence_m.group(2)
                    fl, fc = len(fence_str), fence_str[0]
                    info_string = bq_fence_m.group(3)
                    if not (fc == "`" and "`" in info_string):
                        in_bq_code, bq_fence_len, bq_fence_char = True, fl, fc
                        bq_fence_max_close_indent = max_allowed
                        bq_in_list = False
                        bq_last_was_blank = False
                        in_bq_indented_code = False
                        bq_in_paragraph = False
                        continue

            if bq_html_block_kind is not None:
                if bq_html_block_kind == "type1":
                    if re.search(rf"</{bq_html_block_param}>", inner, re.IGNORECASE):
                        bq_html_block_kind, bq_html_block_param = None, None
                elif bq_html_block_kind == "type3":
                    if "?>" in inner:
                        bq_html_block_kind, bq_html_block_param = None, None
                elif bq_html_block_kind == "type4":
                    if ">" in inner:
                        bq_html_block_kind, bq_html_block_param = None, None
                elif bq_html_block_kind == "type5":
                    if "]]>" in inner:
                        bq_html_block_kind, bq_html_block_param = None, None
                elif bq_html_block_kind in ("type6", "type7"):
                    if _BLANK_RE.match(inner):
                        bq_html_block_kind, bq_html_block_param = None, None
                        bq_last_was_blank = True
                bq_in_paragraph = False
                continue

            if _HTML_BLOCK_START_TYPE1_RE.match(inner):
                tag_m = re.search(r"<(script|pre|style|textarea)", inner, re.IGNORECASE)
                tag = tag_m.group(1).lower() if tag_m else "script"
                if not re.search(rf"</{tag}>", inner, re.IGNORECASE):
                    bq_html_block_kind, bq_html_block_param = "type1", tag
                bq_in_list = False
                bq_last_was_blank = False
                in_bq_indented_code = False
                bq_in_paragraph = False
                continue

            if _HTML_BLOCK_START_TYPE3_RE.match(inner):
                if "?>" not in inner:
                    bq_html_block_kind = "type3"
                bq_in_list = False
                bq_last_was_blank = False
                in_bq_indented_code = False
                bq_in_paragraph = False
                continue

            if _HTML_BLOCK_START_TYPE4_RE.match(inner):
                if ">" not in inner:
                    bq_html_block_kind = "type4"
                bq_in_list = False
                bq_last_was_blank = False
                in_bq_indented_code = False
                bq_in_paragraph = False
                continue

            if _HTML_BLOCK_START_TYPE5_RE.match(inner):
                if "]]>" not in inner:
                    bq_html_block_kind = "type5"
                bq_in_list = False
                bq_last_was_blank = False
                in_bq_indented_code = False
                bq_in_paragraph = False
                continue

            if _HTML_BLOCK_START_TYPE6_RE.match(inner):
                bq_html_block_kind = "type6"
                bq_in_list = False
                bq_last_was_blank = False
                in_bq_indented_code = False
                bq_in_paragraph = False
                continue

            if not bq_in_paragraph and _HTML_BLOCK_START_TYPE7_RE.match(inner):
                bq_html_block_kind = "type7"
                bq_in_list = False
                bq_last_was_blank = False
                in_bq_indented_code = False
                bq_in_paragraph = False
                continue

            if in_bq_html_comment:
                if "-->" in inner:
                    in_bq_html_comment = False
                    suffix = inner.split("-->", 1)[1]
                    suffix = re.sub(r"<!--.*?-->", "", suffix)
                    if "<!--" in suffix and "-->" not in suffix:
                        in_bq_html_comment = True
                        visible_prefix = suffix.split("<!--", 1)[0]
                        if visible_prefix.strip():
                            bq_in_paragraph = True
                            prose.add(idx)
                        else:
                            bq_in_paragraph = False
                    elif suffix.strip():
                        bq_in_paragraph = True
                        prose.add(idx)
                    else:
                        bq_in_paragraph = False
                continue

            if "<!--" in inner:
                rem = re.sub(r"<!--.*?-->", "", inner)
                if "<!--" in rem and "-->" not in rem:
                    in_bq_html_comment = True
                    visible_prefix = rem.split("<!--", 1)[0]
                    if visible_prefix.strip():
                        bq_in_paragraph = True
                        prose.add(idx)
                    else:
                        bq_in_paragraph = False
                    bq_in_list = False
                    in_bq_indented_code = False
                    continue

            if _REF_DEF_RE.match(inner):
                bq_in_paragraph = False
                bq_in_list = False
                in_bq_indented_code = False
                bq_last_was_blank = False
                in_bq_ref_def = not bool(_REF_DEF_WITH_TITLE_RE.match(inner))
                continue

            if in_bq_ref_def:
                if _REF_TITLE_ONLY_RE.match(inner):
                    in_bq_ref_def = False
                    bq_in_paragraph = False
                    bq_in_list = False
                    in_bq_indented_code = False
                    bq_last_was_blank = False
                    continue
                in_bq_ref_def = False

            if _BLANK_RE.match(inner):
                bq_last_was_blank = True
                in_bq_indented_code = False
                bq_in_paragraph = False
                continue

            if _HR_RE.match(inner.strip()) or _HEADING_RE.match(inner):
                bq_in_list = False
                bq_last_was_blank = False
                in_bq_indented_code = False
                bq_in_paragraph = False
                continue

            bq_bullet_m = _BULLET_RE.match(inner)
            if bq_bullet_m:
                bq_in_list = True
                bq_lead_len = len(bq_bullet_m.group(1).replace("\t", "    "))
                bq_marker_len = len(bq_bullet_m.group(2)) + 1
                bq_list_indent = bq_lead_len + bq_marker_len
                bq_last_was_blank = False
                in_bq_indented_code = False
                bq_in_paragraph = True
                prose.add(idx)
                continue

            if _INDENTED_CODE_RE.match(inner):
                if not bq_in_paragraph or in_bq_indented_code:
                    in_bq_indented_code = True
                    bq_last_was_blank = False
                    continue
                in_bq_indented_code = False
                bq_last_was_blank = False
                prose.add(idx)
                continue

            if bq_in_list:
                inner_lead = len(inner) - len(inner.lstrip(" "))
                if inner_lead < bq_list_indent:
                    bq_in_list = False

            in_bq_indented_code = False
            bq_last_was_blank = False
            bq_in_paragraph = True
            prose.add(idx)
            continue
        # Reset blockquote code fence and paragraph state on non-blockquote lines
        # (well-formed Markdown does not interleave blockquote and non-blockquote lines mid-fence).
        in_bq_code, bq_fence_len, bq_fence_char, bq_fence_max_close_indent = False, 0, None, 3
        in_bq_html_comment = False
        bq_html_block_kind = None
        bq_html_block_param = None
        bq_last_was_blank = False
        in_bq_indented_code = False
        bq_in_list = False
        bq_list_indent = 0
        bq_in_paragraph = False

        if in_html_comment:
            if "-->" in line:
                in_html_comment = False
                suffix = line.split("-->", 1)[1]
                suffix = re.sub(r"<!--.*?-->", "", suffix)
                if "<!--" in suffix and "-->" not in suffix:
                    in_html_comment = True
                    visible_prefix = suffix.split("<!--", 1)[0]
                    if visible_prefix.strip():
                        in_paragraph = True
                        prose.add(idx)
                    else:
                        in_paragraph = False
                elif suffix.strip():
                    in_paragraph = True
                    prose.add(idx)
                else:
                    in_paragraph = False
            continue

        if "<!--" in line:
            rem = re.sub(r"<!--.*?-->", "", line)
            if "<!--" in rem and "-->" not in rem:
                in_html_comment = True
                visible_prefix = rem.split("<!--", 1)[0]
                if visible_prefix.strip():
                    in_paragraph = True
                    prose.add(idx)
                else:
                    in_paragraph = False
                in_list = False
                in_indented_code = False
                continue
            elif _HTML_COMMENT_RE.match(line):
                if rem.strip():
                    in_paragraph = True
                    prose.add(idx)
                else:
                    in_paragraph = False
                in_list = False
                in_indented_code = False
                continue

        if _BLANK_RE.match(line):
            in_indented_code = False
            last_was_blank = True
            in_paragraph = False
            continue

        if _HR_RE.match(stripped):
            in_list = False
            in_indented_code = False
            last_was_blank = False
            in_paragraph = False
            continue

        bullet_m = _BULLET_RE.match(line)
        if bullet_m:
            in_list = True
            list_indent = len(bullet_m.group(1)) + len(bullet_m.group(2)) + 1
            in_indented_code = False
            last_was_blank = False
            in_paragraph = True
            prose.add(idx)
            continue

        # Check for indented code blocks:
        # 1. Outside a list: four spaces or a tab is an indented code block unless interrupting a paragraph.
        #    Without a preceding paragraph, it is an indented code block (e.g. at document start, after heading/HR/blank).
        # 2. Inside a list: an indented line is a code block if it is indented
        #    >= list_indent + 4 spaces, or if it follows a blank line with >= 4 spaces / tab.
        indent_match = re.match(r"^([ \t]+)", line)
        if indent_match:
            indent_str = indent_match.group(1).replace("\t", "    ")
            indent_len = len(indent_str)
            if not in_list:
                if indent_len >= 4:
                    if not in_paragraph or in_indented_code:
                        in_indented_code = True
                        last_was_blank = False
                        continue
                    in_indented_code = False
                    last_was_blank = False
                    prose.add(idx)
                    continue
            else:
                if indent_len >= list_indent + 4 or (last_was_blank and indent_len >= 4):
                    last_was_blank = False
                    continue
                last_was_blank = False
                in_paragraph = True
                prose.add(idx)
                continue

        in_list = False
        in_indented_code = False
        last_was_blank = False
        in_paragraph = True
        prose.add(idx)

    return prose


def line_content(line: str) -> str:
    """Strip a bullet marker or blockquote prefix so the splitter sees plain prose."""
    inner = re.sub(r"^(\s*>)+\s?", "", line) if _BQ_RE.match(line) else line
    inner = re.sub(r"<!--.*?-->", "", inner)
    inner = re.sub(r"^.*?-->", "", inner)
    inner = re.sub(r"<!--.*$", "", inner)
    bullet_m = _BULLET_RE.match(inner)
    if bullet_m:
        return bullet_m.group(3).strip()
    return inner.strip()


# ── Scope resolution ────────────────────────────────────────────────────────

def _run_git(args: List[str]) -> Optional[str]:
    try:
        return subprocess.run(
            ["git", *args], capture_output=True, check=True,
            encoding="utf-8", errors="replace",
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def _glob_to_regex(pat: str) -> "re.Pattern[str]":
    """Translate a path glob to an anchored regex; supports ``**``, ``*``, ``?``."""
    i, n, out = 0, len(pat), []
    while i < n:
        c = pat[i]
        if c == "*":
            if pat[i:i + 2] == "**":
                i += 2
                if pat[i:i + 1] == "/":
                    out.append("(?:.*/)?")
                    i += 1
                else:
                    out.append(".*")
            else:
                out.append("[^/]*")
                i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def _compile_ignores(patterns: List[str]) -> List["re.Pattern[str]"]:
    compiled = []
    for pat in patterns:
        compiled.append(_glob_to_regex(pat))
        if "*" not in pat and "?" not in pat:
            compiled.append(_glob_to_regex(pat.rstrip("/") + "/**"))
    return compiled


def _ignored(rel: str, ignores: List["re.Pattern[str]"]) -> bool:
    return any(r.match(rel) for r in ignores)


_HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def _unquote_git_path(raw_path: str) -> str:
    """Decode a C-quoted Git pathname with octal byte sequences to a string."""
    if not (raw_path.startswith('"') and raw_path.endswith('"')):
        return raw_path
    s = raw_path[1:-1]
    out_bytes = bytearray()
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            nxt = s[i + 1]
            if nxt in "01234567":
                oct_digits = []
                j = i + 1
                while j < n and j < i + 4 and s[j] in "01234567":
                    oct_digits.append(s[j])
                    j += 1
                out_bytes.append(int("".join(oct_digits), 8))
                i = j
                continue
            elif nxt == "n":
                out_bytes.append(ord("\n"))
            elif nxt == "t":
                out_bytes.append(ord("\t"))
            elif nxt == "r":
                out_bytes.append(ord("\r"))
            elif nxt == "b":
                out_bytes.append(ord("\b"))
            elif nxt == "a":
                out_bytes.append(7)
            elif nxt == "v":
                out_bytes.append(11)
            elif nxt == "f":
                out_bytes.append(12)
            elif nxt in ('\\', '"'):
                out_bytes.append(ord(nxt))
            else:
                out_bytes.extend(nxt.encode("utf-8"))
            i += 2
        else:
            out_bytes.extend(c.encode("utf-8"))
            i += 1
    try:
        return out_bytes.decode("utf-8")
    except UnicodeDecodeError:
        return out_bytes.decode("utf-8", errors="replace")


def _added_line_numbers(
    base_ref: str, pathspecs: List[str], ignores: Optional[List["re.Pattern[str]"]] = None
) -> Optional[Tuple[Dict[str, Set[int]], "Counter[str]"]]:
    """Map each modified file to the 1-based line numbers added in that file
    vs the merge-base of base_ref and HEAD, or None if the diff could not be
    computed.
    """
    diff = _run_git([
        "-c", "core.quotePath=false",
        "diff", "--unified=0", "--no-color", f"{base_ref}...HEAD", "--", *pathspecs
    ])
    if diff is None:
        return None
    return _added_line_numbers_from_diff(diff, ignores=ignores)


def _added_line_numbers_from_diff(
    diff: str, ignores: Optional[List["re.Pattern[str]"]] = None
) -> Tuple[Dict[str, Set[int]], "Counter[str]"]:
    """Parse unified diff text and extract added line numbers and deleted lines.

    Deletions from files matching ``ignores`` are not collected, ensuring that
    text deleted from an ignored file cannot serve as a moved-content exemption
    for newly added lines in checked files.
    """
    result: Dict[str, Set[int]] = {}
    deleted: "Counter[str]" = Counter()
    cur_src_path: Optional[str] = None
    cur_path: Optional[str] = None
    new_lineno = 0
    in_hunk = False
    for raw in diff.splitlines():
        if raw.startswith("diff "):
            in_hunk = False
            cur_src_path = None
            cur_path = None
            continue
        if not in_hunk and raw.startswith("--- "):
            target = raw[4:].strip()
            if target == "/dev/null":
                cur_src_path = None
            else:
                unquoted = _unquote_git_path(target)
                cur_src_path = unquoted[2:] if unquoted.startswith("a/") else unquoted
            continue
        if not in_hunk and raw.startswith("+++ "):
            target = raw[4:].strip()
            if target == "/dev/null":
                cur_path = None
            else:
                unquoted = _unquote_git_path(target)
                cur_path = unquoted[2:] if unquoted.startswith("b/") else unquoted
            if cur_path is not None:
                if not (ignores and _ignored(cur_path, ignores)):
                    result.setdefault(cur_path, set())
            continue
        if raw.startswith("@@"):
            in_hunk = True
            m = _HUNK_RE.match(raw)
            new_lineno = int(m.group(1)) if m else 0
            continue
        if not in_hunk:
            continue
        if raw.startswith("\\"):
            # Git diff metadata line (e.g. "\ No newline at end of file")
            continue
        if raw.startswith("-"):
            if cur_src_path is None or not (ignores and _ignored(cur_src_path, ignores)):
                deleted[raw[1:]] += 1
            continue
        if raw.startswith("+"):
            if cur_path is not None and not (ignores and _ignored(cur_path, ignores)):
                result[cur_path].add(new_lineno)
            new_lineno += 1
            continue
        # Context line in a unified diff (only present if --unified=0 is changed).
        # Increment line counter to preserve synchronization.
        new_lineno += 1
    return result, deleted


class Violation(NamedTuple):
    """One flagged line. ``reason`` names which check flagged it."""

    path: str
    line: int
    preview: str
    reason: str


_REASON_MESSAGES = {
    "sentence": "Line packs more than one sentence",
    "clause": "Long line with a mid-line semicolon; consider a break after the clause",
    "unreadable": "Could not read file (invalid encoding or unreadable file)",
}


def find_violations(
    base_ref: str,
    globs: List[str],
    ignores: List["re.Pattern[str]"],
    clause_breaks: bool = _DEFAULT_CLAUSE_BREAKS,
    clause_min_length: int = _DEFAULT_CLAUSE_MIN_LENGTH,
) -> Tuple[List[Violation], bool]:
    """Return (violations, skipped). violations is empty and skipped is True
    whenever there's no diff to check against -- either base_ref was never
    given (e.g. a push run with no PR/MR to diff against), or a base_ref was
    given but the diff could not be computed (e.g. a shallow clone).
    """
    if not base_ref:
        return [], True
    scoped = _added_line_numbers(base_ref, globs, ignores=ignores)
    if scoped is None:
        return [], True
    scope, deleted_contents = scoped
    print(f"Checking for missing semantic line breaks (lines added since {base_ref[:12]})\n")

    violations: List[Violation] = []
    exempted_moves = 0
    for rel_path in sorted(scope):
        if _ignored(rel_path, ignores):
            continue
        path = Path(rel_path)
        if path.is_symlink() or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            print(f"::warning file={rel_path}::Could not read {rel_path} as UTF-8: {exc}", file=sys.stderr)
            violations.append(Violation(rel_path, 1, f"invalid UTF-8 encoding: {exc}", "unreadable"))
            continue
        except OSError as exc:
            print(f"::warning file={rel_path}::Could not read {rel_path}: {exc}", file=sys.stderr)
            violations.append(Violation(rel_path, 1, f"read error: {exc}", "unreadable"))
            continue
        lines = text.split("\n")
        prose = prose_line_numbers(text)
        target_lines = scope[rel_path] & prose

        for line_no in sorted(target_lines):
            if line_no < 1 or line_no > len(lines):
                continue
            raw = lines[line_no - 1]
            content = line_content(raw)
            reason = classify_line(content, clause_breaks, clause_min_length)
            if reason is not None:
                preview = content if len(content) <= 80 else content[:77] + "..."
                if deleted_contents[raw] > 0:
                    deleted_contents[raw] -= 1
                    exempted_moves += 1
                    continue
                violations.append(Violation(rel_path, line_no, preview, reason))
    if exempted_moves:
        print(
            f"Note: {exempted_moves} added line(s) also appear among this "
            "diff's deleted lines (moved, not new) and were not reported."
        )
    return violations, False


def write_codequality_report(violations: List[Violation], report_path: str) -> None:
    """Write a GitLab Code Quality JSON report (array of findings)."""
    report_items = []
    for v in violations:
        msg = _REASON_MESSAGES.get(v.reason, "Line needs a semantic break")
        description = f"{msg}: {v.preview}"
        # Compute deterministic fingerprint
        fp_src = f"{v.path}:{v.line}:{v.reason}:{v.preview}"
        fingerprint = hashlib.sha256(fp_src.encode("utf-8")).hexdigest()
        report_items.append({
            "description": description,
            "check_name": f"semantic-line-breaks/{v.reason}",
            "fingerprint": fingerprint,
            "severity": "minor",
            "location": {
                "path": v.path,
                "lines": {
                    "begin": v.line,
                },
            },
        })
    p = Path(report_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(report_items, indent=2), encoding="utf-8")


# ── Configuration & Main ─────────────────────────────────────────────────

def _split_list(value: str) -> List[str]:
    return [tok.strip() for tok in re.split(r"[,\n]", value or "") if tok.strip()]


def _env_flag(name: str, default: bool) -> bool:
    """Read a boolean env var, falling back to ``default`` when unset/empty."""
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    if raw not in ("true", "false"):
        print(
            f"::warning::{name}={raw!r} is not 'true' or 'false'; "
            f"using default ({default})."
        )
        return default
    return raw == "true"


def _nonnegative_int(value: str) -> int:
    try:
        val = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{value!r} is not an integer")
    if val < 0:
        raise argparse.ArgumentTypeError(f"{value!r} must be non-negative")
    return val


def _env_int(name: str, default: int) -> int:
    """Read an int env var, falling back to ``default`` when unset or invalid."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        print(f"::warning::{name}={raw!r} is not an integer; using {default} instead.")
        return default
    if value < 0:
        print(f"::warning::{name}={raw!r} is negative; using {default} instead.")
        return default
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Diff-scoped check for missing semantic line breaks in Markdown."
    )
    parser.add_argument(
        "--base-ref",
        default=os.environ.get("NLB_BASE_REF", "").strip(),
        help="Git ref/SHA to diff against (e.g. origin/main or $CI_MERGE_REQUEST_DIFF_BASE_SHA).",
    )
    parser.add_argument(
        "--globs",
        default=os.environ.get("NLB_GLOBS", "*.md").strip(),
        help="Space-separated git pathspecs to check (default: '*.md').",
    )
    parser.add_argument(
        "--paths-ignore",
        default=os.environ.get("NLB_PATHS_IGNORE", "").strip(),
        help="Comma- or newline-separated glob patterns to skip.",
    )
    parser.add_argument(
        "--fail",
        dest="fail",
        action="store_true",
        default=None,
        help="Fail (exit 1) if violations are found (default: true).",
    )
    parser.add_argument(
        "--no-fail",
        dest="fail",
        action="store_false",
        help="Do not fail (exit 0) if violations are found.",
    )
    parser.add_argument(
        "--clause-breaks",
        dest="clause_breaks",
        action="store_true",
        default=None,
        help="Also flag long lines with mid-line semicolons (default: true).",
    )
    parser.add_argument(
        "--no-clause-breaks",
        dest="clause_breaks",
        action="store_false",
        help="Skip the clause break check (sentence check only).",
    )
    parser.add_argument(
        "--clause-min-length",
        type=_nonnegative_int,
        default=None,
        help=f"Minimum visible line length for clause check (default: {_DEFAULT_CLAUSE_MIN_LENGTH}).",
    )
    parser.add_argument(
        "--codequality-report",
        default=os.environ.get("NLB_CODEQUALITY_REPORT", "").strip(),
        help="Path to write GitLab Code Quality JSON report.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    base_ref = args.base_ref
    globs = args.globs.split() if args.globs.strip() else ["*.md"]
    ignore = _compile_ignores(_split_list(args.paths_ignore))

    if args.fail is not None:
        fail = args.fail
    else:
        fail = _env_flag("NLB_FAIL", default=_DEFAULT_FAIL)

    if args.clause_breaks is not None:
        clause_breaks = args.clause_breaks
    else:
        clause_breaks = _env_flag("NLB_CLAUSE_BREAKS", default=_DEFAULT_CLAUSE_BREAKS)

    if args.clause_min_length is not None:
        clause_min_length = args.clause_min_length
    else:
        clause_min_length = _env_int("NLB_CLAUSE_MIN_LENGTH", default=_DEFAULT_CLAUSE_MIN_LENGTH)

    codequality_report = args.codequality_report

    # Initialize empty Code Quality artifact if configured
    if codequality_report:
        write_codequality_report([], codequality_report)

    violations, skipped = find_violations(
        base_ref, globs, ignore, clause_breaks, clause_min_length
    )

    if skipped:
        reason = f"could not diff against '{base_ref}'" if base_ref else "no base-ref given"
        print(
            f"Skipping the new-line-breaks check for this run "
            f"({reason}; not falling back to a whole-tree scan, which would "
            f"reflag pre-existing long lines)."
        )
        return 0

    if not violations:
        print("No lines missing semantic breaks.")
        return 0

    if codequality_report:
        write_codequality_report(violations, codequality_report)

    # Output violations
    in_gha = "GITHUB_ACTIONS" in os.environ
    for violation in violations:
        message = _REASON_MESSAGES.get(violation.reason, "Line needs a semantic break")
        if in_gha:
            print(f"::error file={violation.path},line={violation.line}::{message}: {violation.preview}")
        else:
            print(f"{violation.path}:{violation.line}: {message}: {violation.preview}")

    print(
        f"\n{len(violations)} line(s) need a semantic break. "
        f"Consider a semantic-break pass (one clause/sentence per line)."
    )
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
