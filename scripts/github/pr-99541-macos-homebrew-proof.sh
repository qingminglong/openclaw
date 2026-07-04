#!/usr/bin/env bash
set -euo pipefail

target_dir="${1:?target checkout directory is required}"
target_sha="${2:?target sha is required}"

target_dir="$(cd "${target_dir}" && pwd)"
artifact_dir="${RUNNER_TEMP:-/tmp}/pr-99541-macos-homebrew-proof"
mkdir -p "${artifact_dir}"

summary_file="${artifact_dir}/summary.md"
proof_json="${artifact_dir}/proof.json"

log() {
  printf '::notice::%s\n' "$*"
  printf '%s\n' "$*" >> "${summary_file}"
}

run_step() {
  printf '+ %s\n' "$*" | tee -a "${summary_file}"
  "$@" 2>&1 | tee -a "${summary_file}"
}

cd "${target_dir}"

actual_sha="$(git rev-parse HEAD)"
if [[ "${actual_sha}" != "${target_sha}" ]]; then
  echo "Expected target SHA ${target_sha}, got ${actual_sha}" >&2
  exit 1
fi

: > "${summary_file}"
log "# PR #99541 macOS Homebrew proof"
log ""
log "- Target SHA: \`${target_sha}\`"
log "- Runner OS: \`${RUNNER_OS:-unknown}\`"
log "- Runner arch: \`$(uname -m)\`"
log ""

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This proof must run on macOS." >&2
  exit 1
fi

run_step sw_vers
run_step uname -a
run_step brew --version

if ! brew list --versions node >/dev/null 2>&1; then
  run_step brew install node
fi

brew_prefix="$(brew --prefix)"
node_prefix="$(brew --prefix node)"
node_cellar="$(brew --cellar node)"
stable_node="${brew_prefix}/opt/node/bin/node"
stable_node_bin="$(dirname "${stable_node}")"
export PATH="${stable_node_bin}:${PATH}"

if [[ ! -x "${stable_node}" ]]; then
  echo "Stable Homebrew Node symlink is missing or not executable: ${stable_node}" >&2
  exit 1
fi

real_stable_node="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${stable_node}")"
if [[ "${real_stable_node}" != "${node_cellar}"/*/bin/node ]]; then
  echo "Stable Node did not resolve into the Homebrew node Cellar: ${real_stable_node}" >&2
  exit 1
fi

current_version_dir="$(cd "$(dirname "${real_stable_node}")/.." && pwd)"
stale_version="openclaw-proof-99541-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
stale_version_dir="${node_cellar}/${stale_version}"
stale_node="${stale_version_dir}/bin/node"

rm -rf "${stale_version_dir}"
cp -a "${current_version_dir}" "${stale_version_dir}"

if [[ ! -x "${stale_node}" ]]; then
  echo "Failed to create executable stale Cellar Node path: ${stale_node}" >&2
  exit 1
fi

run_step "${stable_node}" -p 'JSON.stringify({execPath: process.execPath, argv0: process.argv0, version: process.version})'
run_step "${stale_node}" -p 'JSON.stringify({execPath: process.execPath, argv0: process.argv0, version: process.version})'

log ""
log "## Homebrew paths"
log ""
log "- Homebrew prefix: \`${brew_prefix}\`"
log "- Homebrew node prefix: \`${node_prefix}\`"
log "- Homebrew node Cellar: \`${node_cellar}\`"
log "- Stable Node path used for worker forks: \`${stable_node}\`"
log "- Stable Node resolves to: \`${real_stable_node}\`"
log "- Parent stale Cellar executable path: \`${stale_node}\`"
log ""

run_step "${stable_node}" --version
run_step "${stable_node_bin}/npm" --version
run_step "${stable_node_bin}/npm" install --no-save --no-package-lock --ignore-scripts --no-audit --no-fund tsx@4.22.3

cat > "${artifact_dir}/worker-child.mjs" <<'NODE'
import { appendFileSync, writeFileSync } from "node:fs";

const childRecord = process.env.OPENCLAW_PR_99541_CHILD_RECORD;
if (childRecord) {
  writeFileSync(
    childRecord,
    `${JSON.stringify({
      execPath: process.execPath,
      argv0: process.argv0,
      argv: process.argv,
      version: process.version,
      platform: process.platform,
      arch: process.arch,
    }, null, 2)}\n`,
  );
}

process.on("message", (message) => {
  if (process.env.OPENCLAW_PR_99541_CHILD_MESSAGES) {
    appendFileSync(
      process.env.OPENCLAW_PR_99541_CHILD_MESSAGES,
      `${JSON.stringify(message)}\n`,
    );
  }
  process.send?.({ id: message?.id, ok: true, value: [1, 2, 3] });
});
NODE

cat > "${artifact_dir}/parent-proof.mjs" <<'NODE'
import { fork } from "node:child_process";
import { access, readFile, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [repoDir, workerScript, stableNode, staleNode, proofJson] = process.argv.slice(2);
if (!repoDir || !workerScript || !stableNode || !staleNode || !proofJson) {
  throw new Error("usage: parent-proof.mjs <repoDir> <workerScript> <stableNode> <staleNode> <proofJson>");
}

const childRecord = path.join(path.dirname(proofJson), "child-record.json");
const childMessages = path.join(path.dirname(proofJson), "child-messages.jsonl");
process.env.OPENCLAW_PR_99541_CHILD_RECORD = childRecord;
process.env.OPENCLAW_PR_99541_CHILD_MESSAGES = childMessages;

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function exists(file) {
  try {
    await access(file, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

async function expectRawForkEnoent() {
  return await new Promise((resolve, reject) => {
    const child = fork(workerScript, [], {
      serialization: "json",
      stdio: ["ignore", "ignore", "ignore", "ipc"],
    });
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error("raw fork without execPath did not fail after stale execPath removal"));
    }, 5000);
    child.once("error", (err) => {
      clearTimeout(timeout);
      resolve({ message: err.message, code: err.code });
    });
    child.once("exit", (code, signal) => {
      clearTimeout(timeout);
      reject(new Error(`raw fork exited instead of reporting process error: code=${code} signal=${signal}`));
    });
  });
}

const before = {
  parentExecPath: process.execPath,
  parentArgv0: process.argv0,
  parentVersion: process.version,
  platform: process.platform,
  arch: process.arch,
  stableNode,
  staleNode,
};

assert(process.platform === "darwin", `expected darwin, got ${process.platform}`);
assert(process.execPath === staleNode, `parent execPath was ${process.execPath}, expected ${staleNode}`);
assert(await exists(stableNode), `stable Homebrew Node path is not executable: ${stableNode}`);
assert(await exists(staleNode), `stale Cellar Node path is not executable before removal: ${staleNode}`);

await rm(staleNode);
assert(!(await exists(staleNode)), `stale Cellar Node path still exists after removal: ${staleNode}`);
assert(await exists(stableNode), `stable Homebrew Node path stopped being executable: ${stableNode}`);

const rawForkError = await expectRawForkEnoent();
assert(
  rawForkError.code === "ENOENT" || rawForkError.message.includes("ENOENT"),
  `raw fork did not prove ENOENT from stale process.execPath: ${JSON.stringify(rawForkError)}`,
);

const moduleUrl = pathToFileURL(
  path.join(repoDir, "packages/memory-host-sdk/src/host/embeddings-worker.ts"),
).href;
const { createLocalEmbeddingWorkerProvider } = await import(moduleUrl);

const provider = await createLocalEmbeddingWorkerProvider(
  { config: {}, provider: "local", model: "", fallback: "none" },
  { workerScriptPath: workerScript },
);
const embedding = await provider.embedQuery("real macOS Homebrew stale Cellar proof");
await provider.close?.();

const child = JSON.parse(await readFile(childRecord, "utf8"));
assert(Array.isArray(embedding), "worker embedQuery did not return an array");
assert(await exists(stableNode), `stable Homebrew Node path is not executable after PR worker fork: ${stableNode}`);
assert(!(await exists(staleNode)), `stale Cellar Node path unexpectedly exists after PR worker fork: ${staleNode}`);

const proof = {
  before,
  removedStaleExecPath: staleNode,
  rawForkWithoutExecPath: rawForkError,
  prWorkerFork: {
    status: "success",
    embedding,
    child,
  },
  after: {
    stableNodeExecutable: await exists(stableNode),
    staleNodeExecutable: await exists(staleNode),
  },
};

await writeFile(proofJson, `${JSON.stringify(proof, null, 2)}\n`);
console.log(JSON.stringify(proof, null, 2));
NODE

set +e
"${stale_node}" --import tsx "${artifact_dir}/parent-proof.mjs" \
  "${target_dir}" \
  "${artifact_dir}/worker-child.mjs" \
  "${stable_node}" \
  "${stale_node}" \
  "${proof_json}" 2>&1 | tee -a "${summary_file}"
proof_status="${PIPESTATUS[0]}"
set -e

rm -rf "${stale_version_dir}"

if [[ "${proof_status}" != "0" ]]; then
  echo "macOS Homebrew proof failed." >&2
  exit "${proof_status}"
fi

log ""
log "## Result"
log ""
log "- Real macOS/Homebrew stale Cellar proof completed."
log "- Raw fork without explicit \`execPath\` failed after the stale Cellar executable was removed."
log "- The PR worker fork completed while the stale Cellar executable remained unavailable."

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "${summary_file}" >> "${GITHUB_STEP_SUMMARY}"
fi
