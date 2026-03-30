class VersionDiffService
  IGNORED_KEYS = %w[created_at updated_at].freeze

  def self.call(old_snapshot, new_snapshot, old_metadata: {}, new_metadata: {})
    new(old_snapshot, new_snapshot, old_metadata, new_metadata).call
  end

  def initialize(old_snapshot, new_snapshot, old_metadata, new_metadata)
    @old_steps = Array(old_snapshot)
    @new_steps = Array(new_snapshot)
    @old_metadata = old_metadata || {}
    @new_metadata = new_metadata || {}
  end

  def call
    old_by_id = @old_steps.index_by { |s| s["id"] }
    new_by_id = @new_steps.index_by { |s| s["id"] }

    old_ids = old_by_id.keys.to_set
    new_ids = new_by_id.keys.to_set

    added = (new_ids - old_ids).map { |id| new_by_id[id] }
    removed = (old_ids - new_ids).map { |id| old_by_id[id] }

    modified = (old_ids & new_ids).filter_map do |id|
      changes = diff_step(old_by_id[id], new_by_id[id])
      next if changes.empty?

      { id: id, old: old_by_id[id], new: new_by_id[id], changed_fields: changes }
    end

    {
      added: added,
      removed: removed,
      modified: modified,
      metadata_changes: diff_metadata
    }
  end

  private

  def diff_step(old_step, new_step)
    all_keys = (old_step.keys + new_step.keys).uniq - IGNORED_KEYS
    all_keys.reject { |key| old_step[key] == new_step[key] }
  end

  def diff_metadata
    all_keys = (@old_metadata.keys + @new_metadata.keys).uniq
    all_keys.each_with_object({}) do |key, changes|
      next if @old_metadata[key] == @new_metadata[key]

      changes[key] = { old: @old_metadata[key], new: @new_metadata[key] }
    end
  end
end
