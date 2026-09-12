module AdminHelper
  # Which sidebar item the current admin page belongs to. Section-level, like
  # NavHelper: memberships light Groups because the member search is part of a
  # group's page. Add a controller here when you add an admin surface — absence
  # lights nothing.
  ADMIN_SECTIONS = {
    "admin/dashboard" => :overview,
    "admin/users" => :users,
    "admin/groups" => :groups,
    "admin/memberships" => :groups,
    "admin/data_health" => :data_health,
    "admin/smtp_settings" => :email
  }.freeze

  def admin_section
    ADMIN_SECTIONS[controller_path]
  end

  # For `aria: { current: admin_nav_current(:users) }` — nil renders no
  # attribute, and the CSS keys the current state off [aria-current="page"].
  def admin_nav_current(section)
    "page" if admin_section == section
  end

  # Groups, then each ancestor (root first), then optionally the group itself,
  # as [label, path] pairs for admin/breadcrumb. A persisted group shows its
  # SAVED name, so a failed edit that blanked the field does not blank the crumb.
  def admin_group_trail(group, include_self: false)
    trail = [["Groups", admin_groups_path]]
    return trail if group.nil?

    trail += group.ancestors.reverse.map { |ancestor| [ancestor.name, admin_group_path(ancestor)] }
    if include_self
      name = group.persisted? ? group.attribute_in_database(:name) : group.name
      trail << [name, admin_group_path(group)]
    end
    trail
  end

  # Each tree node with the ids of the groups above it, root first. tree_nodes
  # is depth-first, so a node's ancestors are the trail cut to its depth.
  def admin_group_tree_rows(nodes)
    trail = []
    nodes.map do |node|
      trail = trail.first(node.depth)
      ancestors = trail.dup
      trail << node.id
      [node, ancestors]
    end
  end

  # Why a group can't be deleted yet, or nil when it can. Mirrors the refusal in
  # Admin::GroupsController#destroy, which remains the guard.
  def admin_group_delete_blocker(subgroups:, workflows:)
    held = []
    held << pluralize(subgroups, "subgroup") if subgroups.positive?
    held << pluralize(workflows, "workflow") if workflows.positive?
    return if held.empty?

    what = subgroups + workflows == 1 ? "it" : "them"
    "It still holds #{held.to_sentence}. Move #{what} elsewhere before deleting the group."
  end

  # The confirm names what deleting takes with it: memberships and folders.
  def admin_group_delete_confirm(group, members:, folders:)
    loses = members == 1 ? "loses" : "lose"
    are = folders == 1 ? "is" : "are"
    "Delete #{group.name}? Its #{pluralize(members, 'member')} #{loses} the access it gives, " \
      "and its #{pluralize(folders, 'folder')} #{are} deleted. This can't be undone."
  end

  # The delete confirm says what happens to what's filed in the folder.
  def admin_folder_delete_confirm(folder, workflows:)
    return "Delete the folder #{folder.name}? It holds no workflows." if workflows.zero?

    become = workflows == 1 ? "becomes" : "become"
    "Delete the folder #{folder.name}? Its #{pluralize(workflows, 'workflow')} #{become} unfiled — " \
      "still in this group, in no folder."
  end

  # A clickable column header for an admin table.
  #
  #   sortable_column_header("Email", :email, current_sort: @sort, frame: "users-table")
  #
  # Clicking an inactive column sorts by +initial+; clicking the active column
  # flips it. Sorting returns to page 1 — an offset taken under the previous
  # ordering means nothing under a new one. Every other filter is carried
  # through, so sorting does not quietly clear a search.
  #
  # +current_sort+ is the ordering actually in effect, with the default already
  # resolved (Admin::UsersFilter#sort_key), so the default column renders as
  # sorted rather than looking untouched while quietly driving the list.
  def sortable_column_header(label, column, current_sort:, frame:, initial: :asc)
    ascending  = "#{column}_asc"
    descending = "#{column}_desc"

    state =
      case current_sort
      when ascending  then :asc
      when descending then :desc
      end

    # Flip when active; otherwise open with this column's natural direction.
    target =
      case state
      when :asc  then descending
      when :desc then ascending
      else            initial.to_sym == :desc ? descending : ascending
      end

    link_to label,
            url_for(filter_params.to_h.merge(sort: target, page: nil)),
            class: ["table__sort", ("is-sorted-#{state}" if state)].compact.join(" "),
            aria: { label: sortable_column_label(label, state) },
            data: { turbo_frame: frame, turbo_action: "advance" }
  end

  # For the th's aria-sort attribute. Screen readers announce a column's state
  # from the header cell, not from the link inside it.
  def sortable_column_aria_sort(column, current_sort:)
    case current_sort
    when "#{column}_asc"  then "ascending"
    when "#{column}_desc" then "descending"
    else                       "none"
    end
  end

  private

  def sortable_column_label(label, state)
    case state
    when :asc  then "#{label}, sorted ascending. Activate to sort descending."
    when :desc then "#{label}, sorted descending. Activate to sort ascending."
    else            "#{label}, not sorted. Activate to sort."
    end
  end
end
