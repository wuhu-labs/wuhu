/**
 * SSH Sandbox Example
 *
 * Creates an Alpine sandbox with SSH server accessible via raw TCP tunnel.
 * Generates a temporary key pair for authentication.
 */
import { ModalClient } from 'modal'
import { mkdirSync } from 'fs'

const modal = new ModalClient({
  tokenId: process.env.MODAL_TOKEN_ID,
  tokenSecret: process.env.MODAL_TOKEN_SECRET,
})

// Generate SSH key pair
console.log('Generating temporary SSH key pair...\n')
mkdirSync('/tmp/modal-ssh', { recursive: true })

Bun.spawnSync([
  'rm',
  '-f',
  '/tmp/modal-ssh/id_ed25519',
  '/tmp/modal-ssh/id_ed25519.pub',
])
Bun.spawnSync([
  'ssh-keygen',
  '-t',
  'ed25519',
  '-f',
  '/tmp/modal-ssh/id_ed25519',
  '-N',
  '',
  '-C',
  'modal-sandbox',
], { stdout: 'pipe', stderr: 'pipe' })

const privateKey = await Bun.file('/tmp/modal-ssh/id_ed25519').text()
const publicKey = (await Bun.file('/tmp/modal-ssh/id_ed25519.pub').text())
  .trim()

console.log('=== PRIVATE KEY ===\n')
console.log(privateKey)
console.log('=== END PRIVATE KEY ===\n')

const app = await modal.apps.fromName('ssh-sandbox', { createIfMissing: true })
const image = modal.images.fromRegistry('alpine:3.21')

console.log('Creating sandbox...')

const sb = await modal.sandboxes.create(app, image, {
  command: ['sleep', 'infinity'],
  unencryptedPorts: [22], // Raw TCP for SSH
  idleTimeoutMs: 3600000,
  timeoutMs: 7200000,
})

console.log('Sandbox ID:', sb.sandboxId)
console.log('\nSetting up SSH...')

// Install and configure
const cmds = [
  ['apk', 'add', '--no-cache', 'openssh'],
  ['ssh-keygen', '-A'],
  ['adduser', '-D', '-s', '/bin/ash', 'user'],
  ['passwd', '-u', 'user'], // Unlock account (Alpine locks by default)
  ['mkdir', '-p', '/home/user/.ssh'],
  ['chmod', '700', '/home/user/.ssh'],
]
for (const cmd of cmds) {
  const p = await sb.exec(cmd)
  await p.wait()
}

// Write key using stdin to avoid shell escaping issues
const writeKey = await sb.exec(['tee', '/home/user/.ssh/authorized_keys'])
await writeKey.stdin.writeText(publicKey)
await writeKey.stdin.close()
await writeKey.wait()

// Fix perms
const cmds2 = [
  ['chmod', '600', '/home/user/.ssh/authorized_keys'],
  ['chown', '-R', 'user:user', '/home/user/.ssh'],
]
for (const cmd of cmds2) {
  const p = await sb.exec(cmd)
  await p.wait()
}

// Start sshd (don't await - runs in background)
console.log('Starting sshd...')
await sb.exec(['/usr/sbin/sshd', '-D', '-e'])
await new Promise((r) => setTimeout(r, 2000))

// Get tunnel info
const tunnels = await sb.tunnels()
const tunnel = tunnels[22]

console.log('\n========================================')
console.log('SSH SANDBOX READY')
console.log('========================================\n')

if (tunnel) {
  console.log('Connect with:')
  console.log(
    `  ssh -i /tmp/modal-ssh/id_ed25519 -p ${tunnel.unencryptedPort} user@${tunnel.unencryptedHost}`,
  )
}

console.log('\nSandbox ID:', sb.sandboxId)
console.log('Idle timeout: 1 hour')

process.exit(0)
