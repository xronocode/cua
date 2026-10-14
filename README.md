# Evidence: background type_text by element_token in Safari lands in the previously focused field

cua-driver 0.34.0 (`b0968e1b`), macOS 26.6.2 (25G83) arm64, Safari 26.6.2 (21624.5.1.11.3), iCloud Mail web compose, default background delivery.

## Redactions

- Recipient address replaced with `recipient@example.com` (same length, so `delivered_count: 21` still matches).
- The 34-character subject replaced with `[subject redacted]________________` (also 34 characters, so `requested_chars: 34` still matches).
- Account name, sender address and brand replaced with placeholders. Local paths and screenshot output paths removed.
- Snapshots are trimmed to the compose text areas (To, Subject, body) and the Cancel button. The rest of the window (mailbox list, message previews) is dropped.
- Screenshots are cropped to the compose panel; covered regions are labeled.

Driver responses are otherwise verbatim.

## Files

- `rerun-calls.jsonl`: the controlled rerun, five calls in order. Snapshot before (To not exposed yet), pixel `type_text` into To, snapshot (To holds the address, Subject empty), `type_text` by the Subject token, snapshot (To holds the subject, Subject empty). Times are Unix seconds.
- `field-run-calls.jsonl`: the same steps from the original run (transcript lines 3, 4, 12-15), including the first token call into To during which WebContent crashed. Times are UTC and epoch ms.
- `rerun-1-after-recipient.png`: after the pixel call. Recipient in To, Subject empty.
- `rerun-2-after-subject-call.png`: after the Subject token call. The subject text sits in To after the recipient chip; Subject is empty.
