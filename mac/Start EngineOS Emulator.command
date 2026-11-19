#!/bin/bash
# Moved to apps/mac; this keeps a Finder shortcut to the old place working.
exec "$(cd "$(dirname "$0")" && pwd)/../apps/mac/Start EngineOS Emulator.command"
