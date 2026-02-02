#!/usr/bin/env bash

set -e

# Go to the folder where this script lives (Wuhu repo root)
cd "$(dirname "$0")"

# Install Deno if not present
if ! command -v deno >/dev/null 2>&1; then
  curl -fsSL https://deno.land/install.sh | sh

  # Link into /usr/local/bin for convenience if not already there
  if [ -x "${HOME}/.deno/bin/deno" ] && [ ! -x "/usr/local/bin/deno" ]; then
    ln -sf "${HOME}/.deno/bin/deno" /usr/local/bin/deno
  fi
fi

# Configure local git hooks
git config core.hooksPath .githooks

# Run the Deno-based setup script to clone reference repos and worktrees
deno run -A scripts/setup-terragon.ts
