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
  # this person is not already in. Administrators see every workflow whatever
  # their groups, so they get no section.
  def set_my_groups
    return if current_user.admin?

    @group_paths = Group.paths_by_id
    @memberships = current_user.user_groups.to_a.sort_by { @group_paths[it.group_id].to_s.downcase }
    join_ids = self_joinable_group_ids - @memberships.map(&:group_id)
    @join_nodes = Group.tree_nodes(within: join_ids)
    @join_descriptions = Group.descriptions_by_id(join_ids)
  end
end
