// The Pyking extension for VS Code and Cursor: starts the Pyking
// language server, `pyk lsp --stdio`, for every Pyking document, and
// the Pyking debug adapter, `pyk dap`, for a `pyking` debug session.
// The language, its highlighting, its editing rules and the debugger's
// launch configuration are declared in package.json. See README.md.
//
// Functions:
//   activate(context) -- starts the server; registers the restart
//     command and the debugger.
//   deactivate() -- stops the server.

"use strict";

const vscode = require("vscode");
const { execFile } = require("child_process");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

// The settings the server reads, as sent in initializationOptions.
// () -> {libPath: [String], diagnostics: String}
function serverSettings() {
  const config = vscode.workspace.getConfiguration("pyking");
  return {
    libPath: config.get("libPath", []),
    diagnostics: config.get("diagnostics", "change"),
  };
}

// Whether `command --version` runs, as a promise of an error message or
// null. String -> Promise(String?)
function probe(command) {
  return new Promise((resolve) => {
    execFile(command, ["--version"], { timeout: 10000 }, (error) => {
      if (!error) resolve(null);
      else if (error.code === "ENOENT") resolve("was not found");
      else resolve(`could not be run (${error.message})`);
    });
  });
}

// Starts the language server, or shows one error naming the setting
// where its executable cannot be run. () -> Promise(())
async function start() {
  const config = vscode.workspace.getConfiguration("pyking");
  const command = config.get("server.path") || "pyk";
  const args = config.get("server.args", ["lsp"]);
  const problem = await probe(command);
  if (problem) {
    vscode.window.showErrorMessage(
      `Pyking: the language server "${command}" ${problem}. ` +
        `Set "pyking.server.path" to the pyk executable.`,
    );
    return;
  }
  client = new LanguageClient(
    "pyking",
    "Pyking",
    { command, args, transport: TransportKind.stdio },
    {
      documentSelector: [{ language: "pyking" }],
      initializationOptions: serverSettings(),
      synchronize: { configurationSection: "pyking" },
    },
  );
  try {
    await client.start();
  } catch (error) {
    client = undefined;
    vscode.window.showErrorMessage(
      `Pyking: the language server "${command} ${args.join(" ")} --stdio" ` +
        `failed to start (${error.message}). Check "pyking.server.path".`,
    );
  }
}

// How a `pyking` debug session reaches its adapter: `pyk dap`, from the
// same executable as the language server.
const debugAdapter = {
  createDebugAdapterDescriptor() {
    const config = vscode.workspace.getConfiguration("pyking");
    const command = config.get("server.path") || "pyk";
    return new vscode.DebugAdapterExecutable(command, config.get("debugger.args", ["dap"]));
  },
};

// What F5 debugs where no launch.json says: the Pyking file in the
// editor. Answers the configuration, or undefined to cancel.
// DebugConfiguration -> DebugConfiguration?
const debugConfigurations = {
  resolveDebugConfiguration(folder, config) {
    if (!config.type && !config.request && !config.name) {
      const editor = vscode.window.activeTextEditor;
      if (!editor || editor.document.languageId !== "pyking") {
        vscode.window.showInformationMessage("Pyking: open a .pyk file to debug it.");
        return undefined;
      }
      return { type: "pyking", request: "launch", name: "Debug the current Pyking file",
               program: editor.document.uri.fsPath };
    }
    if (!config.program) {
      vscode.window.showInformationMessage("Pyking: the launch configuration names no program.");
      return undefined;
    }
    return config;
  },
};

// Stops the language server, if one is running. () -> Promise(())
async function stop() {
  if (client) {
    const running = client;
    client = undefined;
    await running.stop();
  }
}

// Starts the server and restarts it when the command changes.
// ExtensionContext -> Promise(())
async function activate(context) {
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("pyking", debugAdapter),
    vscode.debug.registerDebugConfigurationProvider("pyking", debugConfigurations),
    vscode.commands.registerCommand("pyking.restartServer", async () => {
      await stop();
      await start();
    }),
    vscode.workspace.onDidChangeConfiguration(async (event) => {
      if (event.affectsConfiguration("pyking.server")) {
        await stop();
        await start();
      }
    }),
  );
  await start();
}

// Stops the server. () -> Promise(())
function deactivate() {
  return stop();
}

module.exports = { activate, deactivate };
