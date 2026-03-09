class Transition < ApplicationRecord
  belongs_to :step
  belongs_to :target_step, class_name: "Step"

  validates :step_id, uniqueness: { scope: %i[target_step_id condition], message: "already has a transition to this target with the same condition" }

  default_scope { order(:position) }
end
