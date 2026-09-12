module NavHelper
  # Which top-bar destination the current page belongs to.
  #
  # The bar's "you are here" signal is *section*-level, not exact-page: a
  # scenario run launched from the builder still lights Workflows, and every
  # page under /admin lights Admin. Three controllers used to light nothing at
  # all — you could be mid-scenario in the builder with an entirely inert bar.
  #
  # A controller absent from this map deliberately lights nothing. Profiles,
  # registrations, tags, folders and first_runs are reached from inside a
  # section, never from the bar, so highlighting a bar item while you sit on
  # one of them would be a lie.
  NAV_SECTIONS = {
    "dashboard" => :home,
    "workflows" => :workflows,
    "scenarios" => :workflows,
    "steps" => :workflows,
    "workflow_versions" => :workflows,
    "analytics" => :analytics,
    # Only the Player *index* renders the app shell, so :play lights there and
    # nowhere else — see PlayerController#resolve_layout. The run screens swap
    # to the focused player layout, which has no top bar by design. This entry
    # was unreachable until 2026-09-09, when `layout "player"` covered the whole
    # controller and the index wore the run chrome; the pre-redesign
    # `controller_name == "player"` condition was dead for the same reason.
    "player" => :play
  }.freeze

  def nav_section
    return :admin if controller_path.start_with?("admin/")
    return :workflows if controller_path.start_with?("workflows/")
    return :analytics if controller_path.start_with?("analytics/")

    NAV_SECTIONS[controller_path]
  end

  # For `aria: { current: nav_current(:workflows) }` — nil renders no attribute,
  # and the underline in navigation.css keys off [aria-current="page"], so the
  # accessible name and the visible state cannot drift apart.
  def nav_current(section)
    "page" if nav_section == section
  end
end
