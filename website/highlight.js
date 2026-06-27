// Tiny self-contained syntax highlighter for Lumen code blocks.
// No dependencies. Highlights <pre><code class="lumen">…</code></pre>.
(function () {
  var KW = new Set([
    "let", "const", "var", "function", "return", "if", "else", "for", "while",
    "do", "switch", "case", "default", "break", "continue", "type", "interface",
    "enum", "class", "new", "this", "import", "from", "export", "try", "catch",
    "finally", "throw", "defer", "test", "true", "false", "null", "undefined",
    "of", "in", "extends", "expect"
  ]);
  var TYPES = new Set([
    "int", "i32", "i64", "number", "float", "f64", "bool", "boolean", "string",
    "void", "Error", "Math", "String", "Array", "console", "fs"
  ]);

  function esc(c) {
    return c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : c;
  }
  function span(cls, text) {
    var out = "";
    for (var i = 0; i < text.length; i++) out += esc(text[i]);
    return '<span class="' + cls + '">' + out + "</span>";
  }

  function highlight(src) {
    var out = "";
    var i = 0, n = src.length;
    function isId(c) { return /[A-Za-z0-9_$]/.test(c); }
    while (i < n) {
      var c = src[i];
      // line comment
      if (c === "/" && src[i + 1] === "/") {
        var j = i; while (j < n && src[j] !== "\n") j++;
        out += span("tok-com", src.slice(i, j)); i = j; continue;
      }
      // block comment
      if (c === "/" && src[i + 1] === "*") {
        var k = i + 2; while (k < n && !(src[k] === "*" && src[k + 1] === "/")) k++;
        k = Math.min(n, k + 2);
        out += span("tok-com", src.slice(i, k)); i = k; continue;
      }
      // strings (" and `)
      if (c === '"' || c === "`") {
        var q = c, m = i + 1;
        while (m < n && src[m] !== q) { if (src[m] === "\\") m++; m++; }
        m = Math.min(n, m + 1);
        out += span("tok-str", src.slice(i, m)); i = m; continue;
      }
      // numbers
      if (/[0-9]/.test(c)) {
        var p = i; while (p < n && /[0-9a-fA-FxXoObB._]/.test(src[p])) p++;
        out += span("tok-num", src.slice(i, p)); i = p; continue;
      }
      // identifiers / keywords / types
      if (isId(c)) {
        var s = i; while (s < n && isId(src[s])) s++;
        var word = src.slice(i, s);
        var after = src[s];
        if (KW.has(word)) out += span("tok-kw", word);
        else if (TYPES.has(word)) out += span("tok-type", word);
        else if (after === "(") out += span("tok-fn", word);
        else out += esc(word).replace(/./g, function (ch) { return ch; });
        i = s; continue;
      }
      out += esc(c); i++;
    }
    return out;
  }

  document.querySelectorAll("pre code.lumen").forEach(function (el) {
    el.innerHTML = highlight(el.textContent);
  });
})();
