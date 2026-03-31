# TODOs

## Player: Resolved Button
**What:** Add "Resolved" button to Player action/message steps (matches Scenario mode).
**Why:** Agents on live calls need to mark an issue as resolved mid-workflow without completing all remaining steps.
**Context:** `can_resolve` exists as a hash key in Scenario mode's execution path but not as an AR attribute on Step. Implementation requires adding a `can_resolve` method or attribute to Step subclasses. See design doc: `~/.gstack/projects/ScribeK2-TurboFlows/ethos-main-design-20260331-075051.md`.
**Depends on:** Player Quality Pass PR must land first.

## Player: Image Lightbox
**What:** Add `image-lightbox` Stimulus controller to Player step cards for media attachment zoom.
**Why:** Agents viewing workflow steps with images need to zoom into details.
**Context:** The `image-lightbox` controller already exists and is used in Scenario mode. Just needs to be wired into `player/step.html.erb` step card div.
**Depends on:** Player Quality Pass PR must land first.
