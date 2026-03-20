class FlowDiagramService
  # Returns an ordered array of levels, where each level contains step nodes.
  # All workflows use BFS from start_step, grouped by depth.
  #
  # Output: [ [step, step], [step], [step, step] ]  (array of arrays)
  def self.call(workflow)
    new(workflow).call
  end

  def initialize(workflow)
    @workflow = workflow
    @steps = workflow.steps.includes(:transitions).to_a
  end

  def call
    return [] if @steps.empty?

    bfs_levels
  end

  private

  # BFS from start node, assign depth levels
  def bfs_levels
    start = @workflow.start_step || @steps.min_by(&:position)
    return @steps.sort_by(&:position).map { |step| [step] } unless start

    steps_by_id = @steps.index_by(&:id)
    visited = Set.new
    levels = Hash.new { |h, k| h[k] = [] }
    queue = [[start, 0]]
    visited.add(start.id)

    while queue.any?
      step, depth = queue.shift
      levels[depth] << step

      step.transitions.each do |transition|
        target = steps_by_id[transition.target_step_id]
        next unless target && !visited.include?(target.id)

        visited.add(target.id)
        queue << [target, depth + 1]
      end
    end

    # Add orphan steps (not reachable from start) at the end
    orphan_depth = levels.keys.max.to_i + 1
    @steps.each do |step|
      next if visited.include?(step.id)

      levels[orphan_depth] << step
    end

    levels.sort_by(&:first).map(&:last)
  end
end
