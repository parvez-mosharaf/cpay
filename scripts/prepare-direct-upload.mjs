#!/usr/bin/env node
/**
 * Build a clean static bundle for Cloudflare Pages / Workers direct upload.
 * The output is `dist/`; backend migrations and Edge Functions stay outside
 * this bundle and must be deployed to the new CPAY Supabase project.
 */
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";

const root = process.cwd();
const publicDir = path.join(root, "public");
const outputDir = path.join(root, "dist");
const requiredFiles = [
  "index.html",
  "404.html",
  "admin.html",
  "dashboard.html",
  "login.html",
  "register.html",
  "invoice-cpay-v2.html",
  "_headers",
  "config.js",
  "favicon-site.svg",
  "favicon-payment.svg",
];

function fail(message) {
  console.error(`FAIL ${message}`);
  process.exit(1);
}

if (!existsSync(path.join(root, "package.json"))) {
  fail("Run this command from the CPAY project root.");
}
if (!existsSync(publicDir)) fail("public/ folder is missing.");

const configPath = path.join(publicDir, "config.js");
if (!existsSync(configPath)) {
  fail("public/config.js is missing. Copy public/config.example.js and set the CPAY Supabase URL and anon key first.");
}

const config = readFileSync(configPath, "utf8");
if (/YOUR_PROJECT_REF|YOUR_PUBLIC_ANON_KEY/i.test(config)) {
  fail("public/config.js still contains example placeholders.");
}
if (/service_role|SUPABASE_SERVICE_ROLE|BTCPAY_API_KEY|WEBHOOK_SECRET/i.test(config)) {
  fail("A server-side secret name appears in public/config.js. Remove it before upload.");
}

for (const file of requiredFiles) {
  if (!existsSync(path.join(publicDir, file))) fail(`public/${file} is missing.`);
}

const npmCommand = process.platform === "win32" ? "npm.cmd" : "npm";
const build = spawnSync(npmCommand, ["run", "build"], {
  cwd: root,
  stdio: "inherit",
});
if (build.status !== 0) fail("The frontend build failed; no upload bundle was created.");

rmSync(outputDir, { recursive: true, force: true });
mkdirSync(outputDir, { recursive: true });
cpSync(publicDir, outputDir, { recursive: true });

console.log(`\nDirect-upload bundle ready: ${outputDir}`);
console.log("Upload the dist/ folder to the new CPAY Cloudflare project.");
console.log("Deploy Supabase migrations and Edge Functions separately.");