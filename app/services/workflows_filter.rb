class WorkflowsFilter
  attr_reader :workflows, :selected_group, :selected_ancestor_ids,
              :folders, :uncategorized_workflows, :workflows_by_folder,
              :accessible_groups, :total_count, :total_pages, :page,
              :workflows_paginated, :group_error

  # Sized for the card grid and folder accordion, not admin's [10, 25, 50]:
  # six divides the grid cleanly and 25 cards in an accordion reads as broken.
  PER_PAGE_OPTIONS = [6, 12, 24].freeze
  DEFAULT_PER_PAGE = 6

  def initialize(user:, params:)
    @user = user
    @params = params
    @group_error = nil
  end

  def call
    build_base_scope
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

  def per_page_size = per_page

  private

  def build_base_scope
    @workflows = case status_filter
                 when "draft"
                   @user.workflows.drafts
                 when "published"
                   Workflow.visible_to(@user)
                 else
                   published_ids = Workflow.visible_to(@user).select(:id)
                   own_draft_ids = @user.workflows.drafts.select(:id)
                   Workflow.where(id: published_ids).or(Workflow.where(id: own_draft_ids))
                 end

    @workflows = @workflows.includes(:user, group_workflows: :group)
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
    @uncategorized_workflows = @selected_group.uncategorized_workflows
                                              .includes(:user)
                                              .search_by(@params[:search])
    @uncategorized_workflows = case sort_by
                               when "alphabetical"
                                 @uncategorized_workflows.order(Arel.sql("LOWER(title) ASC"))
                               when "most_steps"
                                 @uncategorized_workflows.order(steps_count: :desc)
                               else
                                 @uncategorized_workflows.order(updated_at: :desc)
                               end

    return if @folders.blank?

    @workflows_by_folder = {}
    @folders.each do |folder|
      @workflows_by_folder[folder.id] = @workflows.joins(:group_workflows)
                                                  .where(group_workflows: { folder_id: folder.id })
    end
  end

  def load_sidebar_groups
    @accessible_groups = Group.visible_to(@user)
                              .roots
                              .includes(:children)
                              .order(:position, :name)

    all_sidebar_groups = @accessible_groups.to_a + @accessible_groups.flat_map(&:children)
    Group.precompute_workflows_counts(all_sidebar_groups) if all_sidebar_groups.any?
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
