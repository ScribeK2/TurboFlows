class Workflow < ApplicationRecord
  include WorkflowAuthorization
  include WorkflowNormalization
  include StepTypeIcons
  include WorkflowStepValidation

  belongs_to :user

  # Group associations
  has_many :group_workflows, dependent: :destroy
  has_many :groups, through: :group_workflows

  # Tag associations
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings

  # Scenario associations
  has_many :scenarios, dependent: :destroy

  # Set draft expiration before save (7 days from creation or update)
  before_save :set_draft_expiration, if: :draft?
  # Assign to Uncategorized group if no groups assigned (only for published workflows)
  after_create :assign_to_uncategorized_if_needed, if: :published?
  # ActiveRecord step associations (parallel to JSONB during migration)
  # IMPORTANT: nullify_start_step must run BEFORE dependent :destroy on steps
  # to avoid circular FK constraint (workflows.start_step_id → steps.id)
  before_destroy :nullify_published_version, prepend: true
  before_destroy :nullify_start_step, prepend: true
  has_many :steps, -> { order(:position) }, class_name: "Step", dependent: :destroy
  belongs_to :start_step, class_name: "Step", optional: true
  has_rich_text :description

  # Versioning associations
  has_many :versions, class_name: "WorkflowVersion", dependent: :destroy
  belongs_to :published_version, class_name: "WorkflowVersion", optional: true

  # Find workflows that reference a given workflow as a sub-flow step (via AR steps)
  def self.referencing_as_subflow(target_workflow_id)
    joins(:steps).where(steps: { type: "Steps::SubFlow", sub_flow_workflow_id: target_workflow_id })
  end

  # Steps stored as JSON - automatically serialized/deserialized
  validates :title, presence: true, length: { maximum: 255 }
  validates :user_id, presence: true
  validate :validate_graph_structure, if: :should_validate_graph_structure?
  validate :validate_subflow_steps
  validate :validate_subflow_circular_references, if: :has_subflow_steps?

  # Valid step types for workflows
  # Note: sub_flow is used for calling other workflows as sub-routines
  # Note: message, escalate, resolve are Graph Mode step types
  VALID_STEP_TYPES = %w[question action sub_flow message escalate resolve].freeze

  # Size limits to prevent DoS and ensure performance
  # These can be overridden via environment variables if needed
  MAX_STEPS = ENV.fetch("WORKFLOW_MAX_STEPS", 200).to_i
  MAX_STEP_TITLE_LENGTH = 500
  MAX_STEP_CONTENT_LENGTH = 50_000  # 50KB per step field
  MAX_TOTAL_STEPS_SIZE = 5_000_000  # 5MB total for steps JSON

  enum :status, { draft: "draft", published: "published" }, default: "published"

  scope :recent, -> { order(created_at: :desc) }
  scope :public_workflows, -> { where(is_public: true) }

  # Draft workflow scopes
  scope :drafts, -> { draft }
  scope :expired_drafts, -> { draft.where('draft_expires_at < ?', Time.current) }

  # Get workflows visible to a specific user
  # Admins see all, Editors see own + public, Users see only public
  # Also respects group membership: users see workflows in their assigned groups
  # Handles workflows without groups gracefully (they're accessible to everyone)
  #
  # Access Control Rules:
  # - Admins: See all workflows regardless of group assignment
  # - Editors: See their own workflows + all public workflows + workflows in assigned groups
  # - Users: See public workflows + workflows in assigned groups
  # - Workflows without groups: Accessible to all users (backward compatibility)
  # - Drafts: Excluded from main workflow list (only accessible via wizard routes)
  #
  # Group Access:
  # - Users assigned to a parent group can see workflows in child groups
  # - Workflows are visible if user is assigned to any group containing the workflow
  scope :visible_to, lambda { |user|
    # Exclude drafts from main workflow list
    base_scope = published

    if user&.admin?
      # Admins see all workflows
      base_scope
    elsif user&.editor?
      # Editors see their own workflows + all public workflows + workflows in assigned groups
      if user.groups&.any?
        # Use optimized single-query method to get all accessible group IDs
        accessible_group_ids = Group.accessible_group_ids_for(user)
        # Use subquery to avoid DISTINCT on JSONB column - select only ID for distinct operation
        distinct_ids = base_scope.left_joins(:groups)
                                 .where("workflows.user_id = ? OR workflows.is_public = ? OR groups.id IN (?) OR groups.id IS NULL",
                                        user.id, true, accessible_group_ids)
                                 .select("DISTINCT workflows.id")
        base_scope.where(id: distinct_ids)
      else
        # No group assignments: own workflows + public workflows
        base_scope.where(user: user).or(base_scope.where(is_public: true))
      end
    elsif user&.groups&.any?
      # Users: See public workflows + workflows in assigned groups + workflows without groups
      accessible_group_ids = Group.accessible_group_ids_for(user)
      # Public workflows OR workflows in user's groups OR workflows without groups
      public_workflows = base_scope.where(is_public: true)
      group_workflows = base_scope.joins(:groups).where(groups: { id: accessible_group_ids })
      workflows_without_groups = base_scope.where.missing(:groups)
      base_scope.where(id: public_workflows.select(:id))
                .or(base_scope.where(id: group_workflows.select(:id)))
                .or(base_scope.where(id: workflows_without_groups.select(:id)))
    # Use optimized single-query method to get all accessible group IDs
    else
      # No group assignments: only public workflows + workflows without groups (backward compatibility)
      # Note: Workflows in Uncategorized group are NOT included for users without group assignments
      public_workflows = base_scope.where(is_public: true)
      workflows_without_groups = base_scope.where.missing(:groups)
      base_scope.where(id: public_workflows.select(:id))
                .or(base_scope.where(id: workflows_without_groups.select(:id)))
    end
  }

  # Filter workflows by group (includes workflows in descendant groups)
  # If group is nil, returns workflows without groups (for backward compatibility)
  #
  # Example: If "Customer Support" has child "Phone Support",
  # in_group(Customer Support) returns workflows in both groups
  scope :in_group, lambda { |group|
    return where.not(id: joins(:groups).select(:id)) if group.nil?

    # Get group and all its descendants using optimized method
    # This avoids N+1 queries by using a single efficient query
    descendant_ids = group.descendant_ids
    group_ids = [group.id] + descendant_ids
    # Use pluck to get distinct IDs, then query by those IDs
    # Unscope order to avoid PostgreSQL DISTINCT/ORDER BY conflict
    # This ensures we can pluck IDs without ORDER BY interfering
    distinct_ids = joins(:groups).where(groups: { id: group_ids }).unscope(:order).distinct.pluck(:id)
    where(id: distinct_ids)
  }

  # Search workflows by title and description (fuzzy matching)
  # Searches both title and description fields with case-insensitive queries
  # Uses ILIKE for PostgreSQL, LIKE for SQLite (which is case-insensitive by default)
  scope :search_by, lambda { |query|
    return all if query.blank?

    search_term = "%#{sanitize_sql_like(query.strip)}%"

    title_matches = case_insensitive_like('title', search_term)

    # Search Action Text description via rich text join
    desc_ids = ActionText::RichText
               .where(record_type: "Workflow", name: "description")
               .where("body LIKE ?", search_term)
               .select(:record_id)

    where(id: title_matches.select(:id))
      .or(where(id: desc_ids))
  }

  # Helper method to get description as plain text
  def description_text
    return nil if description.blank?
    description.to_plain_text.squish
  end

  # Helper method to check if description exists
  def has_description?
    description.present?
  end

  # Clean up import flags when steps are completed
  # Assign workflow to Uncategorized group if no groups are assigned
  def assign_to_uncategorized_if_needed
    return if groups.any?

    uncategorized_group = Group.uncategorized
    GroupWorkflow.find_or_create_by!(
      workflow: self,
      group: uncategorized_group,
      is_primary: true
    )
  end

  # Set draft expiration timestamp (7 days from now)
  def set_draft_expiration
    self.draft_expires_at = 7.days.from_now if draft?
  end

  # Determine if graph structure validation should run
  # Only validate graph structure when publishing, not during draft saves.
  # This allows incremental workflow building without requiring all steps
  # to be connected before saving.
  def should_validate_graph_structure?
    published? || @validate_graph_now
  end

  # Force graph validation on next save (for explicit validation requests)
  def validate_graph_now!
    @validate_graph_now = true
  end

  # Class method to cleanup expired drafts
  # Can be called from a scheduled job
  def self.cleanup_expired_drafts
    expired_drafts.delete_all
  end

  # Group helper methods
  def primary_group
    if group_workflows.loaded?
      return nil if group_workflows.empty?
      group_workflows.detect { |gw| gw.is_primary? }&.group || group_workflows.first&.group
    else
      group_workflows.find_by(is_primary: true)&.group || groups.first
    end
  end

  def all_groups
    groups
  end

  # ============================================================================
  # Step Reference Helpers (AR-based)
  # ============================================================================

  # Find a step by its UUID
  def find_step_by_uuid(uuid)
    return nil unless uuid.present?
    steps.find_by(uuid: uuid)
  end

  # Find a step by its title (case-insensitive fallback)
  def find_step_by_title(title)
    return nil unless title.present?
    steps.find_by(title: title) ||
      steps.where("LOWER(title) = ?", title.downcase).first
  end

  # Resolve a step reference (UUID or title) to a UUID
  def resolve_step_reference_to_id(reference)
    return nil if reference.blank?
    step = find_step_by_uuid(reference) || find_step_by_title(reference)
    step&.uuid
  end

  # Resolve a step reference (UUID or title) to a title for display
  def resolve_step_reference_to_title(reference)
    return nil if reference.blank?
    step = find_step_by_uuid(reference) || find_step_by_title(reference)
    step&.title
  end

  # Get step options for select dropdowns
  def step_options_for_select
    steps.map.with_index do |step, index|
      next nil unless step.title.present?
      {
        id: step.uuid,
        title: step.title,
        type: step.step_type,
        index: index,
        display_name: "#{index + 1}. #{step.title}",
        type_icon: step_type_icon(step.step_type)
      }
    end.compact
  end

  # Count steps by type, returns hash like { 'question' => 3, 'action' => 2, ... }
  def step_type_counts
    steps.reorder(nil).group(:type).count.transform_keys { |k| k.demodulize.underscore }
  end

  # Returns the most common step type in this workflow
  def dominant_step_type
    step_type_counts.max_by { |_, count| count }&.first
  end

  # Get variables with their metadata (answer type, options) for condition builders
  def variables_with_metadata
    steps.where(type: "Steps::Question").where.not(variable_name: [nil, ""]).map do |step|
      {
        name: step.variable_name,
        title: step.title,
        answer_type: step.answer_type,
        options: step.options || [],
        display_name: "#{step.title} (#{step.variable_name})"
      }
    end
  end

  # ============================================================================
  # Graph Mode Support
  # ============================================================================

  # All workflows are now graph mode — column kept for backward compatibility
  def graph_mode?
    true
  end

  # Linear mode is no longer supported
  def linear_mode?
    false
  end

  # Get steps as a hash keyed by UUID for graph-based operations
  def graph_steps
    steps.includes(:transitions).index_by(&:uuid)
  end

  # Get the starting node for graph traversal
  def start_node
    start_step || steps.first
  end

  # Get all terminal steps (no outgoing transitions)
  def terminal_nodes
    steps.where.missing(:transitions)
  end

  # Get sub-flow steps
  def subflow_steps
    steps.where(type: "Steps::SubFlow")
  end

  # Get all workflow IDs referenced as sub-flows
  def referenced_workflow_ids
    subflow_steps.pluck(:sub_flow_workflow_id).compact.uniq
  end

  # Check if this workflow has any sub-flow steps
  def has_subflow_steps?
    steps.exists?(type: "Steps::SubFlow")
  end

  private

  def nullify_published_version
    update_columns(published_version_id: nil) if published_version_id.present?
  end

  def nullify_start_step
    update_columns(start_step_id: nil) if start_step_id.present?
    # Delete all transitions and Action Text records referencing this workflow's steps
    # to avoid FK constraint violations during cascading step deletion
    step_ids = steps.pluck(:id)
    if step_ids.any?
      Transition.where(step_id: step_ids).or(Transition.where(target_step_id: step_ids)).delete_all
      ActionText::RichText.where(record_type: "Step", record_id: step_ids).delete_all
    end
  end

  # Validate graph structure (only in graph mode)
  # Uses GraphValidator service for comprehensive checks via AR steps
  def validate_graph_structure
    return unless steps.any?

    graph_steps_hash = {}
    steps.includes(:transitions).find_each do |step|
      graph_steps_hash[step.uuid] = {
        "id" => step.uuid,
        "type" => step.type.demodulize.underscore,
        "title" => step.title,
        "transitions" => step.transitions.map { |t| { "target_uuid" => t.target_step.uuid, "condition" => t.condition } }
      }
    end

    start_uuid = start_step&.uuid || steps.first&.uuid
    validator = GraphValidator.new(graph_steps_hash, start_uuid)

    unless validator.valid?
      validator.errors.each do |error|
        errors.add(:steps, error)
      end
    end
  end

  # Validate sub-flow step references (using AR steps)
  def validate_subflow_steps
    sf_steps = steps.where(type: "Steps::SubFlow")
    return unless sf_steps.any?

    # Batch-load all target workflows to avoid N+1 queries
    target_ids = sf_steps.where.not(sub_flow_workflow_id: nil).pluck(:sub_flow_workflow_id)
    target_workflows = Workflow.where(id: target_ids).index_by(&:id)

    sf_steps.each do |step|
      if step.sub_flow_workflow_id.blank?
        errors.add(:steps, "Step #{step.position + 1}: Sub-flow step requires a target workflow")
        next
      end

      target_workflow = target_workflows[step.sub_flow_workflow_id]
      unless target_workflow
        errors.add(:steps, "Step #{step.position + 1}: Target workflow #{step.sub_flow_workflow_id} does not exist")
        next
      end

      unless target_workflow.published?
        errors.add(:steps, "Step #{step.position + 1}: Target workflow '#{target_workflow.title}' is not published")
      end

      if step.sub_flow_workflow_id == id
        errors.add(:steps, "Step #{step.position + 1}: Sub-flow cannot reference itself")
      end
    end
  end

  # Validate no circular sub-flow references exist
  def validate_subflow_circular_references
    return unless persisted? # Only check on existing workflows

    validator = SubflowValidator.new(id)

    unless validator.valid?
      validator.errors.each do |error|
        errors.add(:steps, error)
      end
    end
  end

end
