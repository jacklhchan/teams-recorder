# Visible Transcription Prompt Design

## Goal

Make the optional per-job transcription prompt visibly discoverable. An empty prompt must look like an input field rather than blank space with a cursor.

## Scope

Only the prompt area in `TranscriptionRequestSheet` changes. The language picker, draft identity, cancel/submit behavior, transcription options, provider requests, and persistence remain unchanged.

## UI

- Show the visible label `Prompt (optional):` above the editor.
- Keep a multi-line editor for longer guidance.
- Give the editor a visible rounded border and normal inset padding.
- When the prompt is empty, show the placeholder `Names, terminology, or transcription guidance…` in secondary text color.
- Hide the placeholder as soon as the user enters text.
- Preserve the existing prompt accessibility identifier and label.

## Behavior

The prompt remains optional. An empty value continues to submit an empty prompt. Non-empty text continues through the existing `TranscriptionRequestDraft.options` path without new storage or validation.

## Testing

Add focused render coverage that first fails against the current borderless editor, then proves:

- the visible optional label is rendered;
- the empty editor exposes the placeholder;
- the prompt editor has a visible field container;
- entering prompt text hides the placeholder and preserves the submitted value.

Run only the directly affected transcription-sheet tests and a release compile check. No provider, recording, storage, or floating-panel behavior changes are required.
