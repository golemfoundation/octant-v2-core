import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { exportRegistry } from "./export-registry.mjs";

const REGISTRY = "0x1111111111111111111111111111111111111111";
const BLOCK_HASH_A = `0x${"aa".repeat(32)}`;
const BLOCK_HASH_B = `0x${"bb".repeat(32)}`;
const MANIFEST_HASH = `0x${"cc".repeat(32)}`;

function registryFixtureRunner(blockHashes, calls) {
  return args => {
    calls.push(args);
    const command = args[0];

    if (command === "chain-id") return "1\n";
    if (command === "block" && args[2] === "--field" && args[3] === "number") return "123\n";
    if (command === "block" && args[2] === "--field" && args[3] === "hash") {
      return `${blockHashes.shift()}\n`;
    }

    if (command !== "call") throw new Error(`Unexpected cast command: ${args.join(" ")}`);
    switch (args[2]) {
      case "count()(uint256)":
        return "0\n";
      case "epoch()(uint64)":
        return "1\n";
      case "manifestHash()(bytes32)":
        return `${MANIFEST_HASH}\n`;
      case "releaseLabel()(string)":
        return '["1.3.0"]\n';
      case "API_VERSION()(string)":
        return '["1.0.0"]\n';
      case "getSuccessor()(address)":
        return "0x0000000000000000000000000000000000000000\n";
      default:
        throw new Error(`Unexpected registry call: ${args[2]}`);
    }
  };
}

test("exports a finalized, hash-verified snapshot atomically", () => {
  const outputDirectory = mkdtempSync(join(tmpdir(), "octant-registry-export-"));
  const calls = [];

  try {
    const { artifact, outFile } = exportRegistry({
      registry: REGISTRY,
      rpcUrl: "https://rpc.invalid",
      outputDirectory,
      generatedAt: new Date("2026-07-28T00:00:00.000Z"),
      castRunner: registryFixtureRunner([BLOCK_HASH_A, BLOCK_HASH_A], calls),
    });

    assert.equal(artifact.snapshot.tag, "finalized");
    assert.equal(artifact.snapshot.blockNumber, 123);
    assert.equal(artifact.snapshot.blockHash, BLOCK_HASH_A);
    assert.equal(artifact.manifestHash, MANIFEST_HASH);
    assert.deepEqual(JSON.parse(readFileSync(outFile, "utf8")), artifact);

    const registryCalls = calls.filter(([command]) => command === "call");
    assert.ok(registryCalls.length > 0);
    for (const call of registryCalls) {
      assert.deepEqual(call.slice(-4), ["--block", "123", "--rpc-url", "https://rpc.invalid"]);
    }
  } finally {
    rmSync(outputDirectory, { recursive: true, force: true });
  }
});

test("aborts without writing when the snapshot height is replaced", () => {
  const outputDirectory = mkdtempSync(join(tmpdir(), "octant-registry-reorg-"));
  const existingArtifact = '{"preserved":true}\n';
  writeFileSync(join(outputDirectory, "1.json"), existingArtifact);

  try {
    assert.throws(
      () =>
        exportRegistry({
          registry: REGISTRY,
          rpcUrl: "https://rpc.invalid",
          snapshotTag: "latest",
          outputDirectory,
          castRunner: registryFixtureRunner([BLOCK_HASH_A, BLOCK_HASH_B], []),
        }),
      /Snapshot block 123 was replaced during export/,
    );
    assert.equal(readFileSync(join(outputDirectory, "1.json"), "utf8"), existingArtifact);
  } finally {
    rmSync(outputDirectory, { recursive: true, force: true });
  }
});
