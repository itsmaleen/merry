# Swipe-to-edit transcript with keyboard mode

**Goal:** While recording, swipe to switch to a keyboard text editor for the transcript. Works in portrait + landscape.

## Files to change
- New file: `ios/cmux/Input/TranscriptEditorView.swift`
- `ios/cmux/Layout/WorkspaceLayoutView.swift` — add state + gesture + overlay
- `ios/cmux/Input/SpeechInputManager.swift` — expose editable transcript binding

## Steps
- [ ] Create `TranscriptEditorView` — a `TextEditor` pre-filled with current `speechManager.transcript`, with Send and Cancel buttons. Support both orientations (no landscape lock for this view)
- [ ] Add `@State var isEditingTranscript = false` to `WorkspaceLayoutView`
- [ ] Add swipe-up or swipe-left gesture on the recording indicator/overlay area. On swipe, stop recording (`speech.stop()`), set `isEditingTranscript = true`, pass the transcript text to the editor
- [ ] On Send from editor: send the edited text to focused surface via `appState.sendText()`, dismiss editor
- [ ] On Cancel from editor: dismiss editor, discard text
- [ ] Unlock orientation for the editor view (currently app is landscape-only — may need `Info.plist` or `AppDelegate` changes to allow portrait when editor is active)
