#!/usr/bin/env node
/**
 * export-registry.mjs
 *
 * Reads one block-consistent snapshot of the on-chain OctantRegistry and regenerates the
 * `deployments/<chainId>.json` artifact. The on-chain registry is the source of truth for
 * production deployments; generated JSON files (and script/helpers/DeployedAddresses.sol)
 * are caches derived from it.
 *
 * Requires Foundry's `cast` on the PATH (no npm dependencies).
 *
 * Usage:
 *   REGISTRY_ADDRESS=0x... ETH_RPC_URL=https://... yarn registry:export
 *   REGISTRY_SNAPSHOT=latest REGISTRY_ADDRESS=0x... ETH_RPC_URL=https://... yarn registry:export
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const ENTRY_TYPES = ["UNSET", "CONTRACT", "FACTORY", "REGISTRY"];
const ENTRY_STATUSES = ["UNSET", "ACTIVE", "DEPRECATED", "DISABLED"];
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/** Run a `cast` command and return stdout. */
function defaultCastRunner(args) {
  return execFileSync("cast", args, { encoding: "utf8" });
}

/** Decode a bytes32 short-string (right-padded with zero bytes) to ASCII. */
function decodeShortString(hex) {
  const bytes = Buffer.from(hex.replace(/^0x/, ""), "hex");
  let end = bytes.length;
  while (end > 0 && bytes[end - 1] === 0) end--;
  return bytes.subarray(0, end).toString("ascii");
}

/**
 * Export one registry snapshot.
 *
 * `finalized` is the default snapshot tag. Callers that intentionally need newer state may
 * select `safe`, `latest`, or an explicit block through REGISTRY_SNAPSHOT; the mandatory
 * before/after hash check still prevents a replaced numeric height from being written.
 */
export function exportRegistry({
  registry,
  rpcUrl,
  snapshotTag = "finalized",
  outputDirectory = resolve(process.cwd(), "deployments"),
  generatedAt = new Date(),
  castRunner = defaultCastRunner,
}) {
  if (!registry || !rpcUrl) {
    throw new Error("REGISTRY_ADDRESS and ETH_RPC_URL are required");
  }

  /** Run a `cast` subcommand against the configured RPC and return trimmed stdout. */
  function cast(...args) {
    return castRunner([...args, "--rpc-url", rpcUrl]).trim();
  }

  const chainId = Number(cast("chain-id"));
  const snapshotBlockNumber = BigInt(cast("block", snapshotTag, "--field", "number"));
  const snapshotBlockHash = cast("block", snapshotBlockNumber.toString(), "--field", "hash");

  /** Read a registry function at the pinned numeric snapshot height. */
  function registryCall(signature, ...args) {
    return cast("call", registry, signature, ...args, "--block", snapshotBlockNumber.toString());
  }

  const count = Number(registryCall("count()(uint256)"));
  const epoch = Number(registryCall("epoch()(uint64)"));
  const manifestHash = registryCall("manifestHash()(bytes32)");
  const releaseLabel = JSON.parse(registryCall("releaseLabel()(string)", "--json"))[0];
  const registryApiVersion = JSON.parse(registryCall("API_VERSION()(string)", "--json"))[0];
  const successor = registryCall("getSuccessor()(address)");

  if (successor.toLowerCase() !== ZERO_ADDRESS) {
    throw new Error(`Registry ${registry} is superseded by ${successor}; export the successor instead.`);
  }

  const entries = [];
  for (let i = 0; i < count; i++) {
    const key = registryCall("keyAt(uint256)(bytes32)", String(i));
    const [address, updatedAt, bump, entryEpoch, entryType, status, compatibilityVersion, runtimeCodeHash] = JSON.parse(
      registryCall("getEntry(bytes32)(address,uint64,uint32,uint64,uint8,uint8,bytes32,bytes32)", key, "--json"),
    );

    const entryTypeNumber = Number(entryType);
    const statusNumber = Number(status);
    entries.push({
      key,
      label: decodeShortString(key),
      address,
      updatedAt: Number(updatedAt),
      bump: Number(bump),
      epoch: Number(entryEpoch),
      entryType: ENTRY_TYPES[entryTypeNumber] ?? `UNKNOWN_${entryTypeNumber}`,
      status: ENTRY_STATUSES[statusNumber] ?? `UNKNOWN_${statusNumber}`,
      compatibilityVersion,
      runtimeCodeHash,
    });
  }

  const verifiedSnapshotBlockHash = cast("block", snapshotBlockNumber.toString(), "--field", "hash");
  if (verifiedSnapshotBlockHash.toLowerCase() !== snapshotBlockHash.toLowerCase()) {
    throw new Error(
      `Snapshot block ${snapshotBlockNumber} was replaced during export ` +
        `(${snapshotBlockHash} -> ${verifiedSnapshotBlockHash}); retry after finality.`,
    );
  }

  const artifact = {
    chainId,
    registry,
    snapshot: {
      tag: snapshotTag,
      blockNumber: Number(snapshotBlockNumber),
      blockHash: snapshotBlockHash,
    },
    epoch,
    manifestHash,
    releaseLabel,
    registryApiVersion,
    successor,
    generatedAt: generatedAt.toISOString(),
    entries: entries.sort((a, b) => a.key.localeCompare(b.key)),
  };

  mkdirSync(outputDirectory, { recursive: true });
  const outFile = resolve(outputDirectory, `${chainId}.json`);
  const temporaryOutFile = `${outFile}.${process.pid}.tmp`;
  try {
    writeFileSync(temporaryOutFile, `${JSON.stringify(artifact, null, 2)}\n`);
    renameSync(temporaryOutFile, outFile);
  } catch (error) {
    rmSync(temporaryOutFile, { force: true });
    throw error;
  }

  return { artifact, outFile };
}

function main() {
  try {
    const { artifact, outFile } = exportRegistry({
      registry: process.env.REGISTRY_ADDRESS,
      rpcUrl: process.env.ETH_RPC_URL,
      snapshotTag: process.env.REGISTRY_SNAPSHOT ?? "finalized",
    });
    console.log(
      `Wrote ${artifact.entries.length} entries to ${outFile} ` +
        `(epoch ${artifact.epoch}, block ${artifact.snapshot.blockNumber})`,
    );
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main();
}
