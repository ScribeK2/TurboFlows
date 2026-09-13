# One workflow in a group's standard kit (spec 2026-09-13-group-featured-workflows).
#
# A group may feature only what its members can already see (Q6): featuring
# never changes who can see a workflow, which filing alone decides. Whether
# members can still see it is read at render, never stored, so a workflow
# unpublished and republished comes back in its place (Q18). Members get at most
# the first 8 they can see, so a row that comes back can push the last one out.
class GroupFeaturedWorkflow < ApplicationRecord
  MAX_PER_GROUP = 8

  belongs_to :group
  belongs_to :workflow
  belongs_to :added_by, class_name: "User", optional: true

  validates :workflow_id, uniqueness: { scope: :group_id }
  validate :visible_to_members, on: :create
  validate :room_in_the_kit, on: :create

  scope :ordered, -> { order(:position, :id) }

  # The rows members get: the first MAX_PER_GROUP of `rows` (in the curator's
  # order) whose workflows they can see. `visible_ids` is as for hidden_reason.
  def self.kit(rows, visible_ids)
    rows.select { visible_ids.include?(it.workflow_id) }.first(MAX_PER_GROUP)
  end

  # Why the group's members don't get this workflow, or nil when they do.
  # `visible_ids` is what Workflow.visible_to_members_of(group) holds and `kit`
  # what .kit made of the whole list, both read once by the caller.
  def hidden_reason(visible_ids, kit)
    return nil if kit.include?(self)
    return "Past the first #{MAX_PER_GROUP}" if visible_ids.include?(workflow_id)

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
