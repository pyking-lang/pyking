// The playground's language server client: Monaco's hover, go to
// definition, outline, completion, signature help, references, the
// highlights of a name, renaming, folding, semantic highlighting and
// quick fixes for Pyking, and the
// diagnostics under the source, all answered by the Pyking language
// server (src/lsp.ml) running in the compiler's worker.
//
// Messages go through PykingRuntime's `lsp` and `lspIdle` (see
// tools/webrun/assets/pyking-runtime.js), which hand one JSON-RPC message
// to the server and answer what it sends back. The server checks a
// changed document only when asked what it has to say once typing has
// paused, so every change is followed, DIAGNOSTICS_DELAY later, by
// `lspIdle`, which is where `textDocument/publishDiagnostics` comes from.
//
// The server's state is the worker's, so a worker replaced by Stop or by a
// rebuilt compiler has forgotten the document: the client notices from
// `runtime.generation` and opens it again before its next message.
//
// A bundle with no language server answers null to everything, and the
// client then does nothing at all.

/** How long the source has to sit still before the server is asked for
 *  diagnostics, in milliseconds. */
const DIAGNOSTICS_DELAY = 200;

/** The owner of the markers the server's diagnostics become. */
export const MARKER_OWNER = "pyking-lsp";

// LSP's CompletionItemKind (1-based) to Monaco's, by name.
const COMPLETION_KINDS = [
  null, "Text", "Method", "Function", "Constructor", "Field", "Variable",
  "Class", "Interface", "Module", "Property", "Unit", "Value", "Enum",
  "Keyword", "Snippet", "Color", "File", "Reference", "Folder", "EnumMember",
  "Constant", "Struct", "Event", "Operator", "TypeParameter",
];

/** Where under lib/ a document the server names is: `file:///lib/<path>`
 *  is lib/<path>, and a bare `file:///<module>.pyk` or
 *  `file:///<module>_external.pyk` -- a module the page supplied no source
 *  for -- is in its module's own folder, as the worker reads it.
 *  String -> String? */
function libraryPath(uri) {
  const under = /^file:\/\/\/lib\/(.+\.pyk)$/.exec(uri);
  if (under) return under[1];
  const bare = /^file:\/\/\/(([A-Za-z_][A-Za-z0-9_]*?)(_external)?\.pyk)$/.exec(uri);
  return bare && bare[2] !== "playground" ? `${bare[2]}/${bare[1]}` : null;
}

export class LspClient {
  /** monaco: the editor's namespace. runtime: the PykingRuntime whose
   *  worker runs the server. editor: the source editor, whose model is the
   *  one document. uri: that document's URI. libURL: where the standard
   *  library is served, for a definition in it. onOpenElsewhere(where,
   *  range): called for a definition outside the document, with its path
   *  under lib/ or its URI. */
  constructor(monaco, runtime, editor, { uri, libURL, onOpenElsewhere } = {}) {
    this.monaco = monaco;
    this.runtime = runtime;
    this.editor = editor;
    this.model = editor.getModel();
    this.uri = uri;
    this.libURL = libURL;
    this.onOpenElsewhere = onOpenElsewhere || (() => {});
    this.version = 1;
    this.nextId = 1;
    this.generation = null;   // which worker has the document open
    this.opening = null;      // the session being started, if one is
    this.available = true;    // false once the bundle said it has no server
    this.capabilities = null;
    this.timer = null;
    this.disposables = [];
  }

  /** Starts the session and registers the providers. Answers whether the
   *  bundle has a language server. () -> Promise<Bool> */
  async start() {
    if (!(await this.session())) return false;
    const { monaco } = this;
    const language = this.model.getLanguageId();
    const mine = (model) => model === this.model;
    this.disposables.push(
      this.model.onDidChangeContent(() => this.changed()),
      monaco.languages.registerHoverProvider(language, {
        provideHover: (model, position) =>
          mine(model) ? this.hover(position) : null,
      }),
      monaco.languages.registerDefinitionProvider(language, {
        provideDefinition: (model, position) =>
          mine(model) ? this.definition(position) : null,
      }),
      monaco.languages.registerDocumentSymbolProvider(language, {
        provideDocumentSymbols: (model) => (mine(model) ? this.symbols() : null),
      }),
      monaco.languages.registerCompletionItemProvider(language, {
        triggerCharacters: ["."],
        provideCompletionItems: (model, position) =>
          mine(model) ? this.completion(position) : null,
      }),
      monaco.languages.registerSignatureHelpProvider(language, {
        signatureHelpTriggerCharacters: ["(", ","],
        signatureHelpRetriggerCharacters: ["="],
        provideSignatureHelp: (model, position) =>
          mine(model) ? this.signatureHelp(position) : null,
      }),
      monaco.languages.registerReferenceProvider(language, {
        provideReferences: (model, position, context) =>
          mine(model) ? this.references(position, context) : null,
      }),
      monaco.languages.registerDocumentHighlightProvider(language, {
        provideDocumentHighlights: (model, position) =>
          mine(model) ? this.highlights(position) : null,
      }),
      monaco.languages.registerRenameProvider(language, {
        provideRenameEdits: (model, position, newName) =>
          mine(model) ? this.rename(position, newName) : null,
        resolveRenameLocation: (model, position) =>
          mine(model) ? this.prepareRename(position) : null,
      }),
      monaco.languages.registerFoldingRangeProvider(language, {
        provideFoldingRanges: (model) => (mine(model) ? this.folding() : null),
      }),
      monaco.languages.registerCodeActionProvider(language, {
        provideCodeActions: (model, range) => (mine(model) ? this.codeActions(range) : null),
      }),
    );
    const legend = this.capabilities?.semanticTokensProvider?.legend;
    if (legend) {
      this.disposables.push(monaco.languages.registerDocumentSemanticTokensProvider(language, {
        getLegend: () => legend,
        provideDocumentSemanticTokens: (model) => (mine(model) ? this.semanticTokens() : null),
        releaseDocumentSemanticTokens: () => {},
      }));
    }
    if (monaco.editor.registerEditorOpener) {
      this.disposables.push(monaco.editor.registerEditorOpener({
        openCodeEditor: (source, resource, selection) => {
          if (resource.toString() === this.model.uri.toString()) return false;
          const path = libraryPath(resource.toString());
          this.onOpenElsewhere(path ? "lib/" + path : resource.toString(), selection);
          return true;
        },
      }));
    }
    return true;
  }

  /** Unregisters everything and closes the document. () -> () */
  dispose() {
    clearTimeout(this.timer);
    for (const d of this.disposables) d.dispose();
    this.disposables = [];
    this.monaco.editor.setModelMarkers(this.model, MARKER_OWNER, []);
  }

  // -- the session ------------------------------------------------------

  /** Makes sure the worker answering now has the document open:
   *  `initialize`, `initialized` and `didOpen` the first time and after
   *  the worker was replaced. Answers whether there is a server.
   *  () -> Promise<Bool> */
  async session() {
    if (!this.available) return false;
    if (this.runtime.isReady && this.generation === this.runtime.generation) return true;
    if (!this.opening) {
      this.opening = this.open().finally(() => { this.opening = null; });
    }
    return this.opening;
  }

  async open() {
    const id = this.nextId++;
    const answer = await this.runtime.lsp({
      jsonrpc: "2.0", id, method: "initialize",
      params: {
        processId: null, rootUri: null, workspaceFolders: null,
        clientInfo: { name: "Pyking playground" },
        capabilities: {
          textDocument: {
            hover: { contentFormat: ["markdown", "plaintext"] },
            completion: { completionItem: { snippetSupport: false } },
            signatureHelp: { signatureInformation: { parameterInformation: { labelOffsetSupport: true } } },
            rename: { prepareSupport: true },
            foldingRange: {},
            semanticTokens: { requests: { full: true }, formats: ["relative"] },
            codeAction: { codeActionLiteralSupport: { codeActionKind: { valueSet: ["quickfix"] } } },
            documentSymbol: { hierarchicalDocumentSymbolSupport: true },
            publishDiagnostics: {},
            synchronization: { didSave: true },
          },
        },
      },
    });
    if (answer === null) {
      this.available = false;
      return false;
    }
    const generation = this.runtime.generation;
    this.capabilities = this.handle(answer, id)?.capabilities ?? {};
    await this.notify("initialized", {});
    const opened = this.version;
    await this.notify("textDocument/didOpen", {
      textDocument: {
        uri: this.uri, languageId: "pyking", version: opened,
        text: this.model.getValue(),
      },
    });
    this.generation = generation;
    // Typed while the document was being opened: not sent by `changed`.
    if (this.version !== opened) {
      await this.notify("textDocument/didChange", {
        textDocument: { uri: this.uri, version: this.version },
        contentChanges: [{ text: this.model.getValue() }],
      });
    }
    this.scheduleIdle();
    return true;
  }

  /** Sends a request and answers its result, or null where it failed or
   *  the worker went away. String -> Object -> Promise<Any?> */
  async request(method, params) {
    if (!(await this.session())) return null;
    const id = this.nextId++;
    try {
      const answer = await this.runtime.lsp({ jsonrpc: "2.0", id, method, params });
      return this.handle(answer, id);
    } catch {
      return null;
    }
  }

  /** Sends a notification, and handles what the server sends back.
   *  String -> Object -> Promise<()> */
  async notify(method, params) {
    try {
      this.handle(await this.runtime.lsp({ jsonrpc: "2.0", method, params }));
    } catch {
      /* the worker went away; the next message opens the document again */
    }
  }

  /** Handles what the server sent: its notifications are acted on, its
   *  requests answered with null, and the result of request `id`, if it
   *  is among them, answered. [Object]? -> Int? -> Any? */
  handle(messages, id = null) {
    let result = null;
    for (const message of messages || []) {
      if (message.method === "textDocument/publishDiagnostics") {
        this.diagnostics(message.params);
      } else if (message.method !== undefined && message.id !== undefined) {
        this.runtime.lsp({ jsonrpc: "2.0", id: message.id, result: null }).catch(() => {});
      } else if (id !== null && message.id === id) {
        result = message.error ? null : (message.result ?? null);
      }
    }
    return result;
  }

  // -- the document -----------------------------------------------------

  /** The source changed: the whole text goes to the server, and the
   *  diagnostics are asked for once typing pauses. () -> () */
  changed() {
    this.version += 1;
    if (this.generation !== null && this.generation === this.runtime.generation) {
      this.notify("textDocument/didChange", {
        textDocument: { uri: this.uri, version: this.version },
        contentChanges: [{ text: this.model.getValue() }],
      });
    }
    this.scheduleIdle();
  }

  scheduleIdle() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.idle(), DIAGNOSTICS_DELAY);
  }

  async idle() {
    if (!(await this.session())) return;
    try {
      this.handle(await this.runtime.lspIdle());
    } catch {
      /* the worker went away */
    }
  }

  /** Turns a document's diagnostics into markers under the source.
   *  {uri, diagnostics} -> () */
  diagnostics({ uri, diagnostics }) {
    if (uri !== this.uri) return;
    const { MarkerSeverity } = this.monaco;
    const severity = [null, MarkerSeverity.Error, MarkerSeverity.Warning,
                      MarkerSeverity.Info, MarkerSeverity.Hint];
    this.monaco.editor.setModelMarkers(this.model, MARKER_OWNER, diagnostics.map((d) => ({
      ...this.range(d.range),
      severity: severity[d.severity ?? 1] ?? MarkerSeverity.Error,
      message: d.message,
      source: d.source,
      code: d.code === undefined ? undefined : String(d.code),
    })));
  }

  // -- the providers ----------------------------------------------------

  position(position) {
    return {
      textDocument: { uri: this.uri },
      position: { line: position.lineNumber - 1, character: position.column - 1 },
    };
  }

  /** An LSP range as Monaco's: lines from 1, columns from 1 in UTF-16
   *  code units, as LSP counts them from 0. */
  range(range) {
    return {
      startLineNumber: range.start.line + 1, startColumn: range.start.character + 1,
      endLineNumber: range.end.line + 1, endColumn: range.end.character + 1,
    };
  }

  async hover(position) {
    const result = await this.request("textDocument/hover", this.position(position));
    if (!result || !result.contents) return null;
    const text = (c) => (typeof c === "string" ? c
      : c.language ? "```" + c.language + "\n" + c.value + "\n```" : c.value);
    const contents = (Array.isArray(result.contents) ? result.contents : [result.contents])
      .map((c) => ({ value: text(c) }))
      .filter((c) => c.value);
    if (!contents.length) return null;
    return result.range ? { contents, range: this.range(result.range) } : { contents };
  }

  async definition(position) {
    const result = await this.request("textDocument/definition", this.position(position));
    if (!result) return null;
    const locations = (Array.isArray(result) ? result : [result]).map((l) => (
      l.targetUri ? { uri: l.targetUri, range: l.targetSelectionRange ?? l.targetRange }
                  : l));
    const answer = [];
    for (const location of locations) {
      const uri = this.monaco.Uri.parse(location.uri);
      if (location.uri !== this.uri) await this.foreign(uri);
      answer.push({ uri, range: this.range(location.range) });
    }
    return answer;
  }

  /** A model for a document the definition is in, other than the source:
   *  a standard library file, fetched from where the page serves lib/, so
   *  Peek Definition can show it. Nothing is made for any other.
   *  Uri -> Promise<()> */
  async foreign(uri) {
    if (this.monaco.editor.getModel(uri)) return;
    const path = libraryPath(uri.toString());
    if (!path || !this.libURL) return;
    try {
      const response = await fetch(this.libURL + path);
      if (!response.ok || this.monaco.editor.getModel(uri)) return;
      this.monaco.editor.createModel(await response.text(), "pyking", uri);
    } catch {
      /* the definition is still reported, without a preview */
    }
  }

  async symbols() {
    const result = await this.request("textDocument/documentSymbol",
                                      { textDocument: { uri: this.uri } });
    if (!result) return null;
    const convert = (s) => {
      const range = this.range(s.range ?? s.location.range);
      return {
        name: s.name, detail: s.detail ?? "", kind: Math.max(0, (s.kind ?? 13) - 1),
        tags: s.tags ?? [], range,
        selectionRange: s.selectionRange ? this.range(s.selectionRange) : range,
        children: (s.children ?? []).map(convert),
      };
    };
    return result.map(convert);
  }

  /** The signatures of the call the position is inside, as Monaco shows
   *  them. Position -> Promise<Object?> */
  async signatureHelp(position) {
    const result = await this.request("textDocument/signatureHelp", this.position(position));
    if (!result || !result.signatures?.length) return null;
    const text = (d) => (d === undefined ? undefined
      : typeof d === "string" ? d : { value: d.value });
    return {
      value: {
        signatures: result.signatures.map((s) => ({
          label: s.label,
          documentation: text(s.documentation),
          parameters: (s.parameters ?? []).map((p) => ({
            label: p.label, documentation: text(p.documentation),
          })),
        })),
        activeSignature: result.activeSignature ?? 0,
        activeParameter: result.activeParameter ?? 0,
      },
      dispose: () => {},
    };
  }

  /** Locations as Monaco's, each in the document or in a model made for
   *  a library file. [Object] -> Promise<[Object]> */
  async locations(result) {
    const answer = [];
    for (const location of result || []) {
      const uri = this.monaco.Uri.parse(location.uri);
      if (location.uri !== this.uri) await this.foreign(uri);
      answer.push({ uri, range: this.range(location.range) });
    }
    return answer;
  }

  async references(position, context) {
    const result = await this.request("textDocument/references", {
      ...this.position(position),
      context: { includeDeclaration: context?.includeDeclaration ?? true },
    });
    return this.locations(result);
  }

  async highlights(position) {
    const result = await this.request("textDocument/documentHighlight", this.position(position));
    if (!result) return null;
    const kinds = this.monaco.languages.DocumentHighlightKind;
    return result.map((h) => ({
      range: this.range(h.range),
      kind: h.kind === 3 ? kinds.Write : h.kind === 2 ? kinds.Read : kinds.Text,
    }));
  }

  /** Where a rename starts, or why there is none. Position -> Promise<Object> */
  async prepareRename(position) {
    if (!(await this.session())) return { rejectReason: "no language server" };
    const id = this.nextId++;
    const answer = await this.runtime.lsp({
      jsonrpc: "2.0", id, method: "textDocument/prepareRename", params: this.position(position),
    });
    const reply = (answer || []).find((m) => m.id === id);
    if (!reply || reply.error) return { range: undefined, text: "", rejectReason: reply?.error?.message ?? "cannot rename this" };
    return { range: this.range(reply.result.range), text: reply.result.placeholder };
  }

  /** The edits a rename makes, or why it is refused.
   *  Position -> String -> Promise<Object> */
  async rename(position, newName) {
    if (!(await this.session())) return { edits: [], rejectReason: "no language server" };
    const id = this.nextId++;
    const answer = await this.runtime.lsp({
      jsonrpc: "2.0", id, method: "textDocument/rename",
      params: { ...this.position(position), newName },
    });
    const reply = (answer || []).find((m) => m.id === id);
    if (!reply || reply.error) return { edits: [], rejectReason: reply?.error?.message ?? "cannot rename this" };
    return this.workspaceEdit(reply.result);
  }

  /** A WorkspaceEdit as Monaco's. Object -> Object */
  workspaceEdit(edit) {
    const edits = [];
    for (const [uri, list] of Object.entries(edit?.changes ?? {})) {
      for (const e of list) {
        edits.push({
          resource: this.monaco.Uri.parse(uri),
          textEdit: { range: this.range(e.range), text: e.newText },
          versionId: undefined,
        });
      }
    }
    return { edits };
  }

  async folding() {
    const result = await this.request("textDocument/foldingRange", { textDocument: { uri: this.uri } });
    if (!result) return null;
    const kinds = this.monaco.languages.FoldingRangeKind;
    return result.map((r) => ({
      start: r.startLine + 1,
      end: r.endLine + 1,
      kind: r.kind === "comment" ? kinds.Comment : r.kind === "imports" ? kinds.Imports : undefined,
    }));
  }

  async semanticTokens() {
    const result = await this.request("textDocument/semanticTokens/full", { textDocument: { uri: this.uri } });
    if (!result) return null;
    return { data: new Uint32Array(result.data ?? []), resultId: undefined };
  }

  /** The quick fixes for what is wrong where the cursor or selection is.
   *  Range -> Promise<Object?> */
  async codeActions(range) {
    const result = await this.request("textDocument/codeAction", {
      textDocument: { uri: this.uri },
      range: {
        start: { line: range.startLineNumber - 1, character: range.startColumn - 1 },
        end: { line: range.endLineNumber - 1, character: range.endColumn - 1 },
      },
      context: { diagnostics: [] },
    });
    if (!result) return null;
    return {
      actions: result.map((a) => ({
        title: a.title,
        kind: a.kind,
        isPreferred: !!a.isPreferred,
        edit: this.workspaceEdit(a.edit),
      })),
      dispose: () => {},
    };
  }

  async completion(position) {
    const result = await this.request("textDocument/completion", this.position(position));
    if (!result) return { suggestions: [] };
    const items = Array.isArray(result) ? result : (result.items ?? []);
    const word = this.model.getWordUntilPosition(position);
    const range = {
      startLineNumber: position.lineNumber, startColumn: word.startColumn,
      endLineNumber: position.lineNumber, endColumn: word.endColumn,
    };
    const kinds = this.monaco.languages.CompletionItemKind;
    return {
      incomplete: !Array.isArray(result) && !!result.isIncomplete,
      suggestions: items.map((item) => ({
        label: item.label,
        kind: kinds[COMPLETION_KINDS[item.kind] ?? "Text"] ?? kinds.Text,
        detail: item.detail,
        documentation: typeof item.documentation === "string"
          ? item.documentation
          : item.documentation ? { value: item.documentation.value } : undefined,
        insertText: item.textEdit?.newText ?? item.insertText ?? item.label,
        range: (item.textEdit?.range ?? item.textEdit?.replace)
          ? this.range(item.textEdit.range ?? item.textEdit.replace) : range,
        sortText: item.sortText,
        filterText: item.filterText,
      })),
    };
  }
}
