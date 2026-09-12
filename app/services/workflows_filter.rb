class WorkflowsFilter
  attr_reader :workflows, :selected_group, :selected_ancestor_ids,
              :folders, :unfiled_workflows, :workflows_by_folder,
              :accessible_groups, :total_count, :total_pages, :page,
              :workflows_paginated, :group_error

  # Sized for the card grid and folder accordion, not admin's [10, 25, 50].
  # 24 is the default so a real library is not 14 pages of six cards.
  PER_PAGE_OPTIONS = [6, 12, 24].freeze
  DEFAULT_PER_PAGE = 24

  # Admin-only: published workflows filed in no group. The Overview links here.
  NO_AUDIENCE = "none".freeze

  # Anyone's own workflows. The home page's "View all" and "+N more" link here.
  OWNER_ME = "me".freeze

  def initialize(user:, params:)
    @user = user
    @params = params
    @group_error = nil
  end

  def call
    build_base_scope
    apply_audience_filter
    apply_owner_filter
    apply_search
    apply_sort
    apply_group_filter
    load_folder_data
    load_sidebar_groups
    paginate
    self
  end

  def status_filter
    @params[:status].presence || "all"
  end

  def sort_by
    @params[:sort].presence || "recent"
  end

  def search_query
    @params[:search]
  end

  def audience_filter
    @params[:audience] == NO_AUDIENCE && @user.admin? ? NO_AUDIENCE : nil
  end

  def owner_filter
    @params[:owner] == OWNER_ME ? OWNER_ME : nil
  end

  def per_page_size = per_page

  # nil for an admin, who may open every group; otherwise the groups this person
  # reaches. The breadcrumb links only these — above a subgroup someone was
  # given, the parent groups are theirs to read, not to open.
  def linkable_group_ids
    return nil if @user.admin?

    @linkable_group_ids ||= Group.reachable_ids_for(@user).to_set
  end

  private

  def build_base_scope
    # Every branch resolves through the viewer's permission scope. The draft
    # branches used to hardcode `@user.workflows.drafts` for every role, so the
    # Drafts tab sat in a strip whose siblings were org-wide while it silently
    # showed only your own — an admin got "No workflows" against 23 real drafts,
    # and the sidebar count flipped to 0. See Workflow.drafts_visible_to.
    @workflows = case status_filter
                 when "draft"
                   Workflow.drafts_visible_to(@user)
                 when "published"
                   Workflow.visible_to(@user)
                 else
                   published_ids = Workflow.visible_to(@user).select(:id)
                   draft_ids = Workflow.drafts_visible_to(@user).select(:id)
                   Workflow.where(id: published_ids).or(Workflow.where(id: draft_ids))
                 end

    @workflows = @workflows.includes(:user, group_workflows: :group)
  end

  def apply_audience_filter
    return unless audience_filter

    @workflows = @workflows.where(id: Workflow.published_without_audience.select(:id))
  end

  def apply_owner_filter
    return unless owner_filter

    @workflows = @workflows.where(user: @user)
  end

  def apply_search
    @workflows = @workflows.search_by(@params[:search])
  end

  def apply_sort
    @workflows = case sort_by
                 when "alphabetical"
                   @workflows.order(Arel.sql("LOWER(title) ASC"))
                 when "most_steps"
                   @workflows.order(steps_count: :desc)
                 else
                   @workflows.order(updated_at: :desc)
                 end
  end

  def apply_group_filter
    @selected_group = nil
    @selected_ancestor_ids = []

    return if @params[:group_id].blank?

    potential_group = Group.find_by(id: @params[:group_id])
    if potential_group&.can_be_viewed_by?(@user)
      @selected_group = Group.includes(parent: { parent: { parent: { parent: :parent } } })
                             .find_by(id: @params[:group_id])
      @selected_ancestor_ids = @selected_group&.ancestors&.map(&:id) || []
      @workflows = @workflows.in_group(@selected_group)
    else
      @group_error = "You don't have permission to view this group."
    end
  rescue StandardError => e
    Rails.logger.error "Error loading group #{@params[:group_id]}: #{e.message}\n#{e.backtrace.join("\n")}"
    @group_error = "An error occurred while loading the group."
  end

  def load_folder_data
    return if @selected_group.blank?

    @folders = @selected_group.folders.ordered
    @unfiled_workflows = @selected_group.unfiled_workflows
                                        .includes(:user)
                                        .search_by(@params[:search])
    @unfiled_workflows = case sort_by
                         when "alphabetical"
                           @unfiled_workflows.order(Arel.sql("LOWER(title) ASC"))
                         when "most_steps"
                           @unfiled_workflows.order(steps_count: :desc)
                         else
                           @unfiled_workflows.order(updated_at: :desc)
                         end

    return if @folders.blank?

    @workflows_by_folder = {}
    @folders.each do |folder|
      @workflows_by_folder[folder.id] = @workflows.joins(:group_workflows)
                                                  .where(group_workflows: { folder_id: folder.id })
    end
  end

  # The groups this person reaches, from their top-most reachable level, Global
  # first and then by name ignoring case (spec Q38, Q50). It listed roots, so an
  # editor given only a subgroup had nothing to click.
  def load_sidebar_groups
    @accessible_groups = sidebar_tops.sort_by { [it.global? ? 0 : 1, it.name.downcase] }

    all_sidebar_groups = @accessible_groups + @accessible_groups.flat_map(&:children)
    return if all_sidebar_groups.empty?

    # Scoped to what this viewer can actually open, and to the tab they are on,
    # so a group's number and the list it opens are the same number.
    Group.precompute_workflows_counts(all_sidebar_groups, visible_ids: @workflows.reselect(:id))
  end

  def sidebar_tops
    return Group.roots.includes(:children).to_a if @user.admin?

    reachable = linkable_group_ids
    Group.where(id: reachable.to_a).includes(:children).reject { reachable.include?(it.parent_id) }
  end

  def paginate
    @page = [(@params[:page] || 1).to_i, 1].max
    @total_count = @workflows.count
    @total_pages = [(@total_count.to_f / per_page).ceil, 1].max
    @page = [@page, @total_pages].min
    @workflows_paginated = @workflows.limit(per_page).offset((@page - 1) * per_page)
  end

  # Anything not on the allowlist — junk, an out-of-range number, a missing
  # param — falls back to the default rather than erroring or trusting input.
  def per_page
    size = @params[:per_page].to_i
    PER_PAGE_OPTIONS.include?(size) ? size : DEFAULT_PER_PAGE
  end
end
