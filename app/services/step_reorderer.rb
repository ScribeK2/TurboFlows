class StepReorderer
  def self.call(workflow, step, new_position)
    new(workflow, step, new_position).call
  end

  def initialize(workflow, step, new_position)
    @workflow = workflow
    @step = step
    max_position = [workflow.steps_count - 1, 0].max
    @new_position = new_position.to_i.clamp(0, max_position)
  end

  def call
    Step.transaction do
      old_position = @step.position
      return if old_position == @new_position

      if @new_position > old_position
        siblings_scope.where(position: (old_position + 1)..@new_position)
                      .update_all("position = position - 1")
      else
        siblings_scope.where(position: @new_position..(old_position - 1))
                      .update_all("position = position + 1")
      end

      @step.update_columns(position: @new_position)
    end
  end

  private

  def siblings_scope
    @workflow.steps.where.not(id: @step.id)
  end
end
