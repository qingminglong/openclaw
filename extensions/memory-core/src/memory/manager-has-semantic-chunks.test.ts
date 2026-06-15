// Tests for hasSemanticChunks() fallback in MemoryIndexManager.status() storeAvailable.
// The production change at manager.ts:1152:
//   storeAvailable: this.vector.available ?? (this.hasSemanticChunks() || undefined),
// allows an existing semantic index to report ready without probing embeddings.
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { OpenClawConfig } from "openclaw/plugin-sdk/memory-core-host-engine-foundation";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { closeAllMemorySearchManagers, getMemorySearchManager } from "./index.js";
import type { MemoryIndexManager } from "./manager.js";
import "./test-runtime-mocks.js";

const createEmbeddingProviderMock = vi.hoisted(() =>
  vi.fn(async () => ({
    requestedProvider: "auto",
    provider: null,
    providerUnavailableReason: "No embeddings provider available.",
  })),
);

vi.mock("./embeddings.js", () => ({
  createEmbeddingProvider: createEmbeddingProviderMock,
  resolveEmbeddingProviderAdapterId: (providerId: string) => providerId,
  resolveEmbeddingProviderAdapterTransport: (providerId: string) =>
    providerId === "local" ? "local" : "remote",
  resolveEmbeddingProviderIndexIdentity: () => undefined,
  resolveEmbeddingProviderFallbackModel: () => "fts-only",
}));

type Manager = MemoryIndexManager & { vector: { available: boolean | null } };

describe("hasSemanticChunks storeAvailable fallback", () => {
  let fixtureRoot = "";
  let caseId = 0;

  beforeAll(async () => {
    fixtureRoot = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-semantic-test-"));
  });

  afterEach(async () => {
    await closeAllMemorySearchManagers();
  });

  afterAll(async () => {
    await closeAllMemorySearchManagers();
    if (fixtureRoot) {
      await fs.rm(fixtureRoot, { recursive: true, force: true });
    }
  });

  async function createSemanticChunkManager(): Promise<Manager> {
    const workspaceDir = path.join(fixtureRoot, `case-${caseId++}`);
    await fs.mkdir(path.join(workspaceDir, "memory"), { recursive: true });
    await fs.writeFile(path.join(workspaceDir, "MEMORY.md"), "test content");
    const indexPath = path.join(workspaceDir, "index.sqlite");

    // Seed DB with semantic chunk BEFORE manager opens it
    const seedDb = new DatabaseSync(indexPath);
    seedDb.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS chunks (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'memory',
        start_line INTEGER NOT NULL,
        end_line INTEGER NOT NULL,
        hash TEXT NOT NULL,
        model TEXT NOT NULL,
        text TEXT NOT NULL,
        embedding TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
    `);
    seedDb
      .prepare(
        `INSERT INTO chunks (id, path, source, start_line, end_line, hash, model, text, embedding, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run("c1", "MEMORY.md", "memory", 1, 3, "h1", "gemini-embed", "note", "[]", Date.now());
    seedDb.close();

    const cfg = {
      memory: { backend: "builtin" },
      agents: {
        defaults: {
          workspace: workspaceDir,
          memorySearch: {
            provider: "auto",
            model: "",
            store: { path: indexPath, vector: { enabled: true } },
            cache: { enabled: false },
            sync: { watch: false, onSessionStart: false, onSearch: false },
          },
        },
        list: [{ id: "main", default: true }],
      },
    } as OpenClawConfig;

    const result = await getMemorySearchManager({ cfg, agentId: "main" });
    if (!result.manager) throw new Error(result.error ?? "manager missing");
    return result.manager as unknown as Manager;
  }

  async function createFtsOnlyManager(): Promise<Manager> {
    const workspaceDir = path.join(fixtureRoot, `case-${caseId++}`);
    await fs.mkdir(path.join(workspaceDir, "memory"), { recursive: true });
    await fs.writeFile(path.join(workspaceDir, "MEMORY.md"), "test content");
    const indexPath = path.join(workspaceDir, "index.sqlite");

    // Seed DB with fts-only chunk
    const seedDb = new DatabaseSync(indexPath);
    seedDb.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS chunks (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'memory',
        start_line INTEGER NOT NULL,
        end_line INTEGER NOT NULL,
        hash TEXT NOT NULL,
        model TEXT NOT NULL,
        text TEXT NOT NULL,
        embedding TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
    `);
    seedDb
      .prepare(
        `INSERT INTO chunks (id, path, source, start_line, end_line, hash, model, text, embedding, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run("c1", "MEMORY.md", "memory", 1, 3, "h1", "fts-only", "note", "[]", Date.now());
    seedDb.close();

    const cfg = {
      memory: { backend: "builtin" },
      agents: {
        defaults: {
          workspace: workspaceDir,
          memorySearch: {
            provider: "none",
            model: "",
            store: { path: indexPath, vector: { enabled: false } },
            cache: { enabled: false },
            sync: { watch: false, onSessionStart: false, onSearch: false },
          },
        },
        list: [{ id: "main", default: true }],
      },
    } as OpenClawConfig;

    const result = await getMemorySearchManager({ cfg, agentId: "main" });
    if (!result.manager) throw new Error(result.error ?? "manager missing");
    return result.manager as unknown as Manager;
  }

  it("reports storeAvailable as true when semantic chunks exist and vector.available is null", async () => {
    const manager = await createSemanticChunkManager();
    // Reset vector.available to null so hasSemanticChunks() fallback fires
    manager.vector.available = null;
    const status = manager.status();
    expect(status.vector?.storeAvailable).toBe(true);
    await manager.close?.();
  });

  it("reports storeAvailable as undefined when only fts-only chunks exist and vector.available is null", async () => {
    const manager = await createFtsOnlyManager();
    manager.vector.available = null;
    const status = manager.status();
    expect(status.vector?.storeAvailable).toBeUndefined();
    await manager.close?.();
  });
});
