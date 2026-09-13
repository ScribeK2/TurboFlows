# The Teams pages' one gate (spec 2026-09-13-group-featured-workflows): anyone
# TeamCuration allows gets in, and a team page opens only for a group they may
# curate. Out of reach and nonexistent answer the same, so a guessed id tells
# nobody anything.
module TeamAccess
  extend ActiveSupport::Concern

  included do
    before_action :ensure_team_access!
  end

  private

  def team_curation
    @team_curation ||= TeamCuration.new(current_user)
  end

  def ensure_team_access!
    deny_team_access! unless team_curation.allowed?
  end

  def find_team(id)
    group = Group.find_by(id:)
    group if team_curation.can_curate?(group)
  end

  def deny_team_access!
    redirect_to root_path, alert: "You don't have permission to access this page."
  end

  # What the featured card renders: the rows in order, and which of their
  # workflows the group's members can see, read once for the whole list.
  def assign_featured(group)
    @featured = group.featured_workflows.ordered.includes(:workflow, :added_by).to_a
    @visible_ids = Workflow.visible_to_members_of(group).where(id: @featured.map(&:workflow_id)).pluck(:id).to_set
  end
end
