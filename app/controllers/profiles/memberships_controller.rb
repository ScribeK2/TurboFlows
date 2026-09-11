# Joining and leaving groups from My groups (spec 2026-09-11 Q8), under the same
# rule as the welcome page: only self-joinable groups, in either direction.
class Profiles::MembershipsController < ApplicationController
  include GroupOnboarding

  def create
    respond_with_my_groups(*join_posted_groups(nothing_chosen: "Choose at least one group to join."))
  end

  def destroy
    membership = current_user.user_groups.find(params[:id])
    current_user.leave_group!(membership.group)
    respond_with_my_groups :notice, "You left #{group_paths_sentence([membership.group_id])}."
  rescue Group::NotSelfJoinable
    respond_with_my_groups :alert, "Only an administrator can take you out of that group."
  end

  private

  # Turbo gets My groups replaced where it is. A redirect back to
  # /profile/edit#my-groups lost its anchor, because a fetch drops the fragment,
  # so the page landed at its top with My groups off screen (found by /qa,
  # 2026-09-11). Without Turbo the browser keeps the anchor, so HTML redirects.
  def respond_with_my_groups(kind, message)
    respond_to do |format|
      format.turbo_stream do
        flash.now[kind] = message
        set_my_groups
        render "profiles/memberships/changed"
      end
      format.html { redirect_to edit_profile_path(anchor: "my-groups"), kind => message }
    end
  end
end
