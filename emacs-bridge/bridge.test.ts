import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, it } from "node:test";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import {
  bridgeDir,
  bridgeKey,
  commandsOf,
  decodeEvalOutput,
  lastAssistantText,
  maxRequestBytes,
  parseRequest,
  showTarget,
} from "./bridge.ts";

describe("parseRequest", () => {
  it("defaults a prompt to followUp", () => {
    assert.deepEqual(parseRequest('{"type":"prompt","text":"hi"}'), {
      type: "prompt",
      text: "hi",
      deliverAs: "followUp",
    });
  });

  it("keeps steer", () => {
    assert.deepEqual(parseRequest('{"type":"prompt","text":"hi","deliverAs":"steer"}'), {
      type: "prompt",
      text: "hi",
      deliverAs: "steer",
    });
  });

  for (const type of ["abort", "new", "last", "commands"]) {
    it(`accepts ${type}`, () => {
      assert.deepEqual(parseRequest(JSON.stringify({ type })), { type });
    });
  }

  const rejected: [string, string, RegExp][] = [
    ["broken JSON", "{", /not valid JSON/],
    ["an array", "[]", /JSON object/],
    ["null", "null", /JSON object/],
    ["an unknown type", '{"type":"shell"}', /unknown request type/],
    ["a missing text", '{"type":"prompt"}', /non-empty text/],
    ["a blank text", '{"type":"prompt","text":"  "}', /non-empty text/],
    ["a non-string text", '{"type":"prompt","text":1}', /non-empty text/],
    ["a bad deliverAs", '{"type":"prompt","text":"x","deliverAs":"nextTurn"}', /deliverAs/],
    ["an extra prompt field", '{"type":"prompt","text":"x","cmd":"rm"}', /unknown fields: cmd/],
    ["an extra abort field", '{"type":"abort","now":true}', /unknown fields: now/],
    ["an extra last field", '{"type":"last","lines":3}', /unknown fields: lines/],
    ["an extra commands field", '{"type":"commands","all":true}', /unknown fields: all/],
  ];
  for (const [what, line, error] of rejected) {
    it(`rejects ${what}`, () => {
      assert.throws(() => parseRequest(line), error);
    });
  }

  it("rejects a request over the size limit", () => {
    const text = "x".repeat(maxRequestBytes);
    assert.throws(() => parseRequest(JSON.stringify({ type: "prompt", text })), /exceeds/);
  });
});

describe("bridgeKey", () => {
  it("matches the key Emacs derives for the same directory", () => {
    assert.equal(bridgeKey("/tmp/pi-test-\u00f6"), "60a925c15103ba01df3d05d29ade3004c905cd7e");
  });
});

describe("bridgeDir", () => {
  it("prefers XDG_RUNTIME_DIR", () => {
    assert.equal(
      bridgeDir({ XDG_RUNTIME_DIR: "/run/user/1", XDG_CACHE_HOME: "/x/cache" }),
      "/run/user/1/pi/emacs",
    );
  });

  it("follows XDG_CACHE_HOME without a runtime directory", () => {
    assert.equal(bridgeDir({ XDG_CACHE_HOME: "/x/cache" }), "/x/cache/pi/emacs");
  });

  it("falls back to ~/.cache", () => {
    assert.match(bridgeDir({}), /\/\.cache\/pi\/emacs$/);
  });

  for (const value of ["", "relative/dir"]) {
    it(`ignores ${JSON.stringify(value)} like Emacs`, () => {
      assert.equal(bridgeDir({ XDG_RUNTIME_DIR: value, XDG_CACHE_HOME: value }), bridgeDir({}));
    });
  }
});

describe("lastAssistantText", () => {
  const entries = (messages: object[]): SessionEntry[] =>
    messages.map((message) => ({
      type: "message",
      id: "id",
      parentId: null,
      timestamp: "",
      message,
    })) as SessionEntry[];
  const assistant = (content: object[], stopReason = "end_turn") => ({
    role: "assistant",
    content,
    stopReason,
  });
  const text = (value: string) => ({ type: "text", text: value });
  const call = () => ({ type: "tool_call" });

  it("returns the text of the last assistant message", () => {
    const branch = entries([
      { role: "user", content: [text("hi")] },
      assistant([text("  one  ")]),
      { role: "tool_result", content: [text("ok")] },
    ]);
    assert.equal(lastAssistantText(branch), "one");
  });

  it("joins text blocks and skips thinking and tool calls", () => {
    const branch = entries([
      assistant([{ type: "thinking", thinking: "h" }, text("a"), call(), text("b")]),
    ]);
    assert.equal(lastAssistantText(branch), "ab");
  });

  it("skips an aborted assistant message without content, not one with text", () => {
    const branch = entries([assistant([text("kept")]), assistant([], "aborted")]);
    assert.equal(lastAssistantText(branch), "kept");
  });

  it("returns undefined when no assistant message has text", () => {
    const branch = entries([assistant([call()]), { role: "user", content: [text("hi")] }]);
    assert.equal(lastAssistantText(branch), undefined);
  });

  it("returns undefined for an empty branch", () => {
    assert.equal(lastAssistantText([]), undefined);
  });
});

describe("commandsOf", () => {
  it("keeps name and description and drops everything else", () => {
    assert.deepEqual(
      commandsOf([{ name: "prove", description: "Run tests" }, { name: "skill:debugging" }]),
      [{ name: "prove", description: "Run tests" }, { name: "skill:debugging" }],
    );
  });
});

describe("showTarget", () => {
  it("resolves a relative path inside the project", () => {
    assert.deepEqual(showTarget("/p", "src/a.ts", 3, 7), {
      file: "/p/src/a.ts",
      line: 3,
      column: 7,
    });
  });

  it("accepts an absolute path inside the project and defaults the position", () => {
    assert.deepEqual(showTarget("/p", "/p/a.ts"), { file: "/p/a.ts", line: 1, column: 1 });
  });

  it("drops a leading @", () => {
    assert.deepEqual(showTarget("/p", "@src/a.ts", 2), { file: "/p/src/a.ts", line: 2, column: 1 });
  });

  it("accepts a name that only starts with two dots", () => {
    assert.deepEqual(showTarget("/p", "..a"), { file: "/p/..a", line: 1, column: 1 });
  });

  for (const path of ["../etc/passwd", "/etc/passwd", "src/../../x"]) {
    it(`rejects ${path}`, () => {
      assert.throws(() => showTarget("/p", path), /outside/);
    });
  }

  for (const [line, column] of [
    [0, 1],
    [1, 0],
    [1.5, 1],
  ]) {
    it(`rejects line ${line} column ${column}`, () => {
      assert.throws(() => showTarget("/p", "a", line, column), /integers/);
    });
  }

  describe("with symlinks", () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "bridge-test-")));
    const project = join(root, "project");
    const link = join(root, "link");
    mkdirSync(join(project, "src"), { recursive: true });
    writeFileSync(join(project, "src", "a.ts"), "");
    writeFileSync(join(root, "secret"), "");
    symlinkSync(project, link);
    symlinkSync(join(root, "secret"), join(project, "escape"));
    after(() => rmSync(root, { recursive: true, force: true }));

    it("accepts a path through the symlinked cwd", () => {
      assert.deepEqual(showTarget(project, join(link, "src", "a.ts")), {
        file: join(project, "src", "a.ts"),
        line: 1,
        column: 1,
      });
    });

    it("accepts a new file through the symlinked cwd", () => {
      assert.deepEqual(showTarget(project, join(link, "src", "new.ts")), {
        file: join(project, "src", "new.ts"),
        line: 1,
        column: 1,
      });
    });

    it("rejects a link that leads out of the project", () => {
      assert.throws(() => showTarget(project, "escape"), /outside/);
    });
  });
});

describe("decodeEvalOutput", () => {
  it("decodes the base64 JSON Emacs prints", () => {
    const json = JSON.stringify({ file: "/p/\u00e4.ts" });
    const encoded = Buffer.from(json, "utf8").toString("base64");
    assert.deepEqual(decodeEvalOutput(`"${encoded}"\n`), { file: "/p/\u00e4.ts" });
  });

  it("rejects anything else", () => {
    assert.throws(
      () => decodeEvalOutput("*ERROR*: void-function\n"),
      /unexpected emacsclient output/,
    );
  });
});
