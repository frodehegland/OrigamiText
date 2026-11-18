# Panels in the right place, every time — plan (18 Nov 2026)

Frode: "the rooms are still not reliably placing the panels."

## What happens now

Each physical room has one WorldAnchor (`PhysicalRooms`, Origami Text Vision/RoomFrames.swift), made at the reader's feet the first time. Each frame keeps a pose relative to that one anchor in `origami-physical-rooms.json`. The frames' shared file also keeps a transform in *immersive-space* coordinates, and those coordinates change every time the space is opened.

## Why it goes wrong (found in the code)

1. **Frames are shown at meaningless coordinates first.** Until a room's anchor is tracked (which can take up to 30 s), frames stand at the transform in the shared file. That transform is in the coordinates of whatever session last saved it, so it is right only if the space happened to open from the same spot. Then the anchor localises and the frames jump: "right, then a few seconds later shifted."
2. **Anchor refinements are ignored.** `anchorUpdated` stores the anchor's new transform, but frames are placed only on a room change. ARKit keeps correcting an anchor after relocalising, so frames sit at the first, coarse fix. Every later `record()` uses the corrected anchor against the uncorrected frame, so the stored pose drifts a little with each session.
3. **One anchor for the whole room means lever-arm error.** The anchor is on the floor where the reader first stood. A 2° error in its yaw puts a wall 4 m away 14 cm off and visibly turned: panels "angled into the space."
4. **Places are recorded when they shouldn't be.**
   - `placeForRoom` records the current, meaningless place of every frame not yet placed in this room.
   - `update()` records on every change.
   - A provisional room made after the 30 s search records places too.
   - Wrong places then become the remembered ones.
5. **Rooms switch mid-session.** `chooseCurrent` re-chooses on every anchor update, and `mergeLateFind` folds rooms together. Any anchors within 1.5 m merge, and a room made this session merges into any remembered one within 15 m. Merging converts poses through two anchors whose relative fix is itself uncertain. Each switch calls `roomChanged()`, and every frame jumps.
6. **Three world-tracking providers run at once,** each on its own ARKitSession: CardFaceTurner, RoomSurfaces, and KnowledgeSpaceAnchoring when used. That is legal, but it means more relocalisation work and anchor streams that can disagree.
7. **Nothing can be seen.** There is no log of what was found, chosen, merged or recorded, so device sessions can't be diagnosed afterwards.

## The fix: one anchor per frame, per physical room

This is Apple's own pattern (the Object Placement sample, WWDC23) and Knowledge Space's: `KnowledgeSpaceAnchoring` gives each node its own anchor.

1. **Each frame gets its own WorldAnchor, at its exact pose,** made when a move or resize ends, and when a frame is put up or a layout loaded. The old anchor for that frame *in this room* is removed. The mapping is kept locally as frame id → [anchor id] (one per physical room it has stood in), in `origami-frame-anchors.json`.
   - ARKit relocalises an anchor only in the room where it was made, so the room needs no identifying: whichever of a frame's anchors is tracked tells where it stands.
   - There is no lever arm, because each anchor sits on its own panel.
2. **A frame follows its anchor.** On every `.added`/`.updated` with `isTracked`, the frame's entity takes the anchor's transform, so refinements are followed and drift can't build up. While its anchor isn't tracked, the frame keeps its last place and never jumps to stale coordinates.
3. **Nothing shows until its place is known.** While the room localises:
   - Frames with an anchor are hidden. No frame is shown at a stale transform.
   - After about 8 s with world tracking running, if a frame's anchor hasn't tracked but others in the room have, it is truly new here. It appears where the layout puts it, or before the reader, gets its anchor, and its place is kept from then on.
   - If *no* anchor has tracked after 8 s, this is a new place. Frames appear as laid out and get anchors when first moved. A quiet "finding this room…" note shows meanwhile.
4. **Nothing is recorded unless the frame's own anchor (or the room) is localised,** and only at gesture ends: never during drags, sync refreshes or placements.
5. **Rooms become names only.** A "physical room" is the set of anchors that track together, kept so the Panels menu can still say "Physical Room: Study". There is no merging and no choosing by distance, so the room never switches mid-session.
6. **Room layouts (the projects)** keep which frames stand and how they look. The poses now come from the anchors on this headset, so loading a layout in a room where its frames already have anchors puts them back exactly. In a room where they don't, they are laid out once and anchored.
7. **One WorldTrackingProvider.** RoomSurfaces' session is the only one. CardFaceTurner's head pose reads it through a shared accessor instead of running its own session, and Knowledge Space anchoring keeps its own only while that view is open.
8. **Migration.** The first time an old room anchor tracks, each of its stored poses is turned into a world pose and given a per-frame anchor. After that the room anchor is retired, and the poses are kept in the file in case it is needed.
9. **A log.** `origami-room-log.txt` in Application Support, capped at 2000 lines, timestamped. It records tracking state, every anchor added, tracked or lost (with frame id), every placement and its source (anchor, layout or new), every record, and every hide or show. Settings ▸ Developer gets Show Room Log, so the next headset session can be read back here.

## Order of work

1. Add the log (small, and it makes everything after it checkable).
2. Per-frame anchors and the follow-the-anchor update, behind the current API: `pose(of:)` and `record(_:)` keep their names, and PhysicalRooms changes inside.
3. Hide-until-localised and the 8 s rule.
4. Recording only at gesture ends, with the guards.
5. Remove the merge and choose-by-distance code.
6. Migration of the old poses.
7. One provider.
8. Build Vision, Mac and iOS. Then a device checklist for Frode:
   - Arrange panels in room A and quit. Relaunch from a different spot: same places?
   - Walk to room B and arrange there. Back in A: A's places again?
   - Load a project in A, then in B.
   - Leave the space open for 2 minutes: does anything drift?
   - Read the log after each step.

## What can't be checked here

Relocalisation happens only on the headset: the simulator never persists or relocalises world anchors. Every step above needs Frode's eyes. The log is what lets each session be diagnosed afterwards rather than guessed at.
