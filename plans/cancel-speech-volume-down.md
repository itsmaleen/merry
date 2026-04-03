# Cancel speech/recording via volume down

**Goal:** When speech is active, volume down (single) cancels recording instead of cycling surfaces.

## Files to change
- `ios/cmux/Layout/WorkspaceLayoutView.swift` — `wireVolumeCallbacks()` (line 578)
- `ios/cmux/Input/SpeechInputManager.swift` — add `cancel()` method

## Steps
- [ ] Add `cancel()` to `SpeechInputManager` — calls `cleanupAudio()` without returning/sending the transcript (unlike `stop()` which returns it)
- [ ] In `wireVolumeCallbacks()` `onSingleDown`, check `speech.isRecording` before the existing logic. If recording, call `speech.cancel()` and `volumeHandler.clearSpeechState()` instead of cycling surfaces
- [ ] Add haptic feedback on cancel (light impact) to confirm the action
