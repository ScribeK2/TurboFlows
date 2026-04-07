class Group < ApplicationRecord
  # Associations
  belongs_to :parent, class_name: 'Group', optional: true
  has_many :children, class_name: 'Group', foreign_key: 'parent_id', dependent: :nullify
  has_many :group_workflows, dependent: :destroy
  has_many :workflows, through: :group_workflows
  has_many :user_groups, dependent: :destroy
  has_many :users, through: :user_groups
  has_many :folders, dependent: :destroy

  # Validations
  validates :name, presence: true, uniqueness: { scope: :parent_id }
  validate :no_circular_reference
  validate :max_depth_allowed

  # Scopes
  scope :roots, -> { where(parent_id: nil) }
  scope :children_of, ->(parent) { where(parent_id: parent.id) }
  scope :visible_to, lambda { |user|
    return all if user&.admin?
    return Group.none unless user

    # Users see groups they're assigned to
    user_assigned_group_ids = joins(:user_groups).where(user_groups: { user_id: user.id }).pluck(:id)

    # Also include Uncategorized group for backward compatibility (workflows without groups)
    # This ensures users can always see workflows in the Uncategorized group
    uncategorized_group_id = Group.find_by(name: "Uncategorized")&.id

    # Combine both: user's assigned groups OR Uncategorized
    group_ids = [user_assigned_group_ids, uncategorized_group_id].flatten.compact.uniq
    where(id: group_ids)
  }

  # Tree traversal methods
  # These methods use recursive algorithms to traverse the hierarchical tree structure

  # Check if this group is a root (has no parent)
  def root?
    parent_id.nil?
  end

  # Check if this group is a leaf (has no children)
  def leaf?
    children.empty?
  end

  # Calculate the depth of this group in the tree (0 for root, 1 for first level, etc.)
  # Uses recursive traversal up the tree to count levels
  def depth
    return 0 if root?

    parent.depth + 1
  end

  # Get all ancestor groups (parent, grandparent, etc.) up to the root
  # Returns an array ordered from immediate parent to root
  # Example: If hierarchy is Root > Parent > Child, Child.ancestors returns [Parent, Root]
  def ancestors
    return [] if parent_id.nil?

    ids = self.class.ancestor_ids_for(id)
    return [] if ids.empty?

    ancestors_by_id = Group.where(id: ids).index_by(&:id)
    ids.map { |aid| ancestors_by_id[aid] }.compact
  end

  # Get all descendant groups (children, grandchildren, etc.) recursively
  # Returns a flat array of all groups below this one in the hierarchy
  # Example: If Root has Child1 and Child2, and Child1 has Grandchild,
  # Root.descendants returns [Child1, Child2, Grandchild]
  #
  # DEPRECATED: Causes N+1 queries — O(depth) round-trips. Use descendant_ids
  # for ID-only lookups. If you need full records, load them with:
  #   Group.where(id: descendant_ids)
  def descendants
    Rails.logger.warn(
      "[DEPRECATED] Group#descendants causes N+1 queries. " \
      "Use Group#descendant_ids or Group.where(id: descendant_ids) instead."
    )
    children.flat_map { |child| [child] + child.descendants }
  end

  # Get all descendant IDs using a single efficient query
  # Uses recursive CTE for PostgreSQL, breadth-first iteration for SQLite
  # @return [Array<Integer>] Array of descendant group IDs
  def descendant_ids
    Group.descendant_ids_for([id])
  end

  # Class method to get all descendant IDs for multiple parent groups at once
  # This is much more efficient than calling descendant_ids on each group
  # @param parent_ids [Array<Integer>] Array of parent group IDs
  # @return [Array<Integer>] Array of all descendant group IDs (not including parents)
  def self.descendant_ids_for(parent_ids)
    return [] if parent_ids.blank?

    # Sanitize parent_ids to ensure they're all integers and valid
    sanitized_parent_ids = parent_ids.map do |id|
      Integer(id)
    rescue StandardError
      nil
    end.compact.uniq
    return [] if sanitized_parent_ids.blank?

    if connection.adapter_name.downcase.include?('postgresql')
      # PostgreSQL: Use recursive CTE for optimal performance
      placeholders = sanitized_parent_ids.map { "?" }.join(",")
      sql = sanitize_sql_array([<<~SQL.squish, *sanitized_parent_ids])
        WITH RECURSIVE descendants AS (
          SELECT id, parent_id FROM groups WHERE parent_id IN (#{placeholders})
          UNION ALL
          SELECT g.id, g.parent_id FROM groups g
          INNER JOIN descendants d ON g.parent_id = d.id
        )
        SELECT DISTINCT id FROM descendants
      SQL
      connection.select_values(sql).map(&:to_i)
    else
      # SQLite/other: Breadth-first iteration (efficient for reasonable depths)
      all_descendant_ids = []
      current_level_ids = parent_ids.map(&:to_i)

      # Safety limit to prevent infinite loops (max 10 levels deep)
      10.times do
        child_ids = Group.where(parent_id: current_level_ids).pluck(:id)
        break if child_ids.empty?

        all_descendant_ids.concat(child_ids)
        current_level_ids = child_ids
      end

      all_descendant_ids.uniq
    end
  end

  # Get all accessible group IDs for a user (their assigned groups + all descendants)
  # Single optimized query instead of N+1
  # @param user [User] The user to get accessible groups for
  # @return [Array<Integer>] Array of all accessible group IDs
  def self.accessible_group_ids_for(user)
    return [] unless user&.groups&.any?

    user_group_ids = user.groups.pluck(:id)
    descendant_ids = descendant_ids_for(user_group_ids)
    (user_group_ids + descendant_ids).uniq
  end

  # Get ancestor IDs for a group using a single efficient approach
  # @param group_id [Integer] The group ID to find ancestors for
  # @return [Array<Integer>] Array of ancestor group IDs, ordered from immediate parent to root
  def self.ancestor_ids_for(group_id)
    if connection.adapter_name.downcase.include?("postgresql")
      sql = <<~SQL
        WITH RECURSIVE ancestor_tree AS (
          SELECT parent_id FROM groups WHERE id = #{connection.quote(group_id)}
          UNION ALL
          SELECT g.parent_id FROM groups g
          INNER JOIN ancestor_tree a ON g.id = a.parent_id
          WHERE g.parent_id IS NOT NULL
        )
        SELECT parent_id FROM ancestor_tree WHERE parent_id IS NOT NULL
      SQL
      connection.select_values(sql).map(&:to_i)
    else
      # SQLite breadth-first with depth cap
      ids = []
      current_id = connection.select_value("SELECT parent_id FROM groups WHERE id = #{connection.quote(group_id)}")
      seen = Set.new
      while current_id && !seen.include?(current_id) && ids.size < 10
        seen.add(current_id)
        ids << current_id.to_i
        current_id = connection.select_value("SELECT parent_id FROM groups WHERE id = #{connection.quote(current_id)}")
      end
      ids
    end
  end

  # Generate a full path string showing the hierarchy
  # Example: "Customer Experience > Phone Support > Tier 1"
  # @param separator [String] The separator to use between group names (default: " > ")
  # @return [String] The full path from root to this group
  def full_path(separator: ' > ')
    (ancestors.reverse + [self]).map(&:name).join(separator)
  end

  # Count workflows in this group and optionally all descendant groups
  # @param include_descendants [Boolean] If true, includes workflows from all descendant groups
  # @return [Integer] The total count of workflows
  # Note: This method can cause N+1 queries if called on multiple groups without eager loading
  def workflows_count(include_descendants: true)
    if include_descendants
      # Use precomputed cache if available (set by Group.precompute_workflows_counts)
      return @_workflows_count_cache if defined?(@_workflows_count_cache)

      all_ids = self.class.descendant_ids_for([id]) + [id]
      GroupWorkflow.where(group_id: all_ids).distinct.count(:workflow_id)
    else
      workflows.count
    end
  end

  # Precompute workflows_count for a collection of groups in bulk
  # This avoids N+1 queries when rendering sidebar or lists
  # @param groups [Array<Group>] Groups to precompute counts for
  def self.precompute_workflows_counts(groups)
    return if groups.empty?

    all_group_ids = groups.map(&:id)

    # Build a map: group_id => set of all descendant IDs (including self)
    all_descendant_ids = descendant_ids_for(all_group_ids)
    all_relevant_ids = (all_group_ids + all_descendant_ids).uniq

    # Single query: get all group_id => workflow_id pairs
    gw_pairs = GroupWorkflow.where(group_id: all_relevant_ids).pluck(:group_id, :workflow_id)

    # Build group_id => [workflow_ids] lookup
    workflows_by_group = gw_pairs.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |(gid, wid), hash|
      hash[gid].add(wid)
    end

    # For each group, compute count including descendants
    # Need to know which groups are descendants of which
    parent_child = Group.where(id: all_relevant_ids).pluck(:id, :parent_id)
    children_map = parent_child.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(cid, pid), hash|
      hash[pid] << cid if pid
    end

    groups.each do |group|
      # Get all IDs in this group's subtree
      subtree_ids = [group.id]
      queue = [group.id]
      while (current = queue.shift)
        kids = children_map[current] || []
        subtree_ids.concat(kids)
        queue.concat(kids)
      end

      # Count distinct workflows across the subtree
      workflow_ids = Set.new
      subtree_ids.each { |gid| workflow_ids.merge(workflows_by_group[gid]) }
      group.instance_variable_set(:@_workflows_count_cache, workflow_ids.size)
    end
  end

  # Get groups accessible to this user (admins see all, others see assigned groups)
  # Also checks if user has access through ancestor groups (if assigned to parent, can see children)
  def can_be_viewed_by?(user)
    return true if user&.admin?
    return false unless user

    user.groups.include?(self) || ancestors.any? { |ancestor| user.groups.include?(ancestor) }
  end

  # Get workflows in this group that don't have a folder assignment
  def uncategorized_workflows
    workflows.joins(:group_workflows)
             .where(group_workflows: { group_id: id, folder_id: nil })
  end

  # Class method to get or create the default "Uncategorized" group
  # This group is used for workflows without explicit group assignments (backward compatibility)
  def self.uncategorized
    find_or_create_by!(name: "Uncategorized") do |group|
      group.description = "Default group for workflows without explicit group assignment"
      group.position = 0
    end
  end

  private

  # Validation to prevent circular references in the group hierarchy
  # Prevents scenarios like: A -> B -> A (direct circular)
  # Or: A -> B -> C -> A (indirect circular)
  # Also prevents a group from being its own parent
  def no_circular_reference
    return unless parent_id
    return unless parent_id_changed? || new_record?

    # Get the parent group
    parent_group = parent_id.present? ? Group.find_by(id: parent_id) : nil
    return unless parent_group

    # Check if this group (or any of its descendants) would be an ancestor of the parent
    # This prevents: A -> B -> A (direct circular)
    # And also: A -> B -> C -> A (indirect circular)
    if parent_group.id == id
      errors.add(:parent_id, "cannot be set to itself")
      return
    end

    # Check if this group is an ancestor of the parent (would create a cycle)
    if parent_group.ancestors.any? { |ancestor| ancestor.id == id }
      errors.add(:parent_id, "cannot create circular reference")
      return
    end

    # Also check if any descendant of this group is the parent (would create a cycle)
    if descendant_ids.include?(parent_group.id)
      errors.add(:parent_id, "cannot create circular reference: parent is a descendant")
      nil
    end
  end

  # Validation to enforce maximum depth limit (prevents infinite nesting)
  # Default maximum depth is 5 levels (configurable)
  def max_depth_allowed
    # Allow up to 5 levels deep (configurable)
    max_depth = 5
    current_depth = if parent_id && parent.persisted?
                      parent.depth + 1
                    else
                      parent_id ? 1 : 0
                    end

    return unless current_depth >= max_depth

    errors.add(:parent_id, "maximum depth of #{max_depth} levels exceeded")
  end
end
