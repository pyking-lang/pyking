// Ace syntax mode for Pyking.
//
// Loaded by tools/webrun/assets/web.js. The keyword and builtin lists
// below are read out of the compiler at page load (`globalThis.pykingWords`,
// set from PykingRuntime.words()), so they cannot drift from the language
// the way a hand-maintained copy would.
//
// Indentation follows PYKING.md: exact 4-space steps, one level deeper after
// a line that opens a block and leaves it empty -- a line *ending* in `:`,
// or a binding whose value is missing from the line (`x =`, the value
// form). A header carrying its block on its own line (`def f(a): a + 1`)
// opens nothing for the next line, and so is not one of these.

ace.define("ace/mode/pyking_highlight_rules", [], function (require, exports) {
  "use strict";
  var oop = require("../lib/oop");
  var TextHighlightRules =
    require("./text_highlight_rules").TextHighlightRules;

  var words = globalThis.pykingWords || {};
  var keywords = (words.keywords || []).join("|");
  var types = (words.types || []).join("|");
  var constants = (words.constants || []).join("|");
  var builtins = (words.builtins || []).join("|");

  var PykingHighlightRules = function () {
    var keywordMapper = this.createKeywordMapper({
      "keyword": keywords,
      "storage.type": types,
      "constant.language": constants,
      "support.function": builtins
    }, "identifier");

    this.$rules = {
      start: [
        { token: "comment", regex: "#.*$" },
        // Strings: both quote forms, with the backslash escapes scan_string
        // decodes. An unterminated literal is a string to the end of its
        // line rather than swallowing the rest of the file.
        { token: "string", regex: "'(?:[^'\\\\]|\\\\.)*'" },
        { token: "string", regex: '"(?:[^"\\\\]|\\\\.)*"' },
        { token: "string", regex: "['\"].*$" },
        { token: "constant.numeric", regex: "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d+(?:\\.\\d+)?)\\b" },
        // `def name` -- colour the name being defined, not just the keyword.
        { token: ["keyword", "text", "entity.name.function"],
          regex: "(\\bdef\\b)(\\s+)([A-Za-z_][A-Za-z_0-9]*)" },
        // The two-character operators first: ':=' must not lex as ':' + '=',
        // '<<' must not lex as two '<', and '&&' must not lex as two '&'.
        { token: "keyword.operator", regex: ":=|->|\\.\\.|==|!=|<=|>=|<<|>>|&&|\\|\\||<|>|\\+|-|\\*|/|%|\\^|&|\\||~|!|=" },
        { token: keywordMapper, regex: "\\b[A-Za-z_][A-Za-z_0-9]*\\b" },
        { token: "paren.lparen", regex: "[\\[({]" },
        { token: "paren.rparen", regex: "[\\])}]" },
        { token: "punctuation", regex: "[,:]" },
        { token: "text", regex: "\\s+" }
      ]
    };
    this.normalizeRules();
  };
  oop.inherits(PykingHighlightRules, TextHighlightRules);
  exports.PykingHighlightRules = PykingHighlightRules;
});

ace.define("ace/mode/pyking", [], function (require, exports) {
  "use strict";
  var oop = require("../lib/oop");
  var TextMode = require("./text").Mode;
  var PykingHighlightRules =
    require("./pyking_highlight_rules").PykingHighlightRules;

  // A line opens a block for the *next* line when it ends in ':' (a header
  // with nothing after it) or in '=' with no value after it (the value
  // form, whose body sits on the following lines). A header whose block is
  // written on its own line ends in neither.
  var OPENS_BLOCK = /(:|=)\s*(#.*)?$/;
  // Lines that close one level as you type them.
  var OUTDENT = /^\s*(else|case)\b/;

  var Mode = function () {
    this.HighlightRules = PykingHighlightRules;
    this.lineCommentStart = "#";
    this.$id = "ace/mode/pyking";
  };
  oop.inherits(Mode, TextMode);

  (function () {
    this.getNextLineIndent = function (state, line, tab) {
      var indent = this.$getIndent(line);
      if (OPENS_BLOCK.test(line)) indent += tab;
      return indent;
    };

    this.checkOutdent = function (state, line, input) {
      return input === ":" && OUTDENT.test(line + input);
    };

    this.autoOutdent = function (state, session, row) {
      if (row === 0) return;
      var line = session.getLine(row);
      var indent = this.$getIndent(line);
      var tabSize = session.getTabSize();
      if (indent.length < tabSize) return;
      session.remove(new (require("../range").Range)(
        row, indent.length - tabSize, row, indent.length));
    };
  }).call(Mode.prototype);

  exports.Mode = Mode;
});
