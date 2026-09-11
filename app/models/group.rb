class Group < ApplicationRecord
  # Everyone signed in sees what is filed here — the one group whose audience is
  # not its members. It replaced "Uncategorized" (db/migrate/20260910120000),
  # which the name promised was for no one in particular and the code showed to
  # almost no one. Only a ROOT group by this name is Global.
  GLOBAL_NAME = "Global".freeze

  # Levels a group tree may have: a root and four below it.
  MAX_DEPTH = 5

  # A person asked to join or leave, on their own, a group only an administrator
  # may put them in or take them out of (spec 2026-09-11 Q6, Q8).
  class NotSelfJoinable < StandardError; end

  # Associations
  belongs_to :parent, class_name: 'Group', optional: true
  has_many :children, class_name: 'Group', foreign_key: 'parent_id', inverse_of: :parent, dependent: :nullify
  has_many :group_workflows, dependent: :destroy
  has_many :workflows, through: :group_workflows
  has_many :user_groups, dependent: :destroy
  has_many :users, through: :user_groups
  has_many :folders, dependent: :destroy

  # Validations
  validates :name, presence: true, uniqueness: { scope: :parent_id }
  validate :no_circular_reference
  validate :max_depth_allowed
  validate :global_stays_put, on: :update
  validate :nothing_nests_under_global
  validate :global_is_not_kept_to_administrators
  # prepend: the dependent callbacks above (nullify children, destroy
  # group_workflows) would otherwise run before the refusal.
  before_destroy :refuse_to_destroy_global, prepend: true

  # Scopes
  scope :roots, -> { where(parent_id: nil) }
  scope :children_of, ->(parent) { where(parent_id: parent.id) }
  scope :global, -> { roots.where(name: GLOBAL_NAME) }

  # Tree traversal methods
  # These methods use recursive algorithms to traverse the hierarchical tree structure

  # Check if this group is a root (has no parent)
  def root?
    parent_id.nil?
  end

  def global?
    parent_id.nil? && name == GLOBAL_NAME
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

  # Levels below this group in the saved tree: 0 for a leaf.
  def subtree_height
    return 0 if new_record?

    ids = descendant_ids
    return 0 if ids.empty?

    depths = Group.tree_nodes.to_h { [it.id, it.depth] }
    ids.filter_map { depths[it] }.max.to_i - depths.fetch(id, 0)
  end

  # Whether a subgroup could be created here. The group page hides Add Subgroup
  # at the limit rather than offering a save that is refused (spec Q61).
  def accepts_subgroups?
    !global? && depth + 1 < MAX_DEPTH
  end

  # Get all ancestor groups (parent, grandparent, etc.) up to the root
  # Returns an array ordered from immediate parent to root
  # Example: If hierarchy is Root > Parent > Child, Child.ancestors returns [Parent, Root]
  def ancestors
    return [] if parent_id.nil?

    ids = self.class.ancestor_ids_for(id)
    return [] if ids.empty?

    ancestors_by_id = Group.where(id: ids).index_by(&:id)
    ids.filter_map { |aid| ancestors_by_id[aid] }
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
    sanitized_parent_ids = parent_ids.filter_map do |id|
      Integer(id)
    rescue StandardError
      nil
    end.uniq
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

  # nil until the migration has run. Never created on read: a lookup that
  # created the group would grow one in every fresh database on first page load.
  def self.global_id
    global.pick(:id)
  end

  # Every group whose workflows this person may see: their groups, those groups'
  # subgroups, and Global. Admins see everything and never need this.
  def self.reachable_ids_for(user)
    return [] unless user

    (accessible_group_ids_for(user) + [global_id]).compact.uniq
  end

  # The groups a save may leave a workflow in. An admin's choice stands. Anyone
  # else may add or remove only groups they reach; a group they don't reach
  # stays exactly as it was, since the picker never showed it to them.
  def self.assignable_ids_for(user, requested_ids, current_ids:)
    requested = Array(requested_ids).compact_blank.map(&:to_i).uniq
    return requested if user&.admin?

    reachable = reachable_ids_for(user)
    (requested & reachable) + (current_ids.map(&:to_i) - reachable)
  end

  # Get ancestor IDs for a group using a single efficient approach
  # @param group_id [Integer] The group ID to find ancestors for
  # @return [Array<Integer>] Array of ancestor group IDs, ordered from immediate parent to root
  def self.ancestor_ids_for(group_id)
    if connection.adapter_name.downcase.include?("postgresql")
      sql = <<~SQL.squish
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
      while current_id && seen.exclude?(current_id) && ids.size < 10
        seen.add(current_id)
        ids << current_id.to_i
        current_id = connection.select_value("SELECT parent_id FROM groups WHERE id = #{connection.quote(current_id)}")
      end
      ids
    end
  end

  # One group as a picker or a list needs it: where it sits and its full path.
  TreeNode = Data.define(:id, :name, :parent_id, :depth, :path) do
    def global? = parent_id.nil? && name == GLOBAL_NAME
  end

  TREE_PATH_SEPARATOR = " / ".freeze

  # Every group, depth-first, each carrying its depth and full path — from ONE
  # query. Group#full_path queries ancestors per call, which a picker of
  # hundreds of department groups cannot afford.
  #
  # Siblings sort by name ignoring case, Global first among the roots (spec Q33,
  # Q50). A byte-order sort put "WSO" before "Web Support". Groups have no
  # position column.
  #
  # within: the ids to emit. Paths still come from the whole tree, so an editor
  # who reaches only "Support / Tier 2" sees that path rather than a bare name.
  def self.tree_nodes(within: nil)
    rows = pluck(:id, :name, :parent_id)
    children = rows.group_by { |_, _, parent_id| parent_id }
    children.each_value { |siblings| siblings.sort_by! { |_, name, parent_id| sibling_sort_key(name, parent_id) } }
    keep = within&.to_set(&:to_i)
    nodes = []

    walk = lambda do |parent_id, depth, trail|
      children.fetch(parent_id, []).each do |id, name, _|
        path = trail + [name]
        if keep.nil? || keep.include?(id)
          nodes << TreeNode.new(id:, name:, parent_id:, depth:, path: path.join(TREE_PATH_SEPARATOR))
        end
        # max_depth_allowed caps real trees; the guard only stops a corrupt cycle.
        walk.call(id, depth + 1, path) if depth < 10
      end
    end
    walk.call(nil, 0, [])

    nodes
  end

  # Global is not a group anyone joins — its audience is everyone signed in.
  def self.assignable_tree_nodes
    tree_nodes.reject(&:global?)
  end

  # Groups a person may join or leave on their own (spec 2026-09-11 Q6): not
  # Global, not one an administrator manages (admins_add_members), and not any
  # group above or below one. Membership covers subgroups, so joining the parent
  # of a managed group would reach it; and a group that could not be rejoined
  # must not be left either. One query, however many groups exist.
  def self.self_joinable_ids
    rows = pluck(:id, :parent_id, :name, :admins_add_members)
    parent_of = rows.to_h { |id, parent_id, _, _| [id, parent_id] }
    children_of = rows.group_by { |_, parent_id, _, _| parent_id }.transform_values { it.map(&:first) }
    blocked = Set.new

    rows.each do |id, _, _, managed|
      next unless managed

      # max_depth_allowed caps real trees at 5; the bound only stops a corrupt cycle.
      ancestor = id
      10.times do
        break if ancestor.nil?

        blocked << ancestor
        ancestor = parent_of[ancestor]
      end

      # Never stop at a group already blocked: walking up from another managed
      # group may have marked it without marking its other children.
      queue = children_of.fetch(id, []).map { [it, 1] }
      until queue.empty?
        child, depth = queue.shift
        blocked << child
        queue.concat(children_of.fetch(child, []).map { [it, depth + 1] }) if depth < 10
      end
    end

    rows.filter_map do |id, parent_id, name, _|
      id unless blocked.include?(id) || (parent_id.nil? && name == GLOBAL_NAME)
    end
  end

  # { group_id => description } for the given groups that have one. The welcome
  # page and My groups show it under a group's path (spec 2026-09-11 Q5).
  def self.descriptions_by_id(ids)
    where(id: ids).where.not(description: [nil, ""]).pluck(:id, :description).to_h
  end

  def self.sibling_sort_key(name, parent_id)
    [parent_id.nil? && name == GLOBAL_NAME ? 0 : 1, name.downcase, name]
  end
  private_class_method :sibling_sort_key

  # { group_id => "Root / Child / Leaf" } for every group, from one query.
  def self.paths_by_id
    tree_nodes.to_h { [it.id, it.path] }
  end

  # { group_id => direct members } for every group that has any, from one query.
  # Direct, not inherited (spec Q34): the number is who is IN the group, which
  # is what the Users filter lists when you follow it.
  def self.member_counts
    UserGroup.group(:group_id).count
  end

  # { group_id => distinct workflows filed in it or any subgroup } for every
  # group that has any, from two queries. That is what /workflows?group_id=
  # lists (Workflow.in_group), so a row's number is the number its link opens.
  def self.workflow_counts_including_subgroups
    parent_of = Group.pluck(:id, :parent_id).to_h
    reached = Hash.new { |hash, id| hash[id] = Set.new }

    GroupWorkflow.distinct.pluck(:group_id, :workflow_id).each do |group_id, workflow_id|
      # A filing counts for its group and every group above it. `seen` only
      # stops a corrupt cycle; no_circular_reference prevents real ones.
      seen = Set.new
      current = group_id
      while current && seen.add?(current)
        reached[current] << workflow_id
        current = parent_of[current]
      end
    end

    reached.transform_values(&:size)
  end

  # Where a group may sit: under any group except itself and its subgroups (a
  # cycle), Global (which has none), and groups too deep to take it and all it
  # carries (MAX_DEPTH), each with its full path (spec Q40, Q61). A saved
  # group's current parent always stays, so editing an already-too-deep group
  # can't silently move it to the top level. A new group has no current parent:
  # a parent_id in the URL doesn't bring back one the save would refuse.
  def self.parent_options_for(group)
    excluded = group&.persisted? ? [group.id, *group.descendant_ids].to_set : Set.new
    height = group ? group.subtree_height : 0
    tree_nodes.reject do |node|
      next false if group&.persisted? && node.id == group.parent_id_was

      node.global? || excluded.include?(node.id) || node.depth + 1 + height >= MAX_DEPTH
    end
  end

  # Generate a full path string showing the hierarchy
  # Example: "Customer Experience > Phone Support > Tier 1"
  # @param separator [String] The separator to use between group names (default: " > ")
  # @return [String] The full path from root to this group
  def full_path(separator: ' > ')
    (ancestors.reverse + [self]).map(&:name).join(separator)
  end

  # The unambiguous name path from the root down to this group, as an import
  # file writes it (WorkflowPlacement::PATH_SEPARATOR). Names are unique per
  # parent_id, so this round-trips.
  def name_path
    full_path(separator: ' / ')
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
  #
  # @param groups [Array<Group>] Groups to precompute counts for
  # @param visible_ids [Enumerable<Integer>, nil] restrict the count to these
  #   workflow ids. Without it the count is every workflow filed under the group,
  #   which is not what the person reading the sidebar can open: an editor saw
  #   "All Workflows 0" above "Global 12", clicked Global, and got
  #   "No workflows". Pass the same scope the list itself uses.
  def self.precompute_workflows_counts(groups, visible_ids: nil)
    return if groups.empty?

    all_group_ids = groups.map(&:id)

    # Build a map: group_id => set of all descendant IDs (including self)
    all_descendant_ids = descendant_ids_for(all_group_ids)
    all_relevant_ids = (all_group_ids + all_descendant_ids).uniq

    # Single query: get all group_id => workflow_id pairs
    gw_pairs = GroupWorkflow.where(group_id: all_relevant_ids)
    gw_pairs = gw_pairs.where(workflow_id: visible_ids) if visible_ids
    gw_pairs = gw_pairs.pluck(:group_id, :workflow_id)

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

    # Global is for everyone signed in. Granting view of the group leaks
    # nothing: the workflows in it are still scoped by Workflow.visible_to.
    return true if global?

    user.groups.include?(self) || ancestors.any? { |ancestor| user.groups.include?(ancestor) }
  end

  # Workflows in this group that sit in none of its folders.
  def unfiled_workflows
    workflows.joins(:group_workflows)
             .where(group_workflows: { group_id: id, folder_id: nil })
  end

  # { folder_id => workflows filed in it } for this group's folders, one query.
  def folder_workflow_counts
    group_workflows.where.not(folder_id: nil).group(:folder_id).count
  end

  # Direct members by email, accounts loaded for display.
  def memberships_by_email
    user_groups.eager_load(:user).merge(User.order(:email))
  end

  # Parent groups whose members reach this group's workflows too, root first,
  # each with its direct member count. Membership covers subgroups, so these
  # people are not listed as members, but the page says they have access.
  def inherited_access
    above = ancestors.reverse
    counts = UserGroup.where(group_id: above.map(&:id)).group(:group_id).count
    above.filter_map { |group| [group, counts[group.id]] if counts[group.id] }
  end

  private

  def was_global?
    name_in_database == GLOBAL_NAME && parent_id_in_database.nil?
  end

  def global_stays_put
    return unless was_global? && (name_changed? || parent_id_changed?)

    errors.add(:base, "Global can't be renamed or moved — everyone signed in relies on it")
  end

  # Nobody joins Global, so the setting would mean nothing while Global's page
  # announced it. The form never offers it; this refuses a hand-built request.
  def global_is_not_kept_to_administrators
    return unless global? && admins_add_members?

    errors.add(:admins_add_members, "can't be set on Global, which everyone signed in already sees")
  end

  def nothing_nests_under_global
    return if parent_id.blank?
    return unless Group.global.exists?(id: parent_id)

    errors.add(:parent_id, "can't be Global — Global has no subgroups")
  end

  def refuse_to_destroy_global
    return unless was_global?

    errors.add(:base, "Global can't be deleted")
    throw :abort
  end

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

  # Groups nest up to MAX_DEPTH levels. Checked when a group is created or moved,
  # and a move checks the whole subtree it carries: checking only the moved group
  # let a three-level subtree land under a fourth-level group, its lowest group at
  # level 7 (spec Q62). A group already too deep can still be renamed.
  def max_depth_allowed
    return unless new_record? || will_save_change_to_parent_id?

    own_depth = if parent_id && parent&.persisted?
                  parent.depth + 1
                else
                  parent_id ? 1 : 0
                end
    deepest = own_depth + subtree_height
    return if deepest < MAX_DEPTH

    message = "maximum depth of #{MAX_DEPTH} levels exceeded"
    message += ": its deepest subgroup would be at level #{deepest + 1}" if deepest > own_depth
    errors.add(:parent_id, message)
  end
end
