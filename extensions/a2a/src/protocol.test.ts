import { describe, expect, it } from "vitest";
import {
  extractA2aMessageText,
  resolveA2aRpcMethod,
  truncateA2aTaskHistory,
  type A2aTaskRecord,
} from "./protocol.js";

describe("A2A protocol message parts", () => {
  it("extracts structured data alongside text", () => {
    expect(extractA2aMessageText([{ text: "hello" }, { data: { count: 2, ready: true } }])).toBe(
      'hello\n{"count":2,"ready":true}',
    );
  });

  it("caps extracted UTF-8 text at 64 KiB without a leading BOM or split code point", () => {
    const text = extractA2aMessageText([{ text: "\uFEFF" + "🦞".repeat(20_000) }]);

    expect(text).toBeDefined();
    expect(Buffer.byteLength(text!)).toBeLessThanOrEqual(64 * 1024);
    expect(text).toContain("[message truncated at 65536 bytes]");
    expect(text).not.toContain("�");
    expect(text).not.toContain("\uFEFF");
  });
});

describe("A2A JSON-RPC request contracts", () => {
  it("does not resolve inherited Object methods", () => {
    expect(resolveA2aRpcMethod("constructor")).toBeUndefined();
  });
});

describe("A2A task history limits", () => {
  it("crops only the response copy", () => {
    const task = {
      id: "task-1",
      contextId: "context-1",
      status: { state: "TASK_STATE_COMPLETED", timestamp: "2026-01-01T00:00:00.000Z" },
      artifacts: [],
      history: [
        { messageId: "message-1", role: "ROLE_USER", parts: [{ text: "one" }] },
        { messageId: "message-2", role: "ROLE_AGENT", parts: [{ text: "two" }] },
        { messageId: "message-3", role: "ROLE_USER", parts: [{ text: "three" }] },
      ],
    } satisfies A2aTaskRecord;
    expect(truncateA2aTaskHistory(task, undefined).history).toEqual(task.history);
    expect(truncateA2aTaskHistory(task, 0).history).toEqual([]);
    expect(truncateA2aTaskHistory(task, 2).history).toEqual(task.history.slice(-2));
    expect(task.history).toHaveLength(3);
  });
});
