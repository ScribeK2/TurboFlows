/**
 * Icon Service
 *
 * Shared SVG icon paths for step types, answer types, and UI elements.
 * All paths are Heroicons-style: 24x24 viewBox, stroke-based, stroke="currentColor".
 * This ensures automatic dark mode support via CSS color inheritance.
 *
 * Multi-subpath icons: paths separated by " M" are split into multiple <path> elements.
 */

// Step type icon paths
export const STEP_ICON_PATHS = {
  question:   "M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z",
  action:     "M13 10V3L4 14h7v7l9-11h-7z",
  sub_flow:   "M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1",
  message:    "M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z",
  escalate:   "M5 10l7-7m0 0l7 7m-7-7v18",
  resolve:    "M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z",
  default:    "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
}

// UI icon paths
export const UI_ICON_PATHS = {
  sparkles:     "M5 3v4M3 5h4M6 17v4m-2-2h4m5-16l2.286 6.857L21 12l-5.714 2.143L13 21l-2.286-6.857L5 12l5.714-2.143L13 3z",
  lightbulb:    "M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z",
  warning:      "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z",
  clipboard:    "M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2",
  numbers:      "M7 20l4-16m2 16l4-16M6 9h14M4 15h14",
  pencil:       "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z",
  check_circle: "M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z",
  paperclip:    "M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656l-6.415 6.585a6 6 0 108.486 8.486L20.5 13"
}

// Answer type icon paths (for branch assistant / template selector)
export const ANSWER_ICON_PATHS = {
  yes_no:          UI_ICON_PATHS.check_circle,
  multiple_choice: UI_ICON_PATHS.clipboard,
  numeric:         UI_ICON_PATHS.numbers,
  text:            UI_ICON_PATHS.pencil
}

/**
 * Render an inline SVG icon from path data.
 *
 * Handles multi-subpath icons by splitting on " M" and creating
 * separate <path> elements for each subpath.
 *
 * @param {string} pathData - SVG path d attribute(s)
 * @param {string} [classes="w-5 h-5"] - CSS classes for the <svg> element
 * @returns {string} HTML string for the inline SVG
 */
export function renderIcon(pathData, classes = "w-5 h-5") {
  if (!pathData) return ""

  // Split multi-subpath strings: each subpath starts with "M"
  const subPaths = pathData.split(/(?= M)/).map(p => p.trim())
  const pathElements = subPaths
    .map(d => `<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="${d}"/>`)
    .join("")

  return `<svg class="${classes}" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">${pathElements}</svg>`
}

/**
 * Convenience wrapper: render an SVG icon for a step type.
 *
 * @param {string} type - Step type (question, action, message, etc.)
 * @param {string} [classes="w-5 h-5"] - CSS classes
 * @returns {string} HTML string
 */
export function renderStepIcon(type, classes = "w-5 h-5") {
  const pathData = STEP_ICON_PATHS[type] || STEP_ICON_PATHS.default
  return renderIcon(pathData, classes)
}

/**
 * Return a plain-text symbol for a step type.
 * Use this for <option> tags (which cannot contain HTML).
 *
 * Matches the existing _step_item.html.erb pattern.
 *
 * @param {string} type - Step type
 * @returns {string} Single character symbol
 */
export function stepTextLabel(type) {
  const labels = {
    question:   "?",
    action:     "!",
    sub_flow:   "~",
    message:    "m",
    escalate:   "^",
    resolve:    "r"
  }
  return labels[type] || "#"
}
