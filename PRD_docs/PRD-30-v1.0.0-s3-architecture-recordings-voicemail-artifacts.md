# PRD-30 - Customer Audio Storage (Recordings, Voicemail)

---

## Status

Superseded by [PRD-10a-v1.0.0-voicemail-solution-mailboxes-routing.md](./PRD-10a-v1.0.0-voicemail-solution-mailboxes-routing.md).

## Note

This file is retained only as historical planning context.

The active contract for customer-audio storage previously described here now lives inside PRD-10a, which now owns:

- the production recordings bucket
- the voicemail bucket
- the Connect `CALL_RECORDINGS` storage association cutover
- mailbox routing and voicemail behavior
- optional transcription and notification

## Historical Scope

PRD-30 originally described customer-audio storage as a separate module boundary. That boundary is no longer the active design direction for the repo.

## Replacement

Use PRD-10a for all future planning, review, and implementation work related to voicemail-owned customer-audio storage.
