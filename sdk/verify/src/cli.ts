#!/usr/bin/env node
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { embedProof, proofFromFeedPost, verifyFile, PUPILLE_ISSUER_PUBLIC_KEY, type FeedPost } from "./index.ts";

const usage = `pupille-proof — portable proofs for Pupille photos

  pupille-proof export [--backend URL] [--post ID] [--out DIR]
      Download posts with their exact bytes and write JPEGs that carry their proof.
      Defaults: --backend http://localhost:8787, every post, --out ./proofs

  pupille-proof verify FILE... [--issuer HEX] [--trusted-app APP_ID]...
      Check files offline. Exits 1 if any file fails.
      Default issuer: the key pinned in the Pupille app.`;

async function exportProofs(backend: string, postId: string | undefined, outDir: string) {
  const response = await fetch(new URL("/v1/feed", backend)).catch(() => {
    throw new Error(`could not reach the backend at ${backend}. Is it running?`);
  });
  if (!response.ok) throw new Error(`GET /v1/feed returned ${response.status}`);
  const posts = (await response.json()) as (FeedPost & { imageUrl: string })[];
  const selected = postId ? posts.filter((p) => p.id === postId) : posts;
  if (selected.length === 0) throw new Error(postId ? `post ${postId} not found` : "the feed is empty");
  await mkdir(outDir, { recursive: true });
  for (const post of selected) {
    const image = await fetch(new URL(post.imageUrl, backend));
    if (!image.ok) throw new Error(`image for ${post.id} returned ${image.status}`);
    const bytes = new Uint8Array(await image.arrayBuffer());
    const path = join(outDir, `${post.id}.jpg`);
    await writeFile(path, embedProof(bytes, proofFromFeedPost(post)));
    process.stdout.write(`${path}  @${post.author.handle}\n`);
  }
}

async function verifyFiles(files: string[], issuer: string, trustedAppIds: string[] | undefined) {
  let failed = false;
  for (const file of files) {
    const result = await verifyFile(new Uint8Array(await readFile(file)), { issuerPublicKey: issuer, trustedAppIds });
    if (!result) {
      failed = true;
      process.stdout.write(`\n${file}\n  ✗ no Pupille proof in this file\n`);
      continue;
    }
    failed ||= !result.verified;
    const who = result.handle ? ` · @${result.handle} (${result.environment} Human)` : "";
    process.stdout.write(`\n${file}\n  ${result.verified ? "VERIFIED" : "NOT VERIFIED"}${who}\n`);
    for (const check of result.checks) process.stdout.write(`  ${check.passed ? "✓" : "✗"} ${check.title}\n`);
  }
  return failed ? 1 : 0;
}

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    backend: { type: "string", default: "http://localhost:8787" },
    post: { type: "string" },
    out: { type: "string", default: "proofs" },
    issuer: { type: "string", default: PUPILLE_ISSUER_PUBLIC_KEY },
    "trusted-app": { type: "string", multiple: true },
    help: { type: "boolean", short: "h" },
  },
});

const [command, ...rest] = positionals;
try {
  if (command === "export") {
    await exportProofs(values.backend!, values.post, values.out!);
  } else if (command === "verify" && rest.length > 0) {
    process.exitCode = await verifyFiles(rest, values.issuer!, values["trusted-app"]);
  } else {
    process.stdout.write(usage + "\n");
    process.exitCode = values.help ? 0 : 2;
  }
} catch (error) {
  process.stderr.write(`pupille-proof: ${(error as Error).message}\n`);
  process.exitCode = 1;
}
