/**
 * Simple HTTP Server Example
 *
 * Creates a sandbox with Python HTTP server on a non-8080 port.
 * Demonstrates encrypted tunnels (HTTPS-wrapped).
 */
import { ModalClient } from "modal";

const modal = new ModalClient({
  tokenId: process.env.MODAL_TOKEN_ID,
  tokenSecret: process.env.MODAL_TOKEN_SECRET,
});

const app = await modal.apps.fromName("http-sandbox", { createIfMissing: true });
const image = modal.images.fromRegistry("python:3.12-alpine");

const PORT = 3000;

console.log(`Creating sandbox with HTTP server on port ${PORT}...`);

const sb = await modal.sandboxes.create(app, image, {
  command: ["python3", "-m", "http.server", PORT.toString()],
  encryptedPorts: [PORT],
  idleTimeoutMs: 3600000,
  timeoutMs: 7200000,
});

console.log("Sandbox ID:", sb.sandboxId);

// Wait for server to start
await new Promise(r => setTimeout(r, 3000));

const tunnels = await sb.tunnels();
const tunnel = tunnels[PORT];

console.log("\n========================================");
console.log("HTTP SERVER READY");
console.log("========================================\n");

if (tunnel) {
  console.log("URL:", tunnel.url);

  // Test it
  console.log("\nTesting connection...");
  const response = await fetch(tunnel.url);
  console.log("Status:", response.status, response.statusText);
}

console.log("\nSandbox ID:", sb.sandboxId);

process.exit(0);
