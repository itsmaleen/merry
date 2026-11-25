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

run_suite text-search scripts/test-text-search.swift merry/Layout/TextSearch.swift
run_suite scroll-follow scripts/test-scroll-follow.swift merry/Layout/ScrollFollow.swift
run_suite image-scaling scripts/test-image-scaling.swift merry/Input/ImageScaling.swift
run_suite frame-fit scripts/test-frame-fit.swift merry/Layout/FrameFit.swift
run_suite chat-grouping scripts/test-chat-grouping.swift merry/Chat/TranscriptEvent.swift merry/Chat/ChatGrouping.swift merry/Chat/ChatOutbox.swift merry/Chat/SlashCommands.swift merry/Chat/ChatTable.swift
run_suite chat-paging scripts/test-chat-paging.swift merry/Chat/TranscriptEvent.swift merry/Chat/ChatGrouping.swift merry/Chat/ChatOutbox.swift merry/Chat/ChatPaging.swift
run_suite screen-dialog scripts/test-screen-dialog.swift merry/Chat/ScreenDialog.swift
run_suite device-snapshot scripts/test-device-snapshot.swift merry/Connection/DeviceSnapshot.swift
run_suite sunny-dates scripts/test-sunny-dates.swift merry/Sunny/SunnyDigest.swift
run_suite day-note scripts/test-day-note.swift merry/Sunny/DayNote.swift merry/Sunny/SunnyDigest.swift
