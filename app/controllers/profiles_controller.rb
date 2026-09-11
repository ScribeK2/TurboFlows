class ProfilesController < ApplicationController
  include GroupOnboarding

  before_action :authenticate_user!
  before_action :set_my_groups, only: %i[edit update]

  def edit; end

  def update
    if current_user.update(profile_params)
      redirect_to edit_profile_path, notice: "Profile updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

  def profile_params
    params.expect(user: %i[display_name time_zone])
  end

  # My groups (spec 2026-09-11 Q8): memberships by path, and the joinable groups
  # this person does not already see. Administrators see every workflow whatever
  # their groups, so they get no section. One tree read feeds both lists.
  def set_my_groups
    return if current_user.admin?

    nodes = Group.tree_nodes
    @group_paths = nodes.to_h { [it.id, it.path] }
    @memberships = current_user.user_groups.to_a.sort_by { @group_paths[it.group_id].to_s.downcase }
    join_ids = self_joinable_group_ids - covered_group_ids(nodes, @memberships.map(&:group_id)).to_a
    @join_nodes = nodes.select { join_ids.include?(it.id) }
    @join_descriptions = Group.descriptions_by_id(join_ids)
  end

  # The groups a person is in and every group below them: membership covers
  # subgroups, so joining one of those adds a row that changes nothing. Nodes
  # come depth-first, so a parent is always met before its children.
  def covered_group_ids(nodes, member_ids)
    nodes.each_with_object(member_ids.to_set) { |node, covered| covered << node.id if covered.include?(node.parent_id) }
  end
end
