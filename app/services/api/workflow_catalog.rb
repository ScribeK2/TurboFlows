module Api
  # What a token may see, and how the API describes it. The REST controllers
  # and the MCP tools both call only this, so they cannot disagree about
  # visibility (spec 2026-09-25-api-and-mcp-design §2).
  #
  # Visible = published workflows the user can see (Workflow.visible_to) plus
  # the drafts they can see (Workflow.drafts_visible_to: their own; an admin's
  # is all). Existing rules, not new ones.
  class WorkflowCatalog
    PER_PAGE = 25

    class InvalidFilter < StandardError; end

    Page = Data.define(:workflows, :next_page)

    def initialize(user, base_url:)
      @user = user
      @base_url = base_url
      @group_paths = {}
    end

    def search(q: nil, tag: nil, group: nil, status: nil, page: nil)
      page = [page.to_i, 1].max
      scope = visible
      scope = scope.search_by(q) if q.present?
      scope = scope.where(id: Tagging.joins(:tag).where(tags: { name: tag }).select(:workflow_id)) if tag.present?
      scope = scope.in_group(find_group(group)) if group.present?
      scope = scope.where(status: checked_status(status)) if status.present?

      rows = scope.includes(:tags, :rich_text_description, group_workflows: :group)
                  .order(updated_at: :desc, id: :desc)
                  .offset((page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
      Page.new(workflows: rows.first(PER_PAGE), next_page: rows.size > PER_PAGE ? page + 1 : nil)
    end

    delegate :find, to: :visible

    def summary(workflow)
      {
        id: workflow.id,
        title: workflow.title,
        description: workflow.description_text.to_s,
        status: workflow.status,
        tags: workflow.tags.map(&:name).sort,
        groups: workflow.group_workflows.sort_by { |gw| [gw.is_primary? ? 0 : 1, gw.group_id] }
                        .map { group_path(it.group) },
        updated_at: workflow.updated_at.iso8601,
        url: url_for(workflow)
      }
    end

    def document(workflow)
      { id: workflow.id, status: workflow.status, url: url_for(workflow), document: workflow.to_strict_document }
    end

    def url_for(workflow)
      @base_url + Rails.application.routes.url_helpers.workflow_path(workflow)
    end

    private

    def visible
      Workflow.where(id: Workflow.visible_to(@user).select(:id))
              .or(Workflow.where(id: Workflow.drafts_visible_to(@user).select(:id)))
    end

    def find_group(id)
      Group.find_by(id: id) || raise(InvalidFilter, "No group has id #{id.inspect}.")
    end

    def checked_status(status)
      return status if Workflow.statuses.key?(status)

      raise InvalidFilter, "status must be one of #{Workflow.statuses.keys.join(', ')}."
    end

    # Group#name_path walks ancestors, so one lookup per group per request,
    # not one per row.
    def group_path(group) = @group_paths[group.id] ||= group.name_path
  end
end
