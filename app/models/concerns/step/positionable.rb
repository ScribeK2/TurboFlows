module Step::Positionable
  extend ActiveSupport::Concern

  included do
    before_validation :assign_next_position, on: :create, if: -> { position.blank? }
  end

  class_methods do
    def insert_at(workflow, position)
      workflow.steps.unscoped
              .where(workflow_id: workflow.id)
              .where("position >= ?", position)
              .update_all("position = position + 1")
      position
    end

    def rebalance_positions(workflow)
      workflow.steps.unscoped
              .where(workflow_id: workflow.id)
              .order(:position)
              .each_with_index do |step, idx|
                step.update_column(:position, idx) if step.position != idx
              end
    end
  end

  private

  def assign_next_position
    max = workflow.steps.unscoped
                  .where(workflow_id: workflow_id)
                  .maximum(:position)
    self.position = max ? max + 1 : 0
  end
end
