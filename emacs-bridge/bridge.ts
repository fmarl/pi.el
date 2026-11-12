import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { SessionEntry, SlashCommandInfo } from "@earendil-works/pi-coding-agent";

export const maxRequestBytes = 64 * 1024;

export type DeliverAs = "steer" | "followUp";

export type Request =
  | { type: "prompt"; text: string; deliverAs: DeliverAs }
  | { type: "abort" }
  | { type: "new" }
  | { type: "last" }
  | { type: "commands" };

export type Target = { file: string; line: number; column: number };

export function bridgeDir(env: NodeJS.ProcessEnv = process.env): string {
  // Must match pi-bridge-directory in pi.el, which ignores relative directories.
  const candidates = [env.XDG_RUNTIME_DIR, env.XDG_CACHE_HOME];
  const base = candidates.find((dir) => dir !== undefined && isAbsolute(dir));

  return join(base ?? join(homedir(), ".cache"), "pi", "emacs");
}

export function bridgeKey(realCwd: string): string {
  return createHash("sha1").update(realCwd, "utf8").digest("hex");
}

export function parseRequest(line: string): Request {
  if (Buffer.byteLength(line, "utf8") > maxRequestBytes) {
    throw new Error(`request exceeds ${maxRequestBytes} bytes`);
  }

  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    throw new Error("request is not valid JSON");
  }

  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("request must be a JSON object");
  }

  const { type, ...fields } = value as Record<string, unknown>;

  if (type === "prompt") {
    const { text, deliverAs = "followUp", ...unknown } = fields;
    rejectUnknown(unknown);

    if (typeof text !== "string" || text.trim() === "") {
      throw new Error("prompt needs a non-empty text");
    }
    if (deliverAs !== "steer" && deliverAs !== "followUp") {
      throw new Error('deliverAs must be "steer" or "followUp"');
    }

    return { type, text, deliverAs };
  }

  if (type === "abort" || type === "new" || type === "last" || type === "commands") {
    rejectUnknown(fields);
    return { type };
  }

  throw new Error(`unknown request type: ${JSON.stringify(type)}`);
}

function rejectUnknown(fields: Record<string, unknown>): void {
  const names = Object.keys(fields);

  if (names.length > 0) {
    throw new Error(`unknown fields: ${names.join(", ")}`);
  }
}

export function lastAssistantText(entries: readonly SessionEntry[]): string | undefined {
  // Mirrors AgentSession.getLastAssistantText.
  for (const entry of entries.toReversed()) {
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;

    const message = entry.message;
    if (message.stopReason === "aborted" && message.content.length === 0) continue;

    const texts = message.content.flatMap((content) =>
      content.type === "text" ? [content.text] : [],
    );
    return texts.join("").trim() || undefined;
  }

  return undefined;
}

export function commandsOf(
  commands: readonly Pick<SlashCommandInfo, "name" | "description">[],
): { name: string; description?: string }[] {
  return commands.map(({ name, description }) =>
    description === undefined || description === "" ? { name } : { name, description },
  );
}

function escapes(rel: string): boolean {
  return rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel);
}

function realPath(file: string): string {
  try {
    return realpathSync(file);
  } catch {
    // A file Pi is about to create has no real path yet, but its directory may.
  }

  try {
    return join(realpathSync(dirname(file)), basename(file));
  } catch {
    // Nor its directory; then the path as written is all there is.
  }

  return file;
}

export function insideFile(realCwd: string, path: string): string {
  // Pi may name the file through a symlinked cwd, or through a link leading out.
  const file = realPath(resolve(realCwd, path));

  if (escapes(relative(realCwd, file))) {
    throw new Error(`${path} is outside ${realCwd}`);
  }

  return file;
}

function checkPosition(line: number, column: number): void {
  const valid = (n: number) => Number.isInteger(n) && n >= 1;

  if (!valid(line) || !valid(column)) {
    throw new Error("line and column must be integers >= 1");
  }
}

export function showTarget(cwd: string, path: string, line = 1, column = 1): Target {
  // Some models write paths as @file, like the locations Emacs sends.
  const file = insideFile(cwd, path.replace(/^@/, ""));
  checkPosition(line, column);

  return { file, line, column };
}

export function decodeEvalOutput(stdout: string): unknown {
  const encoded = /^"([A-Za-z0-9+/=]*)"\s*$/.exec(stdout)?.[1];

  if (encoded === undefined) {
    throw new Error(`unexpected emacsclient output: ${stdout.slice(0, 200)}`);
  }

  return JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
}

export async function emacsclient(args: string[], signal?: AbortSignal): Promise<string> {
  const options = { signal, timeout: 10_000, maxBuffer: 1 << 20 };

  return new Promise((done, fail) => {
    execFile("emacsclient", args, options, (error, stdout, stderr) => {
      if (error) {
        fail(new Error(`emacsclient failed: ${(stderr || error.message).trim()}`));
      } else {
        done(stdout);
      }
    });
  });
}
