module ApplicationHelper
  # Safely display workflow description as plain text
  def display_workflow_description(workflow)
    workflow.description.present? ? workflow.description.to_s : "No description"
  end

  # Render glassmorphism card with block content
  def render_card(title: nil, icon: nil, with_3d: false, css_class: nil, controller: nil, content_class: nil, footer: nil, &)
    content = capture(&) if block_given?
    render partial: "shared/card", locals: {
      title: title,
      icon: icon,
      with_3d: with_3d,
      class: css_class,
      controller: controller,
      content_class: content_class,
      footer: footer,
      content: content
    }
  end

  # Build hierarchical group tree structure for dropdown
  def build_group_tree(groups)
    roots = groups.select { |g| g.parent_id.nil? }
    build_tree_nodes(roots, groups)
  end

  # Render a pill badge indicating workflow draft/published status
  def workflow_status_badge(workflow)
    if workflow.draft?
      content_tag(:span, "Draft",
                  class: "badge badge--draft",
                  aria: { label: "Draft workflow" })
    else
      content_tag(:span, "Published",
                  class: "badge badge--published",
                  aria: { label: "Published workflow" })
    end
  end

  # Sanitize SVG icon markup — allows only safe SVG elements and attributes.
  # Use instead of `raw` when rendering icon HTML in views.
  def sanitize_svg(html)
    sanitize(html, tags: %w[svg path circle rect line polyline polygon g defs use symbol],
                   attributes: %w[viewBox xmlns fill stroke stroke-width stroke-linecap
                                  stroke-linejoin d cx cy r x y width height points
                                  class transform opacity id href xlink:href])
  end

  private

  def build_tree_nodes(parents, all_groups)
    parents.map do |parent|
      children = all_groups.select { |g| g.parent_id == parent.id }
      {
        group: parent,
        children: build_tree_nodes(children, all_groups)
      }
    end
  end
end
