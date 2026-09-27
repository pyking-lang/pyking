// Markdown to HTML, for the Pyking notebook. Pure: no DOM, no network, so
// the same module renders in the page and under node in the test suite
// (tests/test_notebook.py).
//
// What it accepts is CommonMark's blocks and inlines, GitHub's extensions
// (tables, task lists, strikethrough, bare links, footnotes, and the
// `> [!NOTE]` callouts), `$`-delimited math, and a front-matter block. The
// full list, and what each renders to, is in tools/notebook/README.md.
//
// A code block is not rendered here beyond a placeholder: a runnable
// Pyking cell becomes `<div class="pkn-cell" data-cell="N">` and every
// other block a `<pre class="pkn-code">`, and the notebook turns them into
// editors. The cell's source travels in `cells`, not in the HTML.
//
// Data structures:
//   Context -- what the block parse collects for the inline pass: link
//     references, footnote definitions, and the running counters.
//   Block nodes -- {type, ...}: heading, paragraph, code, math, quote,
//     callout, list, table, html, rule, footnote.
//
// Functions:
//   renderMarkdown(source, options) -- the whole document.
//   parseInfo(info) -- a fence's info string, as a language and attributes.
//   slugify(text) -- GitHub's heading anchor for a heading's text.
//   escapeHTML(text) -- text made safe to put in HTML.

/** The languages whose fenced blocks are Pyking cells. */
export const CELL_LANGUAGES = ["pyking", "pyk"];

/** The attributes a Pyking fence may carry after its language. */
export const CELL_ATTRIBUTES = ["norun", "readonly", "error"];

const CALLOUTS = {
  note: "Note", tip: "Tip", important: "Important",
  warning: "Warning", caution: "Caution",
};

// --- entry point -----------------------------------------------------------

/** Renders a document. Answers the HTML, the Pyking cells in document
 *  order, the headings for a contents list, the title (front matter's,
 *  else the first level-1 heading's), whether any math was written, and
 *  the front matter itself.
 *  String -> {baseURL?, documentLink?, allowHTML?} ->
 *  {html, cells, headings, title, math, meta} */
export function renderMarkdown(source, options = {}) {
  const opts = { baseURL: "", documentLink: null, allowHTML: true, ...options };
  const { meta, body } = frontMatter(source.replace(/\r\n?/g, "\n"));
  const ctx = {
    opts,
    refs: new Map(),
    footnotes: new Map(),
    footnoteOrder: [],
    cells: [],
    headings: [],
    slugs: new Map(),
    math: false,
  };
  const blocks = parseBlocks(body.split("\n"), ctx, 0);
  let html = renderBlocks(blocks, ctx, false);
  html += renderFootnotes(ctx);
  const first = ctx.headings.find((h) => h.level === 1);
  return {
    html,
    cells: ctx.cells,
    headings: ctx.headings,
    title: meta.title || (first ? first.text : ""),
    math: ctx.math,
    meta,
  };
}

/** A front-matter block, `---` to `---` (or `...`) at the very top, read
 *  as `key: value` lines. String -> {meta, body} */
function frontMatter(text) {
  const match = /^---[ \t]*\n([\s\S]*?)\n(?:---|\.\.\.)[ \t]*(?:\n|$)/.exec(text);
  if (!match) return { meta: {}, body: text };
  const meta = {};
  for (const line of match[1].split("\n")) {
    const pair = /^([A-Za-z_][\w-]*)\s*:\s*(.*)$/.exec(line);
    if (pair) meta[pair[1]] = pair[2].replace(/^(["'])(.*)\1$/, "$2").trim();
  }
  return { meta, body: text.slice(match[0].length) };
}

// --- blocks ----------------------------------------------------------------

const RE = {
  blank: /^[ \t]*$/,
  atx: /^ {0,3}(#{1,6})(?:[ \t]+|$)(.*?)(?:[ \t]+#+)?[ \t]*$/,
  fence: /^( {0,3})(`{3,}|~{3,})[ \t]*(.*)$/,
  rule: /^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$/,
  setext: /^ {0,3}(=+|-+)[ \t]*$/,
  quote: /^ {0,3}> ?/,
  bullet: /^( {0,3})([-+*])(?:([ \t]+)(.*)|$)/,
  ordered: /^( {0,3})(\d{1,9})([.)])(?:([ \t]+)(.*)|$)/,
  html: /^ {0,3}(?:<!--|<\/?(?:address|article|aside|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|nav|ol|optgroup|option|p|picture|pre|section|script|source|style|summary|table|tbody|td|template|tfoot|th|thead|title|tr|track|ul|video|audio)(?=[\s/>]|$))/i,
  footnote: /^ {0,3}\[\^([^\]\s]+)\]:[ \t]?(.*)$/,
  reference: /^ {0,3}\[((?:[^\]\\]|\\.)+)\]:[ \t]*(<[^>]*>|\S+)(?:[ \t]+("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^)\\]|\\.)*\)))?[ \t]*$/,
  mathOpen: /^ {0,3}\$\$/,
  tableDelimiter: /^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/,
};

/** Leading tabs as spaces, to the next multiple of four. String -> String */
function expandTabs(line) {
  const match = /^[ \t]*/.exec(line)[0];
  if (!match.includes("\t")) return line;
  let column = 0;
  for (const c of match) column = c === "\t" ? column + 4 - (column % 4) : column + 1;
  return " ".repeat(column) + line.slice(match.length);
}

/** How far a line is indented, in spaces. String -> Int */
function indentOf(line) {
  return /^ */.exec(line)[0].length;
}

/** A line with up to `n` leading spaces removed. String -> Int -> String */
function dedent(line, n) {
  const have = indentOf(line);
  return line.slice(Math.min(have, n));
}

/** Whether a line starts a block that ends a paragraph. A list item
 *  interrupts one only when it has content, and an ordered one only when
 *  it starts at 1 -- CommonMark's rule, so that a number at the start of
 *  a wrapped line is not read as a list. String -> Bool */
function interruptsParagraph(line) {
  if (RE.atx.test(line) || RE.fence.test(line) || RE.rule.test(line)
      || RE.quote.test(line) || RE.mathOpen.test(line)) return true;
  if (RE.html.test(line)) return true;
  const bullet = RE.bullet.exec(line);
  if (bullet && bullet[4] && bullet[4].trim()) return true;
  const ordered = RE.ordered.exec(line);
  if (ordered && ordered[2] === "1" && ordered[5] && ordered[5].trim()) return true;
  return false;
}

/** Splits a table row into its cells: on each `|` that is neither
 *  escaped nor inside a code span. String -> [String] */
function splitRow(line) {
  let text = line.trim();
  if (text.startsWith("|")) text = text.slice(1);
  if (text.endsWith("|") && !text.endsWith("\\|")) text = text.slice(0, -1);
  const cells = [];
  let current = "";
  let ticks = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "\\" && text[i + 1] === "|") { current += "|"; i++; continue; }
    if (c === "`") {
      let run = 1;
      while (text[i + run] === "`") run++;
      ticks = ticks === run ? 0 : ticks || run;
      current += "`".repeat(run);
      i += run - 1;
      continue;
    }
    if (c === "|" && !ticks) { cells.push(current.trim()); current = ""; continue; }
    current += c;
  }
  cells.push(current.trim());
  return cells;
}

/** Whether `line` and the one after it open a table: a header row with
 *  as many cells as the delimiter row below it. String -> String? -> Bool */
function opensTable(line, next) {
  if (next === undefined || !line.includes("|") || !RE.tableDelimiter.test(next)) {
    return false;
  }
  if (!next.includes("|") && !line.trim().startsWith("|")) {
    // A lone `---` under text is a setext heading, not a table.
    if (!/:/.test(next)) return false;
  }
  return splitRow(line).length === splitRow(next).length;
}

/** Parses lines into block nodes. `depth` is 0 for the document itself
 *  and more inside a container, so only top-level headings reach the
 *  contents list. [String] -> Context -> Int -> [Block] */
function parseBlocks(input, ctx, depth) {
  const lines = input.map(expandTabs);
  const blocks = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (RE.blank.test(line)) { i++; continue; }

    // Fenced code, including ```math.
    let m = RE.fence.exec(line);
    if (m && !(m[2][0] === "`" && m[3].includes("`"))) {
      const indent = m[1].length;
      const marker = m[2];
      const body = [];
      i++;
      while (i < lines.length) {
        const close = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(lines[i]);
        if (close && close[1][0] === marker[0] && close[1].length >= marker.length) {
          i++;
          break;
        }
        body.push(dedent(lines[i], indent));
        i++;
      }
      const info = parseInfo(m[3]);
      if (info.language === "math") {
        ctx.math = true;
        blocks.push({ type: "math", tex: body.join("\n") });
      } else {
        blocks.push({ type: "code", info, text: body.join("\n") });
      }
      continue;
    }

    // Display math: $$ ... $$, on one line or several.
    if (RE.mathOpen.test(line)) {
      const first = line.trim().slice(2);
      const tex = [];
      if (first.endsWith("$$") && first.length >= 2) {
        tex.push(first.slice(0, -2));
        i++;
      } else {
        if (first.trim()) tex.push(first);
        i++;
        while (i < lines.length) {
          const t = lines[i].trimEnd();
          if (t.endsWith("$$")) {
            if (t.slice(0, -2).trim()) tex.push(t.slice(0, -2));
            i++;
            break;
          }
          tex.push(lines[i]);
          i++;
        }
      }
      ctx.math = true;
      blocks.push({ type: "math", tex: tex.join("\n").trim() });
      continue;
    }

    m = RE.atx.exec(line);
    if (m) {
      blocks.push({ type: "heading", level: m[1].length, text: m[2], depth });
      i++;
      continue;
    }

    if (RE.rule.test(line)) {
      blocks.push({ type: "rule" });
      i++;
      continue;
    }

    // Block quotes, and the callouts written as one.
    if (RE.quote.test(line)) {
      const inner = [];
      while (i < lines.length) {
        if (RE.quote.test(lines[i])) {
          inner.push(lines[i].replace(RE.quote, ""));
        } else if (!RE.blank.test(lines[i]) && inner.length
                   && !RE.blank.test(inner[inner.length - 1])
                   && !interruptsParagraph(lines[i])) {
          inner.push(lines[i]);    // a lazy continuation line
        } else {
          break;
        }
        i++;
      }
      const callout = /^[ \t]*\[!(note|tip|important|warning|caution)\][ \t]*$/i
        .exec(inner[0] || "");
      if (callout) {
        blocks.push({
          type: "callout",
          kind: callout[1].toLowerCase(),
          children: parseBlocks(inner.slice(1), ctx, depth + 1),
        });
      } else {
        blocks.push({ type: "quote", children: parseBlocks(inner, ctx, depth + 1) });
      }
      continue;
    }

    // Lists.
    if (RE.bullet.test(line) || RE.ordered.test(line)) {
      const parsed = parseList(lines, i, ctx, depth);
      blocks.push(parsed.block);
      i = parsed.next;
      continue;
    }

    // Footnote definitions: the first line, then indented continuations.
    m = RE.footnote.exec(line);
    if (m) {
      const label = m[1].toLowerCase();
      const body = [m[2]];
      i++;
      while (i < lines.length) {
        if (RE.blank.test(lines[i])) {
          if (i + 1 < lines.length && indentOf(lines[i + 1]) >= 4) {
            body.push("");
            i++;
            continue;
          }
          break;
        }
        if (indentOf(lines[i]) >= 4) body.push(dedent(lines[i], 4));
        else if (!interruptsParagraph(lines[i]) && !RE.footnote.test(lines[i])) {
          body.push(lines[i]);
        } else break;
        i++;
      }
      if (!ctx.footnotes.has(label)) {
        ctx.footnotes.set(label, { blocks: parseBlocks(body, ctx, depth + 1) });
      }
      continue;
    }

    // Link reference definitions: recorded, rendered as nothing.
    m = RE.reference.exec(line);
    if (m && !m[1].startsWith("^")) {
      const label = normalizeLabel(m[1]);
      if (!ctx.refs.has(label)) {
        ctx.refs.set(label, {
          url: m[2].replace(/^<|>$/g, ""),
          title: m[3] ? unescapeText(m[3].slice(1, -1)) : null,
        });
      }
      i++;
      continue;
    }

    // Raw HTML: through to the next blank line.
    if (RE.html.test(line)) {
      const body = [];
      if (/^ {0,3}<!--/.test(line)) {
        while (i < lines.length) {
          body.push(lines[i]);
          i++;
          if (lines[i - 1].includes("-->")) break;
        }
      } else {
        while (i < lines.length && !RE.blank.test(lines[i])) body.push(lines[i++]);
      }
      blocks.push({ type: "html", text: body.join("\n") });
      continue;
    }

    // Indented code.
    if (indentOf(line) >= 4) {
      const body = [];
      while (i < lines.length && (indentOf(lines[i]) >= 4 || RE.blank.test(lines[i]))) {
        body.push(dedent(lines[i], 4));
        i++;
      }
      while (body.length && RE.blank.test(body[body.length - 1])) body.pop();
      blocks.push({ type: "code", info: parseInfo(""), text: body.join("\n") });
      continue;
    }

    if (opensTable(line, lines[i + 1])) {
      const parsed = parseTable(lines, i);
      blocks.push(parsed.block);
      i = parsed.next;
      continue;
    }

    // A paragraph, or a setext heading if an underline ends it.
    const text = [line];
    i++;
    let heading = 0;
    while (i < lines.length && !RE.blank.test(lines[i])) {
      const setext = RE.setext.exec(lines[i]);
      if (setext) {
        heading = setext[1][0] === "=" ? 1 : 2;
        i++;
        break;
      }
      if (interruptsParagraph(lines[i]) || opensTable(lines[i], lines[i + 1])) break;
      text.push(lines[i]);
      i++;
    }
    const joined = text.map((t) => t.replace(/^[ \t]+/, "")).join("\n");
    if (heading) blocks.push({ type: "heading", level: heading, text: joined.trim(), depth });
    else blocks.push({ type: "paragraph", text: joined });
  }
  return blocks;
}

/** A list starting at lines[start]: its items, each parsed as blocks of
 *  its own, and whether it is loose. [String] -> Int -> Context -> Int ->
 *  {block, next} */
function parseList(lines, start, ctx, depth) {
  const first = RE.bullet.exec(lines[start]);
  const ordered = !first;
  const head = first || RE.ordered.exec(lines[start]);
  const marker = ordered ? head[3] : head[2];
  const startNumber = ordered ? parseInt(head[2], 10) : 1;
  const items = [];
  let loose = false;
  let i = start;
  let sawBlankBetween = false;

  while (i < lines.length) {
    const m = ordered ? RE.ordered.exec(lines[i]) : RE.bullet.exec(lines[i]);
    if (!m || (ordered ? m[3] : m[2]) !== marker || RE.rule.test(lines[i]) && !ordered) break;
    const indent = m[1].length;
    const markerWidth = ordered ? m[2].length + 1 : 1;
    const spacing = ordered ? m[4] : m[3];
    const content = ordered ? m[5] : m[4];
    let width = spacing === undefined ? 1 : spacing.length;
    if (width > 4 || content === undefined || !content.trim()) width = 1;
    const contentIndent = indent + markerWidth + width;
    const body = [content === undefined ? "" : (spacing && spacing.length > 4
      ? " ".repeat(spacing.length - 1) + content : content)];
    if (sawBlankBetween) loose = true;
    i++;
    let blankInside = false;
    while (i < lines.length) {
      const line = lines[i];
      if (RE.blank.test(line)) {
        // A blank line belongs to the item only if more of it follows.
        let j = i + 1;
        while (j < lines.length && RE.blank.test(lines[j])) j++;
        if (j < lines.length && indentOf(lines[j]) >= contentIndent) {
          for (let k = i; k < j; k++) body.push("");
          blankInside = true;
          i = j;
          continue;
        }
        break;
      }
      if (indentOf(line) >= contentIndent) {
        body.push(line.slice(contentIndent));
        i++;
        continue;
      }
      // A lazy continuation of the item's paragraph.
      const last = body[body.length - 1];
      if (last !== undefined && !RE.blank.test(last) && !interruptsParagraph(line)
          && !RE.bullet.test(line) && !RE.ordered.test(line)) {
        body.push(line);
        i++;
        continue;
      }
      break;
    }
    // Blank lines between this item and the next make the list loose.
    let j = i;
    while (j < lines.length && RE.blank.test(lines[j])) j++;
    sawBlankBetween = j > i;
    const next = j < lines.length
      ? (ordered ? RE.ordered.exec(lines[j]) : RE.bullet.exec(lines[j])) : null;
    const continues = next && (ordered ? next[3] : next[2]) === marker
      && indentOf(lines[j]) < contentIndent;

    let task = null;
    const taskMatch = /^\[([ xX])\][ \t]+/.exec(body[0]);
    if (taskMatch) {
      task = taskMatch[1] !== " ";
      body[0] = body[0].slice(taskMatch[0].length);
    }
    const children = parseBlocks(body, ctx, depth + 1);
    if (blankInside && children.length > 1) loose = true;
    items.push({ children, task });
    if (!continues) break;
    i = j;
  }
  return {
    block: { type: "list", ordered, start: startNumber, items, loose },
    next: i,
  };
}

/** A table starting at lines[start]: the header, the alignments from the
 *  delimiter row, and the body rows. [String] -> Int -> {block, next} */
function parseTable(lines, start) {
  const header = splitRow(lines[start]);
  const align = splitRow(lines[start + 1]).map((cell) => {
    const left = cell.startsWith(":");
    const right = cell.endsWith(":");
    return left && right ? "center" : right ? "right" : left ? "left" : null;
  });
  const rows = [];
  let i = start + 2;
  while (i < lines.length && !RE.blank.test(lines[i])
         && !(interruptsParagraph(lines[i]) && !lines[i].includes("|"))) {
    const cells = splitRow(lines[i]);
    rows.push(header.map((_, k) => cells[k] ?? ""));
    i++;
  }
  return { block: { type: "table", header, align, rows }, next: i };
}

/** A fence's info string: the language, and every attribute after it.
 *  `pyking norun` and `{.pyking .norun}` read the same.
 *  String -> {language, attrs, raw} */
export function parseInfo(info) {
  const raw = info.trim();
  const words = raw.replace(/^\{|\}$/g, "").split(/[\s,]+/)
    .map((w) => w.replace(/^\./, "")).filter(Boolean);
  const language = (words[0] || "").toLowerCase();
  const attrs = {};
  for (const word of words.slice(1)) attrs[word.toLowerCase()] = true;
  return { language, attrs, raw };
}

// --- rendering blocks ------------------------------------------------------

/** Renders block nodes. `tight` drops the paragraphs' `<p>`, for the
 *  items of a tight list. [Block] -> Context -> Bool -> String */
function renderBlocks(blocks, ctx, tight) {
  return blocks.map((block) => renderBlock(block, ctx, tight)).join("");
}

/** Renders one block node. Block -> Context -> Bool -> String */
function renderBlock(block, ctx, tight) {
  switch (block.type) {
    case "paragraph": {
      const inline = renderInline(block.text.trimEnd(), ctx);
      return tight ? inline + "\n" : `<p>${inline}</p>\n`;
    }
    case "heading": {
      const inner = renderInline(block.text, ctx);
      const text = plainText(inner);
      const id = uniqueSlug(ctx, slugify(text));
      if (block.depth === 0) ctx.headings.push({ level: block.level, text, id });
      return `<h${block.level} id="${id}">`
        + `<a class="pkn-anchor" href="#${id}" aria-hidden="true">#</a>`
        + `${inner}</h${block.level}>\n`;
    }
    case "rule":
      return "<hr>\n";
    case "code":
      return renderCode(block, ctx);
    case "math":
      return `<div class="pkn-math pkn-math-display">${escapeHTML(block.tex)}</div>\n`;
    case "quote":
      return `<blockquote>\n${renderBlocks(block.children, ctx, false)}</blockquote>\n`;
    case "callout":
      return `<div class="pkn-callout pkn-callout-${block.kind}">`
        + `<p class="pkn-callout-title">${CALLOUTS[block.kind]}</p>\n`
        + `${renderBlocks(block.children, ctx, false)}</div>\n`;
    case "list": {
      const tag = block.ordered ? "ol" : "ul";
      const start = block.ordered && block.start !== 1 ? ` start="${block.start}"` : "";
      const tasks = block.items.some((item) => item.task !== null);
      const items = block.items.map((item) => {
        const box = item.task === null ? ""
          : `<input type="checkbox" disabled${item.task ? " checked" : ""}> `;
        const cls = item.task === null ? "" : ' class="pkn-task"';
        let inner = renderBlocks(item.children, ctx, !block.loose);
        if (!block.loose) inner = inner.replace(/\n$/, "");
        return `<li${cls}>${box}${inner}</li>\n`;
      }).join("");
      const cls = tasks ? ' class="pkn-tasks"' : "";
      return `<${tag}${start}${cls}>\n${items}</${tag}>\n`;
    }
    case "table": {
      const style = (k) => block.align[k] ? ` style="text-align:${block.align[k]}"` : "";
      const head = block.header
        .map((cell, k) => `<th${style(k)}>${renderInline(cell, ctx)}</th>`).join("");
      const rows = block.rows.map((row) => "<tr>" + row
        .map((cell, k) => `<td${style(k)}>${renderInline(cell, ctx)}</td>`).join("")
        + "</tr>\n").join("");
      return `<div class="pkn-table"><table>\n<thead><tr>${head}</tr></thead>\n`
        + (rows ? `<tbody>\n${rows}</tbody>\n` : "") + "</table></div>\n";
    }
    case "html":
      return ctx.opts.allowHTML ? block.text + "\n"
        : `<p>${escapeHTML(block.text)}</p>\n`;
    default:
      return "";
  }
}

/** A code block: a cell placeholder for runnable Pyking, else a `<pre>`
 *  the notebook highlights. Block -> Context -> String */
function renderCode(block, ctx) {
  const { language, attrs } = block.info;
  const isPyking = CELL_LANGUAGES.includes(language);
  if (isPyking && !attrs.norun) {
    const index = ctx.cells.length;
    const known = Object.fromEntries(CELL_ATTRIBUTES.map((a) => [a, !!attrs[a]]));
    ctx.cells.push({ index, id: `cell-${index + 1}`, source: block.text, attrs: known });
    return `<div class="pkn-cell" id="cell-${index + 1}" data-cell="${index}">`
      + `<pre class="pkn-cell-fallback"><code>${escapeHTML(block.text)}</code></pre>`
      + "</div>\n";
  }
  const lang = isPyking ? "pyking" : language;
  const data = lang ? ` data-lang="${escapeHTML(lang)}"` : "";
  return `<pre class="pkn-code"${data}><code>${escapeHTML(block.text)}</code></pre>\n`;
}

/** The footnotes section: every definition that was referenced, in the
 *  order first referenced, each with a link back. Context -> String */
function renderFootnotes(ctx) {
  if (!ctx.footnoteOrder.length) return "";
  // Rendering a footnote may reference another, which extends the order
  // while it is being walked; a plain index loop takes those in too.
  const items = [];
  for (let k = 0; k < ctx.footnoteOrder.length; k++) {
    const label = ctx.footnoteOrder[k];
    const note = ctx.footnotes.get(label);
    const n = k + 1;
    let inner = renderBlocks(note.blocks, ctx, false);
    const back = ` <a href="#fnref-${n}" class="pkn-fnback" aria-label="Back to the text">↩</a>`;
    inner = /<\/p>\n$/.test(inner)
      ? inner.replace(/<\/p>\n$/, back + "</p>\n") : inner + back;
    items.push(`<li id="fn-${n}">\n${inner}</li>\n`);
  }
  return `<section class="pkn-footnotes">\n<ol>\n${items.join("")}</ol>\n</section>\n`;
}

// --- inlines ---------------------------------------------------------------

const PUNCTUATION = /[\p{P}\p{S}]/u;
const WHITESPACE = /\s/u;
const ESCAPABLE = /[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]/;
const INLINE_HTML = new RegExp("^(?:"
  + "<[A-Za-z][A-Za-z0-9-]*(?:\\s+[A-Za-z_:][\\w.:-]*(?:\\s*=\\s*(?:[^\\s\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*\\s*/?>"
  + "|</[A-Za-z][A-Za-z0-9-]*\\s*>"
  + "|<!--[\\s\\S]*?-->)");
const AUTOLINK = /^<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*)>/;
const EMAIL = /^<([A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*)>/;
const BARE_URL = /^(?:https?:\/\/|www\.)[^\s<]*[^\s<?!.,:*_~'")\]]/;
const ENTITY = /^&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/;

/** Renders inline Markdown: code spans, math, links and images,
 *  emphasis, strikethrough, autolinks, footnote references, raw HTML and
 *  escapes. Emphasis follows CommonMark's delimiter algorithm.
 *  String -> Context -> String */
function renderInline(text, ctx) {
  const nodes = [];
  let buffer = "";
  const flush = () => {
    if (buffer) nodes.push({ type: "text", value: buffer });
    buffer = "";
  };
  const html = (value) => { flush(); nodes.push({ type: "html", value }); };
  let i = 0;
  let openBrackets = 0;

  while (i < text.length) {
    const c = text[i];
    const rest = text.slice(i);

    if (c === "\\") {
      if (text[i + 1] === "\n") { html("<br>\n"); i += 2; continue; }
      if (ESCAPABLE.test(text[i + 1] || "")) { buffer += text[i + 1]; i += 2; continue; }
      buffer += c; i++; continue;
    }

    if (c === "`") {
      const run = /^`+/.exec(rest)[0];
      const close = findBacktickRun(text, i + run.length, run.length);
      if (close < 0) { buffer += run; i += run.length; continue; }
      let code = text.slice(i + run.length, close).replace(/\n/g, " ");
      if (code.length >= 2 && code.startsWith(" ") && code.endsWith(" ") && code.trim()) {
        code = code.slice(1, -1);
      }
      html(`<code>${escapeHTML(code)}</code>`);
      i = close + run.length;
      continue;
    }

    if (c === "$") {
      const math = matchInlineMath(text, i);
      if (math) {
        ctx.math = true;
        const cls = math.display ? "pkn-math pkn-math-display" : "pkn-math";
        html(`<span class="${cls}">${escapeHTML(math.tex)}</span>`);
        i = math.end;
        continue;
      }
      buffer += c; i++; continue;
    }

    if (c === "<") {
      let m = AUTOLINK.exec(rest);
      if (m) {
        html(`<a href="${escapeHTML(safeURL(m[1]))}">${escapeHTML(m[1])}</a>`);
        i += m[0].length;
        continue;
      }
      m = EMAIL.exec(rest);
      if (m) {
        html(`<a href="mailto:${escapeHTML(m[1])}">${escapeHTML(m[1])}</a>`);
        i += m[0].length;
        continue;
      }
      m = INLINE_HTML.exec(rest);
      if (m && ctx.opts.allowHTML) { html(m[0]); i += m[0].length; continue; }
      buffer += c; i++; continue;
    }

    if (c === "&") {
      const m = ENTITY.exec(rest);
      if (m) { html(m[0]); i += m[0].length; continue; }
      buffer += c; i++; continue;
    }

    if (c === "!" && text[i + 1] === "[") {
      flush();
      nodes.push({ type: "bracket", image: true, active: true, source: i + 2 });
      openBrackets++;
      i += 2;
      continue;
    }
    if (c === "[") {
      // A footnote reference is recognised whole, before brackets are.
      const note = /^\[\^([^\]\s]+)\]/.exec(rest);
      if (note && ctx.footnotes.has(note[1].toLowerCase())) {
        html(footnoteReference(note[1].toLowerCase(), ctx));
        i += note[0].length;
        continue;
      }
      flush();
      nodes.push({ type: "bracket", image: false, active: true, source: i + 1 });
      openBrackets++;
      i++;
      continue;
    }
    if (c === "]") {
      flush();
      const consumed = closeBracket(nodes, text, i, ctx);
      if (consumed) openBrackets--;
      i = consumed ? consumed : i + 1;
      if (!consumed) nodes.push({ type: "text", value: "]" });
      continue;
    }

    if (c === "*" || c === "_" || c === "~") {
      const run = new RegExp(`^\\${c}+`).exec(rest)[0];
      if (c === "~" && run.length > 2) { buffer += run; i += run.length; continue; }
      const before = i === 0 ? " " : text[i - 1];
      const after = text[i + run.length] ?? " ";
      const wsAfter = WHITESPACE.test(after);
      const wsBefore = WHITESPACE.test(before);
      const punctAfter = PUNCTUATION.test(after);
      const punctBefore = PUNCTUATION.test(before);
      const left = !wsAfter && (!punctAfter || wsBefore || punctBefore);
      const right = !wsBefore && (!punctBefore || wsAfter || punctAfter);
      let canOpen = left;
      let canClose = right;
      if (c === "_") {
        canOpen = left && (!right || punctBefore);
        canClose = right && (!left || punctAfter);
      }
      flush();
      nodes.push({ type: "delim", char: c, count: run.length, orig: run.length,
                   canOpen, canClose });
      i += run.length;
      continue;
    }

    if (c === "\n") {
      if (/ {2,}$/.test(buffer)) { buffer = buffer.replace(/ +$/, ""); html("<br>\n"); }
      else { buffer = buffer.replace(/ +$/, ""); buffer += "\n"; }
      i++;
      continue;
    }

    if ((c === "h" || c === "w") && !openBrackets
        && (i === 0 || /[\s*_~(]/.test(text[i - 1]))) {
      const m = BARE_URL.exec(rest);
      if (m) {
        let url = m[0];
        // A closing parenthesis ends the link unless the link opened one.
        while (url.endsWith(")") && (url.match(/\(/g) || []).length
               < (url.match(/\)/g) || []).length) url = url.slice(0, -1);
        const href = url.startsWith("www.") ? "http://" + url : url;
        html(`<a href="${escapeHTML(safeURL(href))}">${escapeHTML(url)}</a>`);
        i += url.length;
        continue;
      }
    }

    buffer += c;
    i++;
  }
  flush();
  processEmphasis(nodes, 0);
  return renderNodes(nodes);
}

/** Where the next backtick run of exactly `length` starts, or -1.
 *  String -> Int -> Int -> Int */
function findBacktickRun(text, from, length) {
  let i = from;
  while (i < text.length) {
    if (text[i] !== "`") { i++; continue; }
    let run = 0;
    while (text[i + run] === "`") run++;
    if (run === length) return i;
    i += run;
  }
  return -1;
}

/** Inline math starting at text[i]: `$$...$$` (display) or `$...$`,
 *  where the opening `$` is followed by a non-space, the closing one is
 *  preceded by a non-space and not followed by a digit -- Pandoc's rule,
 *  which keeps "$5 and $6" as text. String -> Int -> {tex, display, end}? */
function matchInlineMath(text, i) {
  if (text[i + 1] === "$") {
    const close = text.indexOf("$$", i + 2);
    if (close > i + 2) return { tex: text.slice(i + 2, close).trim(), display: true, end: close + 2 };
    return null;
  }
  if (!text[i + 1] || WHITESPACE.test(text[i + 1])) return null;
  for (let j = i + 1; j < text.length; j++) {
    if (text[j] === "\\") { j++; continue; }
    if (text[j] === "\n" && text[j + 1] === "\n") return null;
    if (text[j] === "$") {
      if (WHITESPACE.test(text[j - 1]) || /[0-9]/.test(text[j + 1] || "")) return null;
      return { tex: text.slice(i + 1, j), display: false, end: j + 1 };
    }
  }
  return null;
}

/** A footnote reference: numbered in the order first referenced.
 *  String -> Context -> String */
function footnoteReference(label, ctx) {
  let n = ctx.footnoteOrder.indexOf(label) + 1;
  const first = n === 0;
  if (first) {
    ctx.footnoteOrder.push(label);
    n = ctx.footnoteOrder.length;
  }
  const id = first ? ` id="fnref-${n}"` : "";
  return `<sup class="pkn-fnref"${id}><a href="#fn-${n}">${n}</a></sup>`;
}

/** Handles a `]` at text[i]: when it closes a bracket as a link or an
 *  image, replaces the bracket and what follows it with the rendered
 *  link and answers the index after it; otherwise answers 0.
 *  [Node] -> String -> Int -> Context -> Int */
function closeBracket(nodes, text, i, ctx) {
  let b = nodes.length - 1;
  while (b >= 0 && nodes[b].type !== "bracket") b--;
  if (b < 0) return 0;
  const bracket = nodes[b];
  if (!bracket.active) {
    nodes[b] = { type: "text", value: bracket.image ? "![" : "[" };
    return 0;
  }
  const label = text.slice(bracket.source, i);
  let target = null;
  let end = i + 1;

  const inline = parseLinkTail(text, i + 1);
  if (inline) {
    target = inline;
    end = inline.end;
  } else {
    const full = /^\[((?:[^\]\\]|\\.)*)\]/.exec(text.slice(i + 1));
    if (full && full[1].trim()) {
      target = ctx.refs.get(normalizeLabel(full[1])) || null;
      if (target) end = i + 1 + full[0].length;
    } else {
      target = ctx.refs.get(normalizeLabel(label)) || null;
      if (target && full) end = i + 1 + full[0].length;   // `[text][]`
    }
  }
  if (!target) {
    nodes[b] = { type: "text", value: bracket.image ? "![" : "[" };
    return 0;
  }

  processEmphasis(nodes, b + 1);
  const inner = renderNodes(nodes.slice(b + 1));
  const url = resolveURL(target.url, bracket.image, ctx);
  const title = target.title ? ` title="${escapeHTML(target.title)}"` : "";
  let rendered;
  if (bracket.image) {
    rendered = `<img src="${escapeHTML(url)}" alt="${escapeHTML(plainText(inner))}"${title}>`;
  } else {
    rendered = `<a href="${escapeHTML(url)}"${title}>${inner}</a>`;
    // No links inside links: every `[` before this one stops opening one.
    for (let k = 0; k < b; k++) {
      if (nodes[k].type === "bracket" && !nodes[k].image) nodes[k].active = false;
    }
  }
  nodes.splice(b, nodes.length - b, { type: "html", value: rendered });
  return end;
}

/** An inline link's `(destination "title")` at text[i], or null.
 *  String -> Int -> {url, title, end}? */
function parseLinkTail(text, i) {
  if (text[i] !== "(") return null;
  let j = i + 1;
  const skip = () => { while (j < text.length && /[ \t\n]/.test(text[j])) j++; };
  skip();
  let url = "";
  if (text[j] === "<") {
    const close = text.indexOf(">", j);
    if (close < 0 || text.slice(j, close).includes("\n")) return null;
    url = text.slice(j + 1, close);
    j = close + 1;
  } else {
    let depth = 0;
    const start = j;
    while (j < text.length) {
      const c = text[j];
      if (c === "\\" && ESCAPABLE.test(text[j + 1] || "")) { j += 2; continue; }
      if (/\s/.test(c)) break;
      if (c === "(") depth++;
      if (c === ")") { if (depth === 0) break; depth--; }
      j++;
    }
    url = text.slice(start, j);
  }
  skip();
  let title = null;
  const quote = text[j];
  if (quote === '"' || quote === "'" || quote === "(") {
    const closer = quote === "(" ? ")" : quote;
    let k = j + 1;
    while (k < text.length && text[k] !== closer) k += text[k] === "\\" ? 2 : 1;
    if (k >= text.length) return null;
    title = unescapeText(text.slice(j + 1, k));
    j = k + 1;
    skip();
  }
  if (text[j] !== ")") return null;
  return { url: unescapeText(url), title, end: j + 1 };
}

/** CommonMark's emphasis pass over nodes[bottom..]: pairs each closing
 *  delimiter run with the nearest opener it may close, innermost first,
 *  and replaces the pair and what lies between with one rendered node.
 *  `~` pairs only with a run of its own length, as strikethrough.
 *  [Node] -> Int -> () */
function processEmphasis(nodes, bottom) {
  let i = bottom;
  while (i < nodes.length) {
    const closer = nodes[i];
    if (closer.type !== "delim" || !closer.canClose) { i++; continue; }
    let found = -1;
    for (let j = i - 1; j >= bottom; j--) {
      const opener = nodes[j];
      if (opener.type !== "delim" || opener.char !== closer.char || !opener.canOpen) continue;
      if (closer.char === "~") {
        if (opener.count === closer.count) { found = j; break; }
        continue;
      }
      const odd = (opener.canClose || closer.canOpen)
        && (opener.orig + closer.orig) % 3 === 0
        && !(opener.orig % 3 === 0 && closer.orig % 3 === 0);
      if (odd) continue;
      found = j;
      break;
    }
    if (found < 0) { i++; continue; }
    const opener = nodes[found];
    const use = closer.char === "~" ? closer.count
      : opener.count >= 2 && closer.count >= 2 ? 2 : 1;
    const tag = closer.char === "~" ? "del" : use === 2 ? "strong" : "em";
    const inner = renderNodes(nodes.slice(found + 1, i));
    opener.count -= use;
    closer.count -= use;
    const replacement = [];
    if (opener.count > 0) replacement.push(opener);
    replacement.push({ type: "html", value: `<${tag}>${inner}</${tag}>` });
    if (closer.count > 0) replacement.push(closer);
    nodes.splice(found, i - found + 1, ...replacement);
    i = found + (opener.count > 0 ? 1 : 0) + 1;
  }
}

/** Inline nodes as HTML: text escaped, a delimiter run nothing paired
 *  as its own characters, a bracket nothing closed as itself.
 *  [Node] -> String */
function renderNodes(nodes) {
  return nodes.map((node) => {
    switch (node.type) {
      case "text": return escapeText(node.value);
      case "html": return node.value;
      case "delim": return node.char.repeat(node.count);
      case "bracket": return node.image ? "![" : "[";
      default: return "";
    }
  }).join("");
}

// --- helpers ---------------------------------------------------------------

/** A link or image destination, resolved against the document: an
 *  absolute URL or a fragment is left alone, a link to another Markdown
 *  file goes through `documentLink`, and anything else relative is put
 *  under `baseURL`. String -> Bool -> Context -> String */
function resolveURL(url, image, ctx) {
  const safe = safeURL(url);
  if (/^[A-Za-z][A-Za-z0-9+.-]*:|^\/\/|^#|^\//.test(safe)) return safe;
  if (!image && ctx.opts.documentLink && /\.md(?:#.*)?$/i.test(safe)) {
    return ctx.opts.documentLink(safe);
  }
  return (ctx.opts.baseURL || "") + safe;
}

/** A URL, or `#` for one whose scheme could run script.
 *  String -> String */
function safeURL(url) {
  return /^\s*(?:javascript|vbscript|data(?!:image\/(?:png|gif|jpe?g|webp|svg\+xml)[;,])):/i
    .test(url) ? "#" : url;
}

/** A link label, as references are matched: case- and space-folded.
 *  String -> String */
function normalizeLabel(label) {
  return label.trim().replace(/\s+/g, " ").toLowerCase();
}

/** Backslash escapes removed. String -> String */
function unescapeText(text) {
  return text.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/g, "$1");
}

/** Rendered HTML as the text it shows. String -> String */
function plainText(html) {
  return html.replace(/<[^>]*>/g, "")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'").replace(/&amp;/g, "&").trim();
}

/** GitHub's anchor for a heading: lower case, punctuation dropped,
 *  spaces as hyphens. String -> String */
export function slugify(text) {
  return text.toLowerCase().trim()
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .replace(/\s/g, "-") || "section";
}

/** A slug not used before in this document: `x`, then `x-1`, `x-2`.
 *  Context -> String -> String */
function uniqueSlug(ctx, slug) {
  const seen = ctx.slugs.get(slug) ?? -1;
  ctx.slugs.set(slug, seen + 1);
  return seen < 0 ? slug : `${slug}-${seen + 1}`;
}

/** Text made safe to put in HTML content, but not in an attribute.
 *  String -> String */
function escapeText(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

/** Text made safe to put in HTML, in content or an attribute.
 *  String -> String */
export function escapeHTML(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
