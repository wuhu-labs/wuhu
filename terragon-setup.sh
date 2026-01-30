#!/usr/bin/env bash

set -e

# go to the folder where this script lives
cd "$(dirname "$0")"
cd ..
git clone https://github.com/paideia-ai/wuhu.git wuhu-terragon
cd wuhu-terragon
./terragon-setup.sh
