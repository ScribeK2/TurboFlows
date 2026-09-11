# Joining and leaving groups from My groups (spec 2026-09-11 Q8), under the same
# rule as the welcome page: only self-joinable groups, in either direction.
class Profiles::MembershipsController < ApplicationController
  include GroupOnboarding

  def create
    join_posted_groups joined_path: my_groups_path, retry_path: my_groups_path,
                       nothing_chosen: "Choose at least one group to join."
  end

  def destroy
    membership = current_user.user_groups.find(params[:id])
    current_user.leave_group!(membership.group)
    redirect_to my_groups_path, notice: "You left #{group_paths_sentence([membership.group_id])}."
  rescue Group::NotSelfJoinable
    redirect_to my_groups_path, alert: "Only an administrator can take you out of that group."
  end

  private

  def my_groups_path
    edit_profile_path(anchor: "my-groups")
  end
end
