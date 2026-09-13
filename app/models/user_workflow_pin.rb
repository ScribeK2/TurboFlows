class UserWorkflowPin < ApplicationRecord
  MAX_PINS = 8

  belongs_to :user
  belongs_to :workflow

  validates :user_id, uniqueness: { scope: :workflow_id }
  validate :pin_limit, on: :create

  private

  # Counts only pins on workflows the user can still see. A workflow that left
  # their groups or was unpublished keeps its pin (nothing sweeps it), and that
  # pin shows nowhere and can't be unpinned — so it must not also hold a slot
  # hostage against a pin the viewer can actually use.
  def pin_limit
    return unless user

    visible = user.user_workflow_pins.where(workflow_id: Workflow.visible_to(user).select(:id))
    if visible.count >= MAX_PINS
      errors.add(:base, "You can pin up to #{MAX_PINS} workflows")
    end
  end
end
