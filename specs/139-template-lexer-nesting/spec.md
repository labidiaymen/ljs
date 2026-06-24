# Spec 139 — Template-literal lexing: nested templates, regex & comments in `${…}`

Status: **Done** (Test262 language 95.2%, no regression).

## Problem
`lexTemplate` found the template boundary by a naive `${`/`}` brace count, blind to nested
strings/templates/regex/comments inside a `${ … }` substitution. So a `}` (or backtick) belonging to a
nested construct mis-decremented the outer depth and the lexer mis-located the closing backtick:
- `` `${ `\${x}` }` `` → the nested template's `}` closed the outer substitution early → SyntaxError.
- `` `"${str.replace(/"/g, '\\"')}"` `` → the `"` inside the regex `/"/g` looked like a string start.

Found by running **webpack** (`RuntimeTemplate.js` builds code with nested templates; `FileSystemInfo.js`
has the regex-in-interpolation form).

## Governing spec
§12.9.6 Template Literal Lexical Components — a `TemplateSubstitutionTail` body is balanced Expression
text; its nested StringLiterals / TemplateLiterals / RegularExpressionLiterals / comments are opaque to
the enclosing template's structure.

## Change
Rewrote `lexTemplate` to delegate each `${ … }` to `skipTemplateSubst`, which scans balanced to the
matching `}` while skipping, as opaque units: nested strings (`skipNestedString`), nested templates
(`skipNestedTemplate`, mutually recursive — handles arbitrary nesting), line/block comments, and RegExp
literals (regex-vs-division via the previous significant char; `[…]` class + `\` escapes handled).

## Success criteria — met
- `` `${ `\${x}` }` `` → `${x}`; the webpack codegen template `` `\`${a.map(x=>`\${${x.expr}}`)…}\`` ``
  evaluates like Node.
- Regex-in-interpolation still parses (no regression to spec 138's parser-level fix).
- webpack parses **FileSystemInfo.js + RuntimeTemplate.js** (was the first two blockers); next blocker is
  `\p{…}` Unicode-property regex → see **spec 140**.
- Test262 `language`: no regression.

## Out of scope
- `\p{…}` Unicode-property regex (the next webpack/yargs blocker) — **spec 140**.
