class Workflow < ApplicationRecord
  include WorkflowAuthorization
  include WorkflowNormalization
  include StepTypeIcons
  include WorkflowStepValidation

  MARKDOWN_RENDERER = Redcarpet::Markdown.new(Redcarpet::Render::HTML.new)

  belongs_to :user

  # Group associations
  has_many :group_workflows, dependent: :destroy
  has_many :groups, through: :group_workflows

  # Scenario associations
  has_many :scenarios, dependent: :destroy

  # Sub-flow associations: track which workflows reference this one as a sub-flow
  has_many :referencing_workflows, class_name: 'Workflow', foreign_key: 'id', primary_key: 'id' do
    def with_subflow_references(target_workflow_id)
      # Find workflows with steps that reference target_workflow_id as a sub_flow
      # This is a custom query since the reference is in JSON
      where("steps::text LIKE ?", "%\"target_workflow_id\":#{target_workflow_id}%")
    end
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

  # Keep steps_count in sync with steps array
  before_save :update_steps_count
  # Clean up import flags when steps are completed
  before_save :cleanup_import_flags
  # Set draft expiration before save (7 days from creation or update)
  before_save :set_draft_expiration, if: -> { status == 'draft' }
  # Assign to Uncategorized group if no groups assigned (only for published workflows)
  after_create :assign_to_uncategorized_if_needed, if: -> { status == 'published' || status.nil? }

  scope :recent, -> { order(created_at: :desc) }
  scope :public_workflows, -> { where(is_public: true) }

  # Draft workflow scopes
  scope :drafts, -> { where(status: 'draft') }
  scope :published, -> { where(status: 'published') }
  scope :expired_drafts, -> { drafts.where('draft_expires_at < ?', Time.current) }

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

    search_term = "%#{query.strip}%"

    title_matches = case_insensitive_like('title', search_term)
    desc_matches = case_insensitive_like('description', search_term)

    where(id: title_matches.select(:id))
      .or(where(id: desc_matches.select(:id)))
  }

  # Helper method to get description as plain text (strips markdown syntax)
  def description_text
    return nil if description.blank?

    ActionController::Base.helpers.strip_tags(
      MARKDOWN_RENDERER.render(description)
    ).squish
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
    self.draft_expires_at = 7.days.from_now if status == 'draft'
  end

  # Check if workflow is a draft
  def draft?
    status == 'draft'
  end

  # Check if workflow is published
  def published?
    status == 'published' || status.nil?
  end

  # Determine if graph structure validation should run
  # Only validate graph structure when publishing, not during draft saves.
  # This allows incremental workflow building without requiring all steps
  # to be connected before saving.
  def should_validate_graph_structure?
    graph_mode? && (status == 'published' || @validate_graph_now)
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

  def cleanup_import_flags
    return unless steps.present?

    self.steps = steps.map do |step|
      next step unless step.is_a?(Hash)

      # Check if step is now complete
      is_complete = case step['type']
                    when 'question'
                      step['question'].present?
                    when 'action'
                      step['instructions'].present?
                    else
                      true
                    end

      # Remove import flags if step is complete
      if is_complete && step['_import_incomplete']
        step.delete('_import_incomplete')
        step.delete('_import_errors')
      end

      step
    end
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
  # ID-Based Step Reference Helpers (Sprint 1: Decision Step Revolution)
  # These methods support ID-based step references instead of title-based,
  # making workflows more robust when steps are renamed.
  # ============================================================================

  # Find a step by its ID
  # Returns the step hash or nil if not found
  def find_step_by_id(step_id)
    return nil unless steps.present? && step_id.present?

    steps.find { |step| step['id'] == step_id }
  end

  # Find a step by its title (for backward compatibility)
  # Returns the step hash or nil if not found
  # Uses case-insensitive fallback if exact match not found
  def find_step_by_title(title)
    return nil unless steps.present? && title.present?

    # Exact match first
    step = steps.find { |step| step['title'] == title }
    return step if step

    # Case-insensitive fallback
    steps.find { |step| step['title']&.downcase == title.downcase }
  end

  # Get step info for display purposes
  # Returns an array of hashes with id, title, type, and index
  def step_options_for_select
    return [] unless steps.present?

    steps.map.with_index do |step, index|
      next nil unless step.is_a?(Hash) && step['title'].present?

      {
        id: step['id'],
        title: step['title'],
        type: step['type'],
        index: index,
        display_name: "#{index + 1}. #{step['title']}",
        type_icon: step_type_icon(step['type'])
      }
    end.compact
  end

  # Count steps by type, returns hash like { 'question' => 3, 'action' => 2, ... }
  def step_type_counts
    return {} unless steps.present?

    steps.each_with_object(Hash.new(0)) { |step, counts| counts[step['type']] += 1 if step['type'].present? }
  end

  # Returns the most common step type in this workflow
  def dominant_step_type
    step_type_counts.max_by { |_, count| count }&.first
  end

  # Get variables with their metadata (answer type, options) for condition builders
  # Returns an array of hashes with variable info
  def variables_with_metadata
    return [] unless steps.present?

    steps.select { |step| step['type'] == 'question' && step['variable_name'].present? }
         .map do |step|
           {
             name: step['variable_name'],
             title: step['title'],
             answer_type: step['answer_type'],
             options: step['options'] || [],
             display_name: "#{step['title']} (#{step['variable_name']})"
           }
         end
  end

  # Convert a step reference (title or ID) to ID
  # Used for migrating from title-based to ID-based references
  def resolve_step_reference_to_id(reference)
    return nil if reference.blank?

    # If it looks like a UUID, assume it's already an ID
    if reference.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i) && find_step_by_id(reference)
      # Verify the ID exists
      return reference
    end

    # Otherwise, treat it as a title and find the corresponding ID
    step = find_step_by_title(reference)
    step&.dig('id')
  end

  # Convert a step reference (ID or title) to title for display
  # Used for displaying step references in the UI
  def resolve_step_reference_to_title(reference)
    return nil if reference.blank?

    # If it looks like a UUID, find the step and return its title
    if reference.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
      step = find_step_by_id(reference)
      return step['title'] if step
    end

    # Otherwise, it might already be a title (backward compatibility)
    # Verify the title exists
    step = find_step_by_title(reference)
    step ? reference : nil
  end

  # Migrate all step references in branches from title-based to ID-based
  # This is idempotent - safe to run multiple times
  # Deprecated: decision steps have been removed. This method is a no-op.
  def migrate_step_references_to_ids!
    false
  end

  # ============================================================================
  # Graph Mode Support (DAG-Based Workflow)
  # These methods support the graph-based workflow structure where steps are
  # connected via explicit transitions rather than sequential array order.
  # ============================================================================

  # Check if workflow is in graph mode
  def graph_mode?
    graph_mode == true
  end

  # Check if workflow is in linear (array-based) mode
  def linear_mode?
    !graph_mode?
  end

  # Get steps as a hash keyed by UUID for graph-based operations
  # Returns { "uuid-1" => step_hash, "uuid-2" => step_hash, ... }
  def graph_steps
    return {} unless steps.present?

    steps.each_with_object({}) do |step, hash|
      next unless step.is_a?(Hash) && step['id'].present?

      hash[step['id']] = step
    end
  end

  # Get the starting node for graph traversal
  # Returns the step hash of the start node, or nil if not found
  def start_node
    return nil unless steps.present?

    if start_node_uuid.present?
      find_step_by_id(start_node_uuid)
    else
      # Default to first step if no start node is set
      steps.first
    end
  end

  # Get all terminal nodes (steps with no outgoing transitions)
  # In graph mode, a terminal node has no transitions array or an empty one
  def terminal_nodes
    return [] unless steps.present?

    if graph_mode?
      steps.select do |step|
        transitions = step['transitions'] || []
        transitions.empty? && step['type'] != 'sub_flow'
      end
    else
      # In linear mode, the last step is the terminal
      [steps.last].compact
    end
  end

  # Get all transitions from a given step
  # Returns array of { condition: string, target_uuid: string } hashes
  def transitions_from(step_or_id)
    step = step_or_id.is_a?(Hash) ? step_or_id : find_step_by_id(step_or_id)
    return [] unless step

    step['transitions'] || []
  end

  # Get all steps that transition to a given step
  # Returns array of step hashes
  def steps_leading_to(step_or_id)
    target_id = step_or_id.is_a?(Hash) ? step_or_id['id'] : step_or_id
    return [] unless target_id && steps.present?

    steps.select do |step|
      transitions = step['transitions'] || []
      transitions.any? { |t| t['target_uuid'] == target_id }
    end
  end

  # Add a transition between two steps (graph mode only)
  # condition: optional condition string for the transition
  # Returns true if successful, false otherwise
  def add_transition(from_step_id, to_step_id, condition: nil)
    return false unless graph_mode?

    from_step = find_step_by_id(from_step_id)
    to_step = find_step_by_id(to_step_id)
    return false unless from_step && to_step

    from_step['transitions'] ||= []

    # Don't add duplicate transitions
    existing = from_step['transitions'].find { |t| t['target_uuid'] == to_step_id }
    return false if existing

    transition = { 'target_uuid' => to_step_id }
    transition['condition'] = condition if condition.present?
    from_step['transitions'] << transition

    true
  end

  # Remove a transition between two steps (graph mode only)
  # Returns true if successful, false otherwise
  def remove_transition(from_step_id, to_step_id)
    return false unless graph_mode?

    from_step = find_step_by_id(from_step_id)
    return false unless from_step

    from_step['transitions'] ||= []
    initial_count = from_step['transitions'].length
    from_step['transitions'].reject! { |t| t['target_uuid'] == to_step_id }

    from_step['transitions'].length < initial_count
  end

  # Convert this workflow from linear to graph mode
  # This creates explicit transitions based on the current step order
  # Returns true if conversion was successful
  def convert_to_graph_mode!
    return true if graph_mode?
    return false unless steps.present?

    require_relative '../services/workflow_graph_converter'
    converter = WorkflowGraphConverter.new(self)
    converted_steps = converter.convert

    if converted_steps
      self.steps = converted_steps
      self.graph_mode = true
      self.start_node_uuid = steps.first&.dig('id')
      save
    else
      false
    end
  end

  # Get sub-flow step configuration
  def subflow_steps
    return [] unless steps.present?

    steps.select { |step| step['type'] == 'sub_flow' }
  end

  # Get all workflow IDs referenced as sub-flows
  def referenced_workflow_ids
    subflow_steps.map { |step| step['target_workflow_id'] }.compact.uniq
  end

  # Check if this workflow has any sub-flow steps
  def has_subflow_steps?
    subflow_steps.any?
  end

  # Convert workflow to template format
  # Returns a hash with template attributes
  def convert_to_template(name: nil, category: nil, description: nil, is_public: true)
    {
      name: name || title,
      description: description || description_text,
      category: category || "custom",
      workflow_data: steps || [],
      is_public: is_public
    }
  end

  private

  def update_steps_count
    self.steps_count = steps.is_a?(Array) ? steps.size : 0
  end

  # Validate graph structure (only in graph mode)
  # Uses GraphValidator service for comprehensive checks
  def validate_graph_structure
    return unless graph_mode? && steps.present?

    require_relative '../services/graph_validator'
    validator = GraphValidator.new(graph_steps, start_node_uuid || steps.first&.dig('id'))

    unless validator.valid?
      validator.errors.each do |error|
        errors.add(:steps, error)
      end
    end
  end

  # Validate sub-flow step references
  def validate_subflow_steps
    return unless steps.present?

    subflow_steps.each_with_index do |step, _|
      step_index = steps.index(step) + 1
      next if step['_import_incomplete'] == true

      target_id = step['target_workflow_id']

      if target_id.blank?
        errors.add(:steps, "Step #{step_index}: Sub-flow step requires a target workflow")
        next
      end

      # Check that target workflow exists
      target_workflow = Workflow.find_by(id: target_id)
      unless target_workflow
        errors.add(:steps, "Step #{step_index}: Target workflow #{target_id} does not exist")
        next
      end

      # Check that target workflow is published
      unless target_workflow.published?
        errors.add(:steps, "Step #{step_index}: Target workflow '#{target_workflow.title}' is not published")
      end

      # Check for circular references (self-reference)
      if target_id.to_i == id
        errors.add(:steps, "Step #{step_index}: Sub-flow cannot reference itself")
      end
    end

    # Deep circular reference check is handled by SubflowValidator during save
  end

  # Validate no circular sub-flow references exist
  def validate_subflow_circular_references
    return unless persisted? # Only check on existing workflows

    require_relative '../services/subflow_validator'
    validator = SubflowValidator.new(id)

    unless validator.valid?
      validator.errors.each do |error|
        errors.add(:steps, error)
      end
    end
  end

end
