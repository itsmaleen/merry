#!/usr/bin/env bash
# Runs the iOS logic tests. The app target has no XCTest bundle, so the pure,
# UIKit-free pieces are compiled and run directly with swiftc.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

run_suite() {
  local name=$1; shift
  echo "== $name"
  swiftc -O -parse-as-library -o "$tmp/$name" "$@"
  "$tmp/$name"
}

run_suite text-search scripts/test-text-search.swift cmux/Layout/TextSearch.swift
