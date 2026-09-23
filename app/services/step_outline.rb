# The builder's step list as an outline of the graph: each step's children hang
# off the door that leads to them. One door per step is the CONTINUATION and
# renders at the parent's indent; the rest are EXITS and nest. A step appears
# once as a real row; every other door to it is a JUMP.
#
# Rulings (spec 2026-09-22, revision 2, decided with the user):
# - The continuation is the LAST door in Step::Doors order: the wired
#   "Anything else" when there is one, otherwise the last answer (No on a
#   Yes/No). Every tool we studied fixes the fallback as a sibling; this is
#   that convention, and it is predictable where a computed rule was not.
# - A merged step belongs to the door the walk reaches first, and the walk
#   VISITS the continuation before the exits ("trunk-first"), so a side branch
#   that rejoins the trunk cannot capture it. The view RENDERS exits first.
#
# Nothing here is persisted: ordinals are derived on every read. Pure - reads
# only the preloaded association. Build it on steps whose `transitions` were
# loaded AFTER any write (Step::Doors reuses a loaded association).
class StepOutline
  Node = Struct.new(:step, :exits, :continuation, :extras, :fallback, :rows, :chain_rows, keyword_init: true)
  # kind: :step (child is a Node), :jump (target placed elsewhere), :stub (unwired).
  Edge = Struct.new(:door, :kind, :child, :target, keyword_init: true)
  WayIn = Struct.new(:source, :label, keyword_init: true)

  Result = Struct.new(:root, :orphan_roots, :ways_in, keyword_init: true) do
    # Steps not reached from the start, in the order the Unconnected section
    # renders them.
    def orphans
      @orphans ||= orphan_roots.flat_map { |node| StepOutline.render_order(node) }
    end

    # Render order (exits before continuation) from the start, then the
    # Unconnected section's. Every "step N" in the builder and the PDF export
    # counts in this order.
    def reading_order
      @reading_order ||= (root ? StepOutline.render_order(root) : []) + orphans
    end

    def ordinals
      @ordinals ||= reading_order.each_with_index.to_h { |step, index| [step.uuid, index + 1] }
    end

    # Shown only when two or more connections lead in: one way in is the
    # outline's own nesting and says nothing new.
    def ways_in_for(step)
      sources = ways_in.fetch(step.uuid, [])
      return [] if sources.size < 2

      sources.sort_by { |way| ordinals[way.source.uuid].to_i }
    end
  end

  def self.call(workflow, steps)
    new(workflow, steps).call
  end

  def self.for(workflow)
    call(workflow, workflow.steps.ordered.includes(transitions: :target_step))
  end

  # Exits before continuation, as the view renders.
  def self.render_order(node, list = [])
    list << node.step
    node.exits.each { |edge| render_order(edge.child, list) if edge.kind == :step }
    render_order(node.continuation.child, list) if node.continuation&.kind == :step
    list
  end

  def initialize(workflow, steps)
    @workflow = workflow
    @steps = steps.to_a
    @by_id = @steps.index_by(&:id)
    @seen = Set.new
    @doors = @steps.to_h { |step| [step.id, Step::Doors.for(step)] }
  end

  def call
    start = @by_id[@workflow.start_step_id] || @steps.min_by { |step| step.position.to_i }
    root = start && node_for(start)
    orphan_roots = walk_orphans
    ([root].compact + orphan_roots).each { |node| count_rows(node) }
    Result.new(root: root, orphan_roots: orphan_roots, ways_in: collect_ways_in)
  end

  private

  # The steps the start does not reach get outlines of their own, so an
  # unconnected chain keeps its shape and an unconnected question keeps its
  # stubs. A root is a step nothing still unplaced leads to, taken in position
  # order; a cycle nothing leads into starts at its first step by position.
  def walk_orphans
    roots = []
    loop do
      remaining = @steps.reject { |step| @seen.include?(step.id) }
      break if remaining.empty?

      led_to = remaining.flat_map { |step| step.transitions.map(&:target_step_id) }.to_set
      roots << node_for(remaining.find { |step| led_to.exclude?(step.id) } || remaining.first)
    end
    roots
  end

  def node_for(step)
    @seen << step.id
    doors = @doors[step.id]
    # Visited first so the trunk claims its own steps; rendered last.
    continuation = doors.doors.last && edge_for(doors.doors.last)
    exits = doors.doors[0...-1].map { |door| edge_for(door) }
    Node.new(step: step, exits: exits, continuation: continuation, extras: doors.extras,
             fallback: doors.fallback, rows: 0, chain_rows: 0)
  end

  def edge_for(door)
    target = door.target_step && @by_id[door.target_step.id]
    return Edge.new(door: door, kind: :stub) if target.nil?
    return Edge.new(door: door, kind: :jump, target: target) if @seen.include?(target.id)

    Edge.new(door: door, kind: :step, target: target, child: node_for(target))
  end

  # rows: this step plus everything inside its exits (each exit renders its
  # child's whole continuation chain). chain_rows: rows plus this node's own
  # continuation chain - what a fold wrapped around it holds.
  def count_rows(node)
    node.rows = 1
    node.exits.each do |edge|
      next unless edge.kind == :step

      count_rows(edge.child)
      node.rows += edge.child.chain_rows
    end
    following = node.continuation&.kind == :step ? node.continuation.child : nil
    count_rows(following) if following
    node.chain_rows = node.rows + (following ? following.chain_rows : 0)
  end

  # Every transition into a step, from any step on the page (orphans too: the
  # author can see those rows). A door's own label names it; an extra is named
  # by its condition.
  def collect_ways_in
    ways = {}
    @steps.each do |step|
      doors = @doors[step.id]
      doors.doors.each do |door|
        add_way(ways, door.target_step, step, door.label)
      end
      doors.extras.each do |transition|
        add_way(ways, transition.target_step, step, transition.condition.presence || "Anything else")
      end
    end
    ways
  end

  def add_way(ways, target, source, label)
    return unless target && @by_id[target.id]

    (ways[target.uuid] ||= []) << WayIn.new(source: source, label: label)
  end
end
