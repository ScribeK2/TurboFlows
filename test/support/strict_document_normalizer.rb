# Compares two strict documents ignoring step uuids but keeping topology.
# Shared by the export round trip and the API round trip.
module StrictDocumentNormalizer
  # Step UUIDs can't be relied on literally either way: the importer preserves
  # an explicit id verbatim (uniqueness is scoped to workflow_id, so the same
  # string is fine in a different workflow) and mints a fresh one only when a
  # step arrives with none — so two documents may carry identical ids or
  # different ones, depending on what the source provided. Dropping them
  # outright would leave transition topology unchecked, and a regression that
  # wired every transition to the wrong target would pass silently. Instead,
  # map each uuid to the index of the step it names (steps are exported in a
  # stable position order) and compare indices, so topology survives the
  # comparison while the literal id values — stable or not — do not.
  # Step uuids are legitimately regenerated on import, so they cannot be compared
  # literally — but deleting them would leave only condition and label on each
  # transition, and an importer that wired every transition to the wrong step
  # would still pass. Map each uuid to the INDEX of the step it names instead, so
  # a rewired transition changes the compared document.
  def normalize(document)
    # deep_dup, not except: the rewrites below reach into workflows[0], which a
    # shallow copy shares with the caller's document. Without this, calling
    # normalize twice on the same export rewrites already-rewritten indices and
    # every target_id comes back nil.
    doc = document.deep_dup.except("exported_at")
    workflow = doc["workflows"].first
    steps = workflow["steps"]
    index_by_uuid = steps.each_with_index.to_h { |step, i| [step["id"], i] }

    workflow["start_step_id"] = index_by_uuid.fetch(workflow["start_step_id"], nil)
    workflow["steps"] = steps.map do |step|
      step.except("id").merge(
        "transitions" => Array(step["transitions"]).map do |t|
          t.merge("target_id" => index_by_uuid.fetch(t["target_id"], nil))
        end
      )
    end
    doc
  end
end
