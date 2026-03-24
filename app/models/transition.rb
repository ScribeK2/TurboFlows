class Transition < ApplicationRecord
  belongs_to :step
  belongs_to :target_step, class_name: "Step"

  validates :step_id, uniqueness: { scope: %i[target_step_id condition], message: "already has a transition to this target with the same condition" }

  scope :ordered, -> { order(:position) }

  validate :steps_belong_to_same_workflow

  private

  def steps_belong_to_same_workflow
    return unless step && target_step

    if step.workflow_id != target_step.workflow_id
      errors.add(:target_step, "must belong to the same workflow")
    end
  end
end
