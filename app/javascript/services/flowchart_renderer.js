// Shared FlowchartRenderer service for rendering workflow flowcharts
// Used by flow_preview_controller, template_flow_preview_controller, and wizard_flow_preview_controller
import dagre from "dagre"

export class FlowchartRenderer {
  constructor(options = {}) {
    this.nodeWidth = options.nodeWidth || 200
    this.nodeHeight = options.nodeHeight || 120
    this.nodeMargin = options.nodeMargin || 40
    this.compact = options.compact || false
    this.clickable = options.clickable || false
    this.arrowIdPrefix = options.arrowIdPrefix || ''
    this.rankSep = options.rankSep || 80
    this.nodeSep = options.nodeSep || 40
    this.interactive = options.interactive || false
  }

  // Find step by title
  findStepByTitle(steps, title) {
    return steps.find(s => s.title === title)
  }

  // Find step by ID (for graph mode)
  findStepById(steps, id) {
    return steps.find(s => s.id === id)
  }

  // Check if workflow is in graph mode (steps have transitions arrays)
  isGraphMode(steps) {
    return steps.some(s => Array.isArray(s.transitions))
  }

  // Build a map of connections between steps
  buildConnections(steps) {
    // Check if this is a graph mode workflow
    if (this.isGraphMode(steps)) {
      return this.buildGraphConnections(steps)
    }
    return this.buildLinearConnections(steps)
  }

  // Build connections for graph mode workflows (using explicit transitions)
  buildGraphConnections(steps) {
    const connections = []
    const transitionColors = ["#6366f1", "#10b981", "#f59e0b", "#ef4444", "#8b5cf6", "#ec4899"]

    steps.forEach((step) => {
      if (!step.transitions || !Array.isArray(step.transitions)) return

      step.transitions.forEach((transition, tIndex) => {
        if (!transition.target_uuid) return

        const targetStep = this.findStepById(steps, transition.target_uuid)
        if (!targetStep) return

        const color = transitionColors[tIndex % transitionColors.length]
        const label = transition.label || transition.condition || ""

        connections.push({
          from: step.index,
          to: targetStep.index,
          fromId: step.id,
          toId: targetStep.id,
          type: transition.condition ? "conditional" : "default",
          label: label.length > 20 ? label.substring(0, 17) + "..." : label,
          color: transition.condition ? color : "#6b7280"
        })
      })
    })

    return connections
  }

  // Build connections for linear mode workflows (sequential only, no decision branches)
  buildLinearConnections(steps) {
    const connections = []

    // Linear mode: just sequential connections (decision branches removed)
    steps.forEach((step, index) => {
      if (index < steps.length - 1) {
        const nextStep = steps[index + 1]
        connections.push({
          from: step.index,
          to: nextStep.index,
          type: "default",
          label: ""
        })
      }
    })

    return connections
  }

  // Calculate node positions using Dagre for proper DAG layout
  calculatePositions(steps, connections) {
    if (!steps || steps.length === 0) return {}

    // Create a new directed graph
    const g = new dagre.graphlib.Graph()
    g.setGraph({
      rankdir: "TB",
      ranksep: this.rankSep,
      nodesep: this.nodeSep,
      marginx: this.nodeMargin,
      marginy: this.nodeMargin
    })
    g.setDefaultEdgeLabel(() => ({}))

    // Add nodes
    steps.forEach((step) => {
      g.setNode(String(step.index), {
        width: this.nodeWidth,
        height: this.nodeHeight
      })
    })

    // Add edges from connections
    connections.forEach((conn) => {
      g.setEdge(String(conn.from), String(conn.to))
    })

    // Run the layout algorithm
    dagre.layout(g)

    // Extract positions (Dagre gives center coords, convert to top-left)
    const positions = {}
    steps.forEach((step) => {
      const node = g.node(String(step.index))
      if (node) {
        positions[step.index] = {
          x: node.x - this.nodeWidth / 2,
          y: node.y - this.nodeHeight / 2
        }
      }
    })

    return positions
  }

  // Build SVG path for a connection using smooth cubic bezier curves
  buildConnectionPath(fromPos, toPos, connType, connIndex = 0) {
    const fromX = fromPos.x + this.nodeWidth / 2
    const fromY = fromPos.y + this.nodeHeight
    const toX = toPos.x + this.nodeWidth / 2
    const toY = toPos.y
    const dy = toY - fromY

    // Backward edge (target above source) - route around the side
    if (dy < 0) {
      const offset = 60 + (connIndex * 25)
      return `M ${fromX} ${fromY} C ${fromX + offset} ${fromY + 40}, ${toX + offset} ${toY - 40}, ${toX} ${toY}`
    }

    // Standard downward connection - smooth cubic bezier
    // Control points at 40% and 60% of the vertical distance for a natural curve
    const cp1y = fromY + dy * 0.4
    const cp2y = fromY + dy * 0.6
    return `M ${fromX} ${fromY} C ${fromX} ${cp1y}, ${toX} ${cp2y}, ${toX} ${toY}`
  }

  // Build SVG defs for arrowheads
  buildSvgDefs() {
    const prefix = this.arrowIdPrefix
    return `
      <defs>
        <marker id="${prefix}arrowhead-gray" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#6b7280" />
        </marker>
        <marker id="${prefix}arrowhead-slate" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#475569" />
        </marker>
        <marker id="${prefix}arrowhead-emerald" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#10b981" />
        </marker>
        <marker id="${prefix}arrowhead-green" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#22c55e" />
        </marker>
        <marker id="${prefix}arrowhead-red" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#ef4444" />
        </marker>
        <marker id="${prefix}arrowhead-indigo" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#6366f1" />
        </marker>
        <marker id="${prefix}arrowhead-amber" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#f59e0b" />
        </marker>
        <marker id="${prefix}arrowhead-orange" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#f97316" />
        </marker>
        <marker id="${prefix}arrowhead-cyan" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#06b6d4" />
        </marker>
        <marker id="${prefix}arrowhead-purple" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#8b5cf6" />
        </marker>
        <marker id="${prefix}arrowhead-pink" markerWidth="10" markerHeight="10" refX="0" refY="3" orient="auto" markerUnits="userSpaceOnUse">
          <polygon points="0 0, 10 3, 0 6" fill="#ec4899" />
        </marker>
      </defs>
    `
  }

  // Get arrow marker ID based on connection color
  getArrowId(conn) {
    const prefix = this.arrowIdPrefix
    // Map colors to arrow IDs
    if (conn.color === "#10b981" || conn.type === "true") return `${prefix}arrowhead-emerald`
    if (conn.color === "#22c55e") return `${prefix}arrowhead-green`
    if (conn.color === "#ef4444" || conn.type === "false") return `${prefix}arrowhead-red`
    if (conn.color === "#6366f1") return `${prefix}arrowhead-indigo`
    if (conn.color === "#f59e0b") return `${prefix}arrowhead-amber`
    if (conn.color === "#f97316") return `${prefix}arrowhead-orange`
    if (conn.color === "#06b6d4") return `${prefix}arrowhead-cyan`
    if (conn.color === "#475569") return `${prefix}arrowhead-slate`
    if (conn.color === "#8b5cf6") return `${prefix}arrowhead-purple`
    if (conn.color === "#ec4899") return `${prefix}arrowhead-pink`
    return `${prefix}arrowhead-gray`
  }

  // Build SVG for all connections (vertical layout)
  buildConnectionsSvg(connections, positions, maxX, maxY) {
    const strokeWidth = this.compact ? 1.5 : 2
    const fontSize = this.compact ? 9 : 11
    const charWidth = this.compact ? 5 : 6

    const svgClass = this.interactive ? 'flowchart-svg' : 'flowchart-svg flowchart-svg--non-interactive'
    let svgHtml = `<svg class="${svgClass}" style="width: ${maxX}px; height: ${maxY}px; z-index: 0;">`
    svgHtml += this.buildSvgDefs()

    connections.forEach((conn, connIndex) => {
      const fromPos = positions[conn.from]
      const toPos = positions[conn.to]

      if (!fromPos || !toPos) return

      // For vertical layout: connect from bottom center to top center
      const fromX = fromPos.x + this.nodeWidth / 2
      const fromY = fromPos.y + this.nodeHeight
      const toX = toPos.x + this.nodeWidth / 2
      const toY = toPos.y

      const path = this.buildConnectionPath(fromPos, toPos, conn.type, connIndex)
      const color = conn.color || "#6b7280"
      const arrowId = this.getArrowId(conn)
      const strokeDasharray = conn.type === "else" ? "5,5" : "none"

      const interactiveAttrs = this.interactive
        ? ` data-from-id="${this.escapeHtml(conn.fromId || '')}" data-to-id="${this.escapeHtml(conn.toId || '')}" data-conn-index="${connIndex}" pointer-events="stroke" cursor="pointer"`
        : ''

      // Wrap in <g> group when interactive for hover targeting
      if (this.interactive) {
        svgHtml += `<g class="edge-group" data-from-id="${this.escapeHtml(conn.fromId || '')}" data-to-id="${this.escapeHtml(conn.toId || '')}" data-conn-index="${connIndex}">`
      }

      svgHtml += `<path d="${path}" stroke="${color}" stroke-width="${strokeWidth}" fill="none" stroke-dasharray="${strokeDasharray}" marker-end="url(#${arrowId})"${interactiveAttrs}/>`

      // Add label for connections with labels
      const showLabel = conn.label && conn.label.trim() !== ""
      const midX = (fromX + toX) / 2
      const midY = (fromY + toY) / 2

      if (showLabel) {
        // Position label at midpoint of the bezier curve
        const labelText = this.escapeHtml(conn.label)
        const textLength = labelText.length * charWidth
        const pillPadX = 8
        const pillPadY = 4
        const pillWidth = textLength + pillPadX * 2
        const pillHeight = fontSize + pillPadY * 2
        svgHtml += `
          <rect x="${midX - pillWidth / 2}" y="${midY - pillHeight / 2}" width="${pillWidth}" height="${pillHeight}" fill="white" stroke="${color}" stroke-width="1" opacity="0.95" rx="8"/>
          <text x="${midX}" y="${midY + fontSize / 3}" text-anchor="middle" fill="${color}" font-size="${fontSize}" font-weight="600">${labelText}</text>
        `
      }

      // Delete button at edge midpoint (hidden by default, shown on hover via JS)
      if (this.interactive) {
        const delY = showLabel ? midY - 20 : midY
        svgHtml += `
          <g class="edge-delete-btn" style="display: none;" data-from-id="${this.escapeHtml(conn.fromId || '')}" data-conn-index="${connIndex}" cursor="pointer" pointer-events="all">
            <circle cx="${midX}" cy="${delY}" r="10" fill="#ef4444" opacity="0.9"/>
            <line x1="${midX - 4}" y1="${delY - 4}" x2="${midX + 4}" y2="${delY + 4}" stroke="white" stroke-width="2" stroke-linecap="round"/>
            <line x1="${midX + 4}" y1="${delY - 4}" x2="${midX - 4}" y2="${delY + 4}" stroke="white" stroke-width="2" stroke-linecap="round"/>
          </g>
        `
        svgHtml += `</g>`
      }
    })

    svgHtml += `</svg>`
    return svgHtml
  }

  // Get step color (hex) - matches step_item header colors
  getStepColor(type) {
    const colors = {
      question: "#475569",      // slate-600
      action: "#10b981",        // emerald-500
      sub_flow: "#6366f1",      // indigo-500
      message: "#06b6d4",       // cyan-500
      escalate: "#f97316",      // orange-500
      resolve: "#22c55e"        // green-500
    }
    return colors[type] || "#6b7280"
  }

  // Get step type icon
  getStepIcon(type) {
    const icons = {
      question: '?',
      action: '!',
      sub_flow: '↪',
      message: 'i',
      escalate: '↑',
      resolve: '✓'
    }
    return icons[type] || '#'
  }

  // Build HTML for a single step node (polished card design)
  buildNodeHtml(step, pos, options = {}) {
    const headerColor = this.getStepColor(step.type)
    const fontSize = this.compact ? "step-card__title--compact" : ""
    const padding = this.compact ? 8 : 12
    const badgeSize = this.compact ? 18 : 24
    const icon = this.getStepIcon(step.type)

    const escapedStepId = this.escapeHtml(step.id || '')
    const escapedStepType = this.escapeHtml(step.type || 'unknown')

    // Interactive mode: hover-reveals ports, no wizard click behavior
    if (this.interactive) {
      const isStart = step.isStartNode
      const startBadge = isStart
        ? '<span class="step-card__start-badge">START</span>'
        : ''

      return `
        <div class="absolute workflow-node step-card step-card--${escapedStepType}${isStart ? ' is-start' : ''}"
             style="left: ${pos.x}px; top: ${pos.y}px; width: ${this.nodeWidth}px;"
             data-step-index="${step.index}"
             data-step-id="${escapedStepId}"
             data-step-type="${escapedStepType}">
          <div class="step-card__inner" style="min-height: ${this.nodeHeight}px;">
            <!-- Colored header bar -->
            <div class="step-card__header" style="background-color: ${headerColor};">
              <span class="step-card__number"
                    style="width: ${badgeSize}px; height: ${badgeSize}px; font-size: ${this.compact ? 10 : 12}px;">
                ${step.index + 1}
              </span>
              <span class="step-card__icon" style="font-size: ${this.compact ? 11 : 13}px;">${icon}</span>
              <span class="step-card__type">${escapedStepType}</span>
              ${startBadge}
            </div>
            <!-- Content -->
            <div class="step-card__body" style="padding: ${padding}px;">
              <h4 class="step-card__title" style="display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;">
                ${this.escapeHtml(step.title || 'Step ' + (step.index + 1))}
              </h4>
              ${step.type === "resolve" ? '<p class="step-card__hint step-card__hint--resolve">Terminal</p>' : ""}
              ${step.can_resolve ? '<p class="step-card__hint step-card__hint--can-resolve">Can resolve</p>' : ""}
              <p class="step-card__hint">Double-click to edit</p>
            </div>
          </div>
          <!-- Input port (top center) -->
          <div class="input-port"
               data-port="input" data-step-id="${escapedStepId}"></div>
          <!-- Output port (bottom center) -->
          <div class="output-port"
               data-port="output" data-step-id="${escapedStepId}"></div>
        </div>
      `
    }

    // Non-interactive (preview) mode: original behavior
    return `
      <div class="absolute workflow-node step-card step-card--${escapedStepType}${this.clickable ? ' is-clickable' : ''}"
           style="left: ${pos.x}px; top: ${pos.y}px; width: ${this.nodeWidth}px;"
           data-step-index="${step.index}"
           ${this.clickable ? 'data-action="click->wizard-flow-preview#editStep"' : ''}>
        <div class="step-card__inner" style="min-height: ${this.nodeHeight}px;">
          <!-- Colored header bar -->
          <div class="step-card__header" style="background-color: ${headerColor};">
            <span class="step-card__number"
                  style="width: ${badgeSize}px; height: ${badgeSize}px; font-size: ${this.compact ? 10 : 12}px;">
              ${step.index + 1}
            </span>
            <span class="step-card__icon" style="font-size: ${this.compact ? 11 : 13}px;">${icon}</span>
            <span class="step-card__type">${this.escapeHtml(step.type || 'unknown')}</span>
          </div>
          <!-- Content -->
          <div class="step-card__body" style="padding: ${padding}px;">
            <h4 class="step-card__title" style="display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;">
              ${this.escapeHtml(step.title || 'Step ' + (step.index + 1))}
            </h4>
            ${step.type === "resolve" ? '<p class="step-card__hint step-card__hint--resolve">Terminal</p>' : ""}
            ${step.can_resolve ? '<p class="step-card__hint step-card__hint--can-resolve">Can resolve</p>' : ""}
            ${this.clickable ? '<p class="step-card__hint">Click to edit</p>' : ''}
          </div>
        </div>
      </div>
    `
  }

  // Render the complete flowchart
  render(steps) {
    if (!steps || steps.length === 0) {
      return '<p class="flowchart-empty">No steps to preview</p>'
    }

    const connections = this.buildConnections(steps)
    const positions = this.calculatePositions(steps, connections)

    if (Object.keys(positions).length === 0) {
      return '<p class="flowchart-empty">Unable to render flow preview</p>'
    }

    // Calculate canvas dimensions
    const positionValues = Object.values(positions)
    const maxX = Math.max(...positionValues.map(p => p.x + this.nodeWidth)) + this.nodeMargin * 2
    const maxY = Math.max(...positionValues.map(p => p.y + this.nodeHeight)) + this.nodeMargin * 2

    // Build SVG and nodes
    let html = '<div class="flowchart-canvas" style="min-height: ' + maxY + 'px; width: ' + maxX + 'px;">'
    html += this.buildConnectionsSvg(connections, positions, maxX, maxY)

    steps.forEach((step, arrayIndex) => {
      const pos = positions[arrayIndex] || positions[step.index]
      if (!pos) return
      html += this.buildNodeHtml(step, pos)
    })

    html += "</div>"
    return html
  }

  // Escape HTML to prevent XSS
  escapeHtml(text) {
    if (!text) return ''
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}

export default FlowchartRenderer
