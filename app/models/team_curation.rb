# Who may curate which groups' featured workflows (spec
# 2026-09-13-group-featured-workflows Q2, Q5, Q13), decided in one place: the
# top-bar link, /teams, each team page and every change to a team's list ask
# here.
#
# An administrator curates every group, Global included. A manager curates the
# groups they manage and those groups' sub-teams (the reach Analytics gives
# them), and never Global, which has no managers. Everyone else curates nothing.
class TeamCuration
  def initialize(user)
    @user = user
  end

  def allowed?
    @user&.admin? || group_ids.any?
  end

  def can_curate?(group)
    group.present? && group_ids.include?(group.id)
  end

  def group_ids
    @group_ids ||= @user&.admin? ? Group.pluck(:id) : GroupManager.team_group_ids_for(@user)
  end
end
