// Shared FlowchartRenderer service for rendering workflow flowcharts
// Used by flow_preview_controller, template_flow_preview_controller, and wizard_flow_preview_controller

export class FlowchartRenderer {
  constructor(options = {}) {
    this.nodeWidth = options.nodeWidth || 200
    this.nodeHeight = options.nodeHeight || 120
    this.nodeMargin = options.nodeMargin || 40
    this.compact = options.compact || false
    this.darkMode = options.darkMode || false
    this.clickable = options.clickable || false
    this.arrowIdPrefix = options.arrowIdPrefix || ''
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

  // Calculate node positions (vertical layout - top to bottom)
  calculatePositions(steps, connections) {
    const positions = {}
    const horizontalSpacing = this.nodeWidth + this.nodeMargin
    const verticalSpacing = this.nodeHeight + 60 // More spacing for vertical arrows

    // Track branch targets and sources for layout decisions
    const branchTargets = new Set()
    const branchSources = new Map() // Maps target index to array of source indices
    connections.forEach(conn => {
      if (conn.type === "true" || conn.type === "false" || conn.type.startsWith("branch_") || conn.type === "else" || conn.type === "conditional") {
        branchTargets.add(conn.to)
        if (!branchSources.has(conn.to)) {
          branchSources.set(conn.to, [])
        }
        branchSources.get(conn.to).push(conn.from)
      }
    })

    // Center horizontally for simple vertical flow
    const centerX = this.nodeMargin + this.nodeWidth / 2
    let currentY = this.nodeMargin
    let maxX = this.nodeMargin

    steps.forEach((step, index) => {
      // For simple vertical layout, center all nodes
      let nodeX = this.nodeMargin

      // If this step has multiple incoming branches or is a branch target from non-adjacent step,
      // we might offset it slightly, but for now keep it simple and centered
      positions[index] = { x: nodeX, y: currentY }
      maxX = Math.max(maxX, nodeX + this.nodeWidth)
      currentY += verticalSpacing
    })

    return positions
  }

  // Build SVG path for a connection (vertical layout - top to bottom)
  buildConnectionPath(fromPos, toPos, connType, connIndex = 0) {
    // For vertical layout: connect from bottom center of source to top center of target
    const fromX = fromPos.x + this.nodeWidth / 2
    const fromY = fromPos.y + this.nodeHeight
    const toX = toPos.x + this.nodeWidth / 2
    const toY = toPos.y
    const dx = toX - fromX
    const dy = toY - fromY

    // If going backwards (target is above source), curve around
    if (dy < 0) {
      const curveOffset = 60 + (connIndex * 20)
      return `M ${fromX} ${fromY} C ${fromX + curveOffset} ${fromY + 30}, ${toX + curveOffset} ${toY - 30}, ${toX} ${toY}`
    }

    // For conditional/branch connections, add slight curve based on index
    if (connType === "true" || connType === "conditional" || connType.startsWith("branch_")) {
      const curveOffset = 20 + (connIndex * 15)
      const controlY = fromY + dy * 0.5
      return `M ${fromX} ${fromY} Q ${fromX + curveOffset} ${controlY}, ${toX} ${toY}`
    } else if (connType === "false") {
      const curveOffset = -20 - (connIndex * 15)
      const controlY = fromY + dy * 0.5
      return `M ${fromX} ${fromY} Q ${fromX + curveOffset} ${controlY}, ${toX} ${toY}`
    } else if (connType === "else") {
      // Dashed line, slight curve
      const controlY = fromY + dy * 0.5
      return `M ${fromX} ${fromY} Q ${fromX - 15} ${controlY}, ${toX} ${toY}`
    } else {
      // Default straight vertical line
      return `M ${fromX} ${fromY} L ${toX} ${toY}`
    }
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

    let svgHtml = `<svg class="absolute inset-0 pointer-events-none" style="width: ${maxX}px; height: ${maxY}px; z-index: 0;">`
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

      svgHtml += `<path d="${path}" stroke="${color}" stroke-width="${strokeWidth}" fill="none" stroke-dasharray="${strokeDasharray}" marker-end="url(#${arrowId})"/>`

      // Add label for branches and conditional connections
      const showLabel = conn.label && (
        conn.type === "true" ||
        conn.type === "false" ||
        conn.type.startsWith("branch_") ||
        conn.type === "else" ||
        conn.type === "conditional"
      )

      if (showLabel) {
        // Position label to the side of the connection for vertical layout
        const midY = (fromY + toY) / 2
        const labelOffset = conn.type === "false" || connIndex % 2 === 1 ? -8 : 8
        const labelX = fromX + labelOffset + (this.nodeWidth / 4)
        const labelY = midY
        const labelText = this.escapeHtml(conn.label)
        const textLength = labelText.length * charWidth
        svgHtml += `
          <rect x="${labelX - 4}" y="${labelY - 10}" width="${textLength + 8}" height="16" fill="white" opacity="0.95" rx="3"/>
          <text x="${labelX + textLength/2}" y="${labelY + 2}" text-anchor="middle" fill="${color}" font-size="${fontSize}" font-weight="600">${labelText}</text>
        `
      }
    })

    svgHtml += `</svg>`
    return svgHtml
  }

  // Get step background color class (matches step_item colors)
  getStepColorClass(type) {
    switch(type) {
      case "question": return "bg-slate-100 text-slate-700"
      case "action": return "bg-emerald-100 text-emerald-700"
      case "sub_flow": return "bg-indigo-100 text-indigo-700"
      case "message": return "bg-cyan-100 text-cyan-700"
      case "escalate": return "bg-orange-100 text-orange-700"
      case "resolve": return "bg-green-100 text-green-700"
      default: return "bg-gray-100 text-gray-700"
    }
  }

  // Get step border color class (matches step_item colors)
  getStepBorderClass(type) {
    switch(type) {
      case "question": return "border-slate-400"
      case "action": return "border-emerald-400"
      case "sub_flow": return "border-indigo-400"
      case "message": return "border-cyan-400"
      case "escalate": return "border-orange-400"
      case "resolve": return "border-green-400"
      default: return "border-gray-300"
    }
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

  // Build HTML for a single step node (with colored header)
  buildNodeHtml(step, pos, options = {}) {
    const bgColorClass = this.getStepColorClass(step.type)
    const borderClass = this.getStepBorderClass(step.type)
    const headerColor = this.getStepColor(step.type)
    const fontSize = this.compact ? "text-xs" : "text-sm"
    const padding = this.compact ? 8 : 12
    const badgeSize = this.compact ? 18 : 22
    const icon = this.getStepIcon(step.type)

    const darkModeClasses = this.darkMode
      ? "dark:bg-gray-800 dark:text-gray-100"
      : ""

    const lineClamp = this.compact
      ? 'display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;'
      : 'display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;'

    return `
      <div class="absolute workflow-node z-10 ${this.clickable ? 'cursor-pointer hover:opacity-80 transition-opacity' : ''}"
           style="left: ${pos.x}px; top: ${pos.y}px; width: ${this.nodeWidth}px;"
           data-step-index="${step.index}"
           ${this.clickable ? `data-action="click->wizard-flow-preview#editStep"` : ''}>
        <div class="rounded-lg bg-white shadow-md overflow-hidden border ${borderClass} ${darkModeClasses}"
             style="min-height: ${this.nodeHeight}px;">
          <!-- Colored header bar -->
          <div class="flex items-center gap-2 px-3 py-2" style="background-color: ${headerColor};">
            <span class="inline-flex items-center justify-center rounded-full bg-white/30 text-white font-bold"
                  style="width: ${badgeSize}px; height: ${badgeSize}px; font-size: 11px;">
              ${step.index + 1}
            </span>
            <span class="text-white/90 font-bold text-sm">${icon}</span>
            <span class="text-xs font-semibold uppercase text-white/90 tracking-wide">${this.escapeHtml(step.type || 'unknown')}</span>
          </div>
          <!-- Content -->
          <div style="padding: ${padding}px;">
            <h4 class="font-semibold ${fontSize} text-gray-900 break-words" style="${lineClamp}">
              ${this.escapeHtml(step.title || `Step ${step.index + 1}`)}
            </h4>
            ${step.type === "resolve" ? `<p class="text-xs text-green-600 mt-1 font-medium">Terminal</p>` : ""}
            ${this.clickable ? `<p class="text-xs text-gray-400 mt-2">Click to edit</p>` : ''}
          </div>
        </div>
      </div>
    `
  }

  // Render the complete flowchart
  render(steps) {
    if (!steps || steps.length === 0) {
      return `<p class="text-gray-500 ${this.darkMode ? 'dark:text-gray-400' : ''} text-center py-8">No steps to preview</p>`
    }

    const connections = this.buildConnections(steps)
    const positions = this.calculatePositions(steps, connections)

    if (Object.keys(positions).length === 0) {
      return `<p class="text-gray-500 text-center py-8">Unable to render flow preview</p>`
    }

    // Calculate canvas dimensions
    const positionValues = Object.values(positions)
    const maxX = Math.max(...positionValues.map(p => p.x + this.nodeWidth)) + this.nodeMargin
    const maxY = Math.max(...positionValues.map(p => p.y + this.nodeHeight)) + this.nodeMargin

    // Build SVG and nodes
    let html = `<div class="relative" style="min-height: ${maxY}px; width: ${maxX}px;">`
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
