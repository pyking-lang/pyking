// The Pyking language for Monaco: a Monarch tokenizer, the editing rules
// (comments, brackets, indentation) and a light and a dark theme.
//
// Loaded by tools/webrun/assets/web.js (`ensureMonaco`). The keyword and
// builtin lists are the compiler's own, asked of it when the page loads
// (PykingRuntime.words()), so they cannot drift from the language the way
// a hand-maintained copy would. pyking-mode.js is the same for Ace.
//
// Indentation follows PYKING.md as pyking-mode.js does: one level deeper
// after a line that opens a block and leaves it empty -- a line ending in
// `:`, or a binding whose value is missing from the line (`x =`) -- and
// `else` going back one level as it is typed.

/** The language id the editors and the language server client use. */
export const LANGUAGE = "pyking";

/** A line that opens a block for the next one. */
const OPENS_BLOCK = /(:|=)\s*(#.*)?$/;

/** Registers the Pyking language, once, with the compiler's word lists
 *  {keywords, builtins}, and defines the themes `pyking-dark` and
 *  `pyking-light`. Monaco -> {keywords, builtins} -> () */
export function registerPyking(monaco, words) {
  if (monaco.languages.getLanguages().some((l) => l.id === LANGUAGE)) return;
  const all = words.keywords || [];
  const types = all.filter((w) => /^[A-Z]/.test(w));
  const constants = ["true", "false"].filter((w) => all.includes(w));
  const keywords = all.filter((w) => !types.includes(w) && !constants.includes(w));

  monaco.languages.register({ id: LANGUAGE, extensions: [".pyk"], aliases: ["Pyking"] });
  monaco.languages.setMonarchTokensProvider(LANGUAGE, {
    keywords, types, constants, builtins: words.builtins || [],
    tokenizer: {
      root: [
        [/#.*$/, "comment"],
        // Strings: both quote forms, with the backslash escapes the lexer
        // decodes. An unterminated literal is a string to the end of its
        // line rather than swallowing the rest of the file.
        [/'(?:[^'\\]|\\.)*'/, "string"],
        [/"(?:[^"\\]|\\.)*"/, "string"],
        [/['"].*$/, "string.invalid"],
        [/0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d+(?:\.\d+)?/, "number"],
        // `def name` -- the name being defined, not just the keyword.
        [/(def)(\s+)([A-Za-z_][A-Za-z_0-9]*)/, ["keyword", "white", "function"]],
        // The two-character operators first: ':=' must not lex as ':' +
        // '=', '<<' not as two '<', '&&' not as two '&'.
        [/:=|->|\.\.|==|!=|<=|>=|<<|>>|&&|\|\||[<>+\-*/%^&|~!=]/, "operator"],
        [/[A-Za-z_][A-Za-z_0-9]*/, {
          cases: {
            "@keywords": "keyword",
            "@types": "type",
            "@constants": "constant",
            "@builtins": "predefined",
            "@default": "identifier",
          },
        }],
        [/[[\](){}]/, "@brackets"],
        [/[,:.]/, "delimiter"],
        [/\s+/, "white"],
      ],
    },
  });
  const pairs = [
    { open: "(", close: ")" }, { open: "[", close: "]" }, { open: "{", close: "}" },
    { open: '"', close: '"', notIn: ["string", "comment"] },
    { open: "'", close: "'", notIn: ["string", "comment"] },
  ];
  monaco.languages.setLanguageConfiguration(LANGUAGE, {
    comments: { lineComment: "#" },
    brackets: [["(", ")"], ["[", "]"], ["{", "}"]],
    autoClosingPairs: pairs,
    surroundingPairs: pairs,
    indentationRules: {
      increaseIndentPattern: OPENS_BLOCK,
      decreaseIndentPattern: /^\s*else\b/,
    },
    onEnterRules: [{
      beforeText: OPENS_BLOCK,
      action: { indentAction: monaco.languages.IndentAction.Indent },
    }],
  });

  // Tomorrow and Tomorrow Night, the Ace themes the pages used, for
  // every language's tokens: a rule for `keyword` also colours
  // `keyword.python`.
  const rules = (c) => [
    { token: "comment", foreground: c.comment, fontStyle: "italic" },
    { token: "string", foreground: c.string },
    { token: "number", foreground: c.number },
    { token: "constant", foreground: c.number },
    { token: "keyword", foreground: c.keyword },
    { token: "type", foreground: c.type },
    { token: "function", foreground: c.function },
    { token: "predefined", foreground: c.builtin },
    { token: "operator", foreground: c.builtin },
    // What the language server's semantic tokens name (src/lsp.ml).
    { token: "parameter", fontStyle: "italic" },
    { token: "enumMember", foreground: c.number },
    { token: "namespace", foreground: c.type },
    { token: "property", foreground: c.builtin },
    { token: "function.defaultLibrary", foreground: c.builtin },
  ];
  // The context menu (Go to Definition, ...) in both themes: white text
  // on a dark menu, which stays readable whatever the page around it is.
  const menu = {
    "menu.background": "#2d2f31", "menu.foreground": "#ffffff",
    "menu.selectionBackground": "#4271ae", "menu.selectionForeground": "#ffffff",
    "menu.separatorBackground": "#5a5b5c", "menu.border": "#5a5b5c",
  };
  monaco.editor.defineTheme("pyking-dark", {
    base: "vs-dark", inherit: true,
    rules: rules({ comment: "969896", string: "b5bd68", number: "de935f",
                   keyword: "b294bb", type: "f0c674", function: "81a2be",
                   builtin: "8abeb7" }),
    colors: { "editor.background": "#1d1f21", "editor.foreground": "#c5c8c6", ...menu },
  });
  monaco.editor.defineTheme("pyking-light", {
    base: "vs", inherit: true,
    rules: rules({ comment: "8e908c", string: "718c00", number: "f5871f",
                   keyword: "8959a8", type: "c99e00", function: "4271ae",
                   builtin: "3e999f" }),
    colors: { "editor.background": "#ffffff", "editor.foreground": "#4d4d4c", ...menu },
  });
}

/** The Monaco theme a page option names: "dark" or "light", a Monaco
 *  theme's own name, or an Ace theme's (`ace/theme/tomorrow_night`),
 *  which is dark when its name says so. String -> String */
export function themeFor(name = "dark") {
  if (name === "dark" || name === "light") return "pyking-" + name;
  if (name.startsWith("ace/theme/")) {
    return /night|dark/.test(name) ? "pyking-dark" : "pyking-light";
  }
  return name;
}
