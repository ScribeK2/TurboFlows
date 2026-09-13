# One workflow in a group's standard kit (spec 2026-09-13-group-featured-workflows).
#
# A group may feature only what its members can already see (Q6): featuring
# never changes who can see a workflow, which filing alone decides. Whether
# members can still see it is read at render, never stored, so a workflow
# unpublished and republished comes back in its place (Q18).
class GroupFeaturedWorkflow < ApplicationRecord
  MAX_PER_GROUP = 8

  belongs_to :group
  belongs_to :workflow
  belongs_to :added_by, class_name: "User", optional: true

  validates :workflow_id, uniqueness: { scope: :group_id }
  validate :visible_to_members, on: :create
  validate :room_in_the_kit, on: :create

  scope :ordered, -> { order(:position, :id) }

  # Why the group's members can't see this workflow, or nil when they can.
  # `visible_ids` is what Workflow.visible_to_members_of(group) holds, read once
  # for the whole list by the caller.
  def hidden_reason(visible_ids)
    return nil if visible_ids.include?(workflow_id)

    workflow.published? ? "Not filed in this team, its sub-teams or Global" : "Unpublished"
  end

  private

  def visible_to_members
    return unless group && workflow
    return if Workflow.visible_to_members_of(group).exists?(workflow.id)

    errors.add(:workflow, "isn't visible to #{group.name}'s members, so it can't be featured there")
  end

  # Only rows members can still see hold a place (Q18), so a workflow that was
  # unpublished can't block the one that replaces it.
  def room_in_the_kit
    return unless group

    visible = group.featured_workflows.where(workflow_id: Workflow.visible_to_members_of(group).select(:id))
    errors.add(:base, "A team can feature up to #{MAX_PER_GROUP} workflows") if visible.count >= MAX_PER_GROUP
  end
end
