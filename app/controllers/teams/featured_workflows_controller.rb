# A team's featured workflows, curated on its team page (spec
# 2026-09-13-group-featured-workflows). Every change answers with a Turbo Stream
# that re-renders the featured card in place, the way the admin group page's
# members and folders cards do. Feature and Remove also report through #flash;
# Move and a drag only re-render the card. Without Turbo a change returns to the
# team page.
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

      if save_featured(row)
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
    # The card comes back with focus on the row that moved.
    def move
      rows = @group.featured_workflows.ordered.to_a
      from = rows.index(@featured)
      @moved_id = @featured.id
      @moved_direction = params[:direction] == "up" ? "up" : "down"
      to = @moved_direction == "up" ? from - 1 : from + 1

      if to.between?(0, rows.size - 1)
        rows.insert(to, rows.delete_at(from))
        renumber(rows.map(&:id))
      end

      respond_with_featured
    end

    # The drag, saved as the group page's folders are: ids in their new order.
    # Turbo gets the card back, so each row's Move buttons follow the new order.
    def reorder
      ids = params[:featured_ids]
      return head :bad_request unless ids.is_a?(Array)

      renumber(ids)
      respond_to do |format|
        format.turbo_stream { render_featured }
        format.any { head :ok }
      end
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

    # Two Features of the same workflow at once. The losing request is refused
    # either by the uniqueness validation (the other row landed before it
    # checked) or by the unique index (it landed between the check and the
    # INSERT). Either way the workflow ended up featured, which is what was
    # asked, so it answers as featured rather than with the model's message or a
    # 500. A refusal with no row behind it, such as the limit, is still a refusal.
    def save_featured(row)
      row.save || @group.featured_workflows.exists?(workflow_id: row.workflow_id)
    rescue ActiveRecord::RecordNotUnique
      true
    end

    def renumber(ids)
      GroupFeaturedWorkflow.transaction do
        ids.each_with_index do |id, index|
          @group.featured_workflows.where(id:).update_all(position: index)
        end
      end
    end

    def respond_with_featured(notice: nil, alert: nil)
      respond_to do |format|
        format.turbo_stream do
          flash.now[:notice] = notice if notice
          flash.now[:alert] = alert if alert
          render_featured
        end
        format.html { redirect_to team_path(@group), notice:, alert: }
      end
    end

    # The card comes back whole, with the search re-run for the same words, so
    # the search stays open after a Feature.
    def render_featured
      assign_featured(@group)
      @query = search_query
      @candidates = candidates_for(@query)
      render "teams/featured_workflows/changed"
    end
  end
end
