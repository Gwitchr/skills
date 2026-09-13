#!/usr/bin/env bash
# Slack CLI get-manifest hook: prints manifest.json, ignoring CLI arguments.
cat "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manifest.json"
