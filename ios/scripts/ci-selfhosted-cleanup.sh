#!/usr/bin/env bash
# Self-hosted Mac only, run with `if: always()`: stop leftover tests, recorders and simulators
# so a hung or cancelled job can't hold the next one.
# The pkill patterns match any process on the host whose command line contains them. That's
# fine while the mini is a CI-only box; narrow them if it is ever shared with interactive use. -Orion
pkill -f 'xcodebuild test' || true
pkill -f 'simctl io' || true
xcrun simctl shutdown all || true
