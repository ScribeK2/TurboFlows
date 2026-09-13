# A team's featured workflows, curated on its team page (spec
# 2026-09-13-group-featured-workflows). Every change answers with the featured
# card and a flash, the way the admin group page's members and folders cards do,
# or returns to the team page when Turbo isn't there.
module Teams
  class FeaturedWorkflowsController < ApplicationController
    include TeamAccess

    SEARCH_LIMIT = 10

    before_action :set_team
    before_action :set_featured, only: %i[destroy move]

    # The add search, answered into the team page's turbo-frame.
    def index
      @query = search_query
      @candidates = candidates_for(@query)
    end

    def create
      row = @group.featured_workflows.build(workflow_id: params[:workflow_id], added_by: current_user,
                                            position: next_position)

      if row.save
        respond_with_featured notice: "Featured #{row.workflow.title} for #{@group.name}."
      else
        respond_with_featured alert: row.errors.full_messages.to_sentence
      end
    end

    def destroy
      title = @featured.workflow.title
      @featured.destroy!

      respond_with_featured notice: "Removed #{title} from #{@group.name}."
    end

    # One place up or down, for anyone not dragging (default 2). The ends stay put.
    def move
      rows = @group.featured_workflows.ordered.to_a
      from = rows.index(@featured)
      to = params[:direction] == "up" ? from - 1 : from + 1

      if to.between?(0, rows.size - 1)
        rows.insert(to, rows.delete_at(from))
        renumber(rows.map(&:id))
      end

      respond_with_featured
    end

    # The drag, saved as the group page's folders are: ids in their new order.
    def reorder
      ids = params[:featured_ids]
      return head :bad_request unless ids.is_a?(Array)

      renumber(ids)
      head :ok
    end

    private

    def set_team
      @group = find_team(params[:team_id])
      deny_team_access! unless @group
    end

    def set_featured
      @featured = @group.featured_workflows.find(params[:id])
    end

    def search_query
      params[:q].to_s.strip
    end

    # What this team's members can see (Q14), matching the words and not
    # featured here already, whether or not the curator can open it.
    def candidates_for(query)
      return Workflow.none if query.blank?

      Workflow.visible_to_members_of(@group)
              .search_by(query)
              .where.not(id: @group.featured_workflows.select(:workflow_id))
              .order(:title)
              .limit(SEARCH_LIMIT)
    end

    def next_position
      (@group.featured_workflows.maximum(:position) || -1) + 1
    end

    def renumber(ids)
      GroupFeaturedWorkflow.transaction do
        ids.each_with_index do |id, index|
          @group.featured_workflows.where(id:).update_all(position: index)
        end
      end
    end

    # The card comes back whole, with the search re-run for the same words, so
    # the search stays open after a Feature.
    def respond_with_featured(notice: nil, alert: nil)
      respond_to do |format|
        format.turbo_stream do
          flash.now[:notice] = notice if notice
          flash.now[:alert] = alert if alert
          assign_featured(@group)
          @query = search_query
          @candidates = candidates_for(@query)
          render "teams/featured_workflows/changed"
        end
        format.html { redirect_to team_path(@group), notice:, alert: }
      end
    end
  end
end
