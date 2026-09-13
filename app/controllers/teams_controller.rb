# The groups you curate, and one group's featured workflows (spec
# 2026-09-13-group-featured-workflows Q8, Q16, Q17). Who may curate what is
# TeamCuration's answer; this controller only lists and shows.
class TeamsController < ApplicationController
  include TeamAccess

  before_action :set_team, only: :show

  # Filtered on the server by any part of the path, into a frame the field sits
  # outside of, so answering as you type never replaces the input.
  def index
    @query = params[:q].to_s.strip
    @nodes = Group.tree_nodes(within: team_curation.group_ids)
    @nodes = @nodes.select { it.path.downcase.include?(@query.downcase) } if @query.present?
  end

  def show
    assign_featured(@group)
    @path = Group.paths_by_id.fetch(@group.id)
    @member_count = @group.user_groups.count
  end

  private

  def set_team
    @group = find_team(params[:id])
    deny_team_access! unless @group
  end
end
