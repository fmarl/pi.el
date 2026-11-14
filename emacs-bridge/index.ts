import { chmodSync, mkdirSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { connect, createServer, type Server } from "node:net";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import {
  bridgeDir,
  bridgeKey,
  commandsOf,
  type DeliverAs,
  decodeEvalOutput,
  emacsclient,
  lastAssistantText,
  maxRequestBytes,
  parseRequest,
  type Request,
  showTarget,
} from "./bridge.ts";

type Status = { state: "busy" | "idle"; tool?: string; path?: string; aborted?: boolean };

type Bridge = { server: Server; socket: string; status: string; cwd: string };

type Reply = { ok: boolean; error?: string; data?: unknown };

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function errorCode(error: unknown): unknown {
  return error instanceof Error && "code" in error ? error.code : undefined;
}

async function listen(server: Server, path: string): Promise<void> {
  return new Promise((done, fail) => {
    server.once("error", fail);

    server.listen(path, () => {
      server.off("error", fail);
      done();
    });
  });
}

async function answers(path: string): Promise<boolean> {
  return new Promise((done) => {
    const probe = connect(path);

    probe.once("connect", () => {
      probe.destroy();
      done(true);
    });

    probe.once("error", () => done(false));
  });
}

export default function (pi: ExtensionAPI): void {
  let bridge: Bridge | undefined;

  function writeStatus(status: Status) {
    if (!bridge) return;

    const temporary = `${bridge.status}.tmp`;
    const content = `${JSON.stringify({ ...status, cwd: bridge.cwd })}\n`;

    try {
      writeFileSync(temporary, content, { mode: 0o600 });
      renameSync(temporary, bridge.status);
    } catch {
      // Only the mode line reads the status.
    }
  }

  function send(text: string, ctx: ExtensionContext, deliverAs: DeliverAs = "followUp") {
    const delivery = ctx.isIdle() ? {} : { deliverAs };

    pi.sendUserMessage(text, { expandPromptTemplates: true, ...delivery });
  }

  function handle(request: Request, ctx: ExtensionContext): unknown {
    switch (request.type) {
      case "prompt":
        send(request.text, ctx, request.deliverAs);
        return undefined;

      case "abort":
        ctx.abort();
        return undefined;

      case "new":
        if (!ctx.isIdle()) throw new Error("Pi is busy; abort first");
        send("/emacs-new", ctx);
        return undefined;

      case "last":
        return { text: lastAssistantText(ctx.sessionManager.getBranch()) ?? null };

      case "commands":
        return { commands: commandsOf(pi.getCommands()) };

      default:
        return request satisfies never;
    }
  }

  function reply(line: string, ctx: ExtensionContext): Reply {
    try {
      const data = handle(parseRequest(line), ctx);
      return data === undefined ? { ok: true } : { ok: true, data };
    } catch (error) {
      return { ok: false, error: errorText(error) };
    }
  }

  function serve(ctx: ExtensionContext): Server {
    return createServer((connection) => {
      let pending = "";

      connection.setEncoding("utf8");
      connection.setTimeout(5_000, () => connection.destroy());
      connection.on("error", () => connection.destroy());

      connection.on("data", (chunk: string) => {
        pending += chunk;

        const end = pending.indexOf("\n");
        const tooLong = Buffer.byteLength(pending, "utf8") > maxRequestBytes;
        if (end === -1 && !tooLong) return;

        connection.removeAllListeners("data");

        const line = end === -1 ? pending : pending.slice(0, end);
        connection.end(`${JSON.stringify(reply(line, ctx))}\n`);
      });
    });
  }

  async function open(ctx: ExtensionContext): Promise<Bridge> {
    const dir = bridgeDir();
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);

    const cwd = realpathSync(ctx.cwd);
    const key = bridgeKey(cwd);
    const socket = join(dir, `${key}.sock`);
    const server = serve(ctx);

    await listen(server, socket).catch(async (error: unknown) => {
      // A socket nobody answers on is left over from a Pi that crashed.
      if (errorCode(error) !== "EADDRINUSE" || (await answers(socket))) throw error;

      rmSync(socket, { force: true });
      await listen(server, socket);
    });

    chmodSync(socket, 0o600);

    return { server, socket, status: join(dir, `${key}.json`), cwd };
  }

  pi.on("session_start", async (_event, ctx) => {
    // `pi -p` must not take the directory from an interactive Pi.
    if (!ctx.hasUI) return;

    try {
      bridge = await open(ctx);
    } catch (error) {
      const inUse = errorCode(error) === "EADDRINUSE";
      const reason = inUse ? `another Pi serves ${ctx.cwd}` : errorText(error);

      ctx.ui.notify(`Emacs bridge inactive: ${reason}`, "warning");
      return;
    }

    writeStatus({ state: ctx.isIdle() ? "idle" : "busy" });
  });

  pi.on("session_shutdown", () => {
    if (!bridge) return;

    bridge.server.close();
    rmSync(bridge.socket, { force: true });
    rmSync(bridge.status, { force: true });

    bridge = undefined;
  });

  pi.on("agent_start", () => writeStatus({ state: "busy" }));

  pi.on("tool_execution_start", (event) => {
    const args = event.args as Record<string, unknown> | undefined;
    const path = typeof args?.path === "string" ? { path: args.path } : {};

    writeStatus({ state: "busy", tool: event.toolName, ...path });
  });

  pi.on("agent_settled", (event) => writeStatus({ state: "idle", aborted: event.aborted }));

  pi.registerCommand("emacs-new", {
    description: "Start a new session; Emacs sends this through the bridge",

    handler: async (_args, ctx) => {
      await ctx.newSession();
    },
  });

  pi.registerTool({
    name: "emacs_context",
    label: "Emacs context",

    description:
      "Returns what the user has open in Emacs: file, cursor line and column " +
      "of the selected window, the active region with its text, " +
      "the buffer's flymake diagnostics, the files in the other visible windows, " +
      "and, when the cursor is in a magit diff hunk, the file and line range it points at. " +
      "The region text is cut to 20000 bytes, with region.truncated set, " +
      "and the diagnostics to 50, with moreDiagnostics counting the rest; " +
      "read the file for the full text",

    promptSnippet: "Read the file, cursor, region and diagnostics the user has open in Emacs",

    promptGuidelines: [
      "Use emacs_context when the user refers to code they are looking at, " +
        "such as 'this', 'here' or 'the selection'.",
    ],

    parameters: Type.Object({}),

    async execute(_toolCallId, _params, signal) {
      const output = await emacsclient(["--eval", "(pi-context-json)"], signal);
      const context = decodeEvalOutput(output);

      return {
        content: [{ type: "text", text: JSON.stringify(context, null, 2) }],
        details: undefined,
      };
    },
  });

  pi.registerTool({
    name: "emacs_show",
    label: "Show in Emacs",
    description: "Opens a file of the current project in the user's Emacs at a line and column.",
    promptSnippet: "Open a project file in the user's Emacs at a line",

    promptGuidelines: [
      "Use emacs_show to point the user at a location in a file instead of quoting long code.",
    ],

    parameters: Type.Object({
      path: Type.String({
        description: "File path, relative to the working directory or absolute inside it",
      }),
      line: Type.Optional(Type.Integer({ minimum: 1 })),
      column: Type.Optional(Type.Integer({ minimum: 1 })),
    }),

    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const cwd = realpathSync(ctx.cwd);
      const { file, line, column } = showTarget(cwd, params.path, params.line, params.column);

      await emacsclient(["-n", `+${line}:${column}`, file], signal);

      return {
        content: [{ type: "text", text: `Opened ${file} at ${line}:${column}` }],
        details: undefined,
      };
    },
  });
}
