# rubocop:disable Style/ClassAndModuleChildren -- compact form required because Step is a class, not a module
module Step::Positionable
  extend ActiveSupport::Concern

  included do
    before_validation :assign_next_position, on: :create, if: -> { position.blank? }
  end

  class_methods do
    def insert_at(workflow, position)
      workflow.steps
              .where(position: position..)
              .update_all("position = position + 1")
      position
    end

    def rebalance_positions(workflow)
      workflow.steps
              .each_with_index do |step, idx|
                step.update_columns(position: idx) if step.position != idx
              end
    end
  end

  private

  def assign_next_position
    max = workflow.steps.maximum(:position)
    self.position = max ? max + 1 : 0
  end
end
# rubocop:enable Style/ClassAndModuleChildren
