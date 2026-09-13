module Dashboard
  # What the CSR home reads: a call to pick back up, the viewer's pins, and the
  # workflows they recently started (spec 2026-09-13). The Editor and Admin home
  # is Dashboard::Home.
  class DataLoader
    # Recently Run: at most RECENTLY_RUN_LIMIT workflows, found in the newest
    # RECENTLY_RUN_SCAN calls the viewer started.
    RECENTLY_RUN_LIMIT = 5
    RECENTLY_RUN_SCAN = 100

    # A workflow the viewer recently started, and how that call ended. The
    # ending comes from CallStatistics, which picks it in SQL the way
    # Scenario#run_ending does, so five rows cost the same as one.
    RecentRun = Data.define(:origin, :call) do
      delegate :workflow, to: :origin
      delegate :finished?, :outcome, to: :call
    end

    # How recently a call must have been touched to be offered for resuming.
    # Closing the tab is how calls usually end, so most unfinished runs are
    # calls that are over; an hour covers a long hold without listing the day's
    # finished calls (spec Q10).
    RESUME_WINDOW = 60.minutes

    # The call home offers to pick back up. `frame` is what Resume opens: the
    # unfinished frame with the latest activity, which is the one the agent was
    # last on. `workflow` is where the call started.
    Resume = Data.define(:frame, :workflow, :step_title, :last_activity_at)

    # A frame's call, as Scenario#run_origin_id records it.
    CALL = Arel.sql("COALESCE(run_origin_id, id)")

    # One team's part of "From your team": the group, the heading it shows under,
    # and the workflows from its kit, in the curator's order.
    TeamSection = Data.define(:group, :heading, :workflows)

    attr_reader :user

    def initialize(user)
      @user = user
    end

    def csr?
      user.regular?
    end

    def pinned_workflow_ids
      @pinned_workflow_ids ||= user.user_workflow_pins.pluck(:workflow_id).to_set
    end

    def pinned_workflows
      @pinned_workflows ||= user.pinned_workflows
                                .where(id: Workflow.visible_to(user).select(:id))
                                .includes(:tags, :steps)
                                .limit(UserWorkflowPin::MAX_PINS)
    end

    # Run stats for every launcher row on the page, pinned and featured:
    # { workflow_id => { runs:, last_run_at: } }, counting calls the viewer
    # started, from two queries.
    def run_stats
      return @run_stats if defined?(@run_stats)

      ids = (pinned_workflows.map(&:id) + team_sections.flat_map { |section| section.workflows.map(&:id) }).uniq
      return (@run_stats = {}) if ids.empty?

      counts = started_calls.where(workflow_id: ids).group(:workflow_id).count
      last_runs = started_calls.where(workflow_id: ids).group(:workflow_id).maximum(:created_at)
      @run_stats = ids.index_with { |id| { runs: counts[id].to_i, last_run_at: last_runs[id] } }
    end

    # "From your team" (spec 2026-09-13-group-featured-workflows Q4, Q10, Q11):
    # the viewer's own groups in name order, then Global.
    def team_sections
      @team_sections ||= build_team_sections
    end

    # Workflows the viewer started, one row per workflow for its latest call,
    # limited to workflows they can still run, so every Re-run works.
    def recently_run
      @recently_run ||= begin
        latest = latest_call_per_workflow
        calls = CallStatistics.new(Scenario.where(id: latest.map(&:id))).calls.index_by(&:origin_id)
        latest.map { |origin| RecentRun.new(origin:, call: calls.fetch(origin.id)) }
      end
    end

    # At most one: the viewer's call with the latest activity inside
    # RESUME_WINDOW that still has an unfinished frame. Activity is the whole
    # call's (Scenario#run_last_activity), because a parent parked on a live
    # sub-flow stopped its own clock when it parked. Every frame records its call
    # in run_origin_id, so this is two grouped queries rather than a run_frames
    # walk per call.
    def resume
      return @resume if defined?(@resume)

      @resume = build_resume
    end

    private

    def build_resume
      activity = live_scenarios.where(updated_at: RESUME_WINDOW.ago..).group(CALL).maximum(:updated_at)
      return if activity.empty?

      unfinished = live_scenarios.where.not(status: Scenario::TERMINAL_STATUSES)
                                 .where("#{CALL} IN (?)", activity.keys)
                                 .to_a
      return if unfinished.empty?

      frame = unfinished.max_by { |f| [activity.fetch(f.run_origin_id || f.id), f.updated_at] }
      Resume.new(frame:, workflow: frame.run_origin.workflow, step_title: frame.current_step&.title,
                 last_activity_at: activity.fetch(frame.run_origin_id || frame.id))
    end

    # Each group's kit (GroupFeaturedWorkflow.kit): the first 8 featured
    # workflows its members can see, in the curator's order. The kit is cut
    # before anything is left out, so a pin never lets a ninth in. Then a
    # workflow shows once, under the first group that features it, and never if
    # the viewer has pinned it. A group with nothing left gets no section.
    # Visibility comes from one batch, so the query count doesn't grow with the
    # viewer's groups.
    def build_team_sections
      groups = Group.where(id: user.user_groups.select(:group_id)).to_a
      headings = team_headings(groups)
      groups.sort_by! { [it.name.downcase, headings.fetch(it.id).downcase] }
      if (global = Group.global.first)
        groups << global
        headings[global.id] = "For everyone"
      end

      rows = GroupFeaturedWorkflow.where(group_id: groups.map(&:id)).ordered
                                  .includes(workflow: %i[tags steps]).group_by(&:group_id)
      return [] if rows.empty?

      visible = Group.member_visible_workflow_ids(groups, rows.values.flatten.map(&:workflow_id),
                                                  global_id: global&.id)
      shown = pinned_workflow_ids.dup

      groups.filter_map do |group|
        kit = GroupFeaturedWorkflow.kit(rows.fetch(group.id, []), visible.fetch(group.id))
        workflows = kit.map(&:workflow).select { shown.add?(it.id) }
        TeamSection.new(group:, heading: headings.fetch(group.id), workflows:) if workflows.any?
      end
    end

    # A team's heading is its name, or its path when another of the viewer's
    # teams has the same name. Names are unique only under one parent, so a CSR
    # can be in both "Support / Phone" and "Sales / Phone".
    def team_headings(groups)
      colliding = groups.group_by { it.name.downcase }.values.select(&:many?).flatten
      paths = colliding.any? ? Group.paths_by_id : {}
      groups.to_h { [it.id, colliding.include?(it) ? paths.fetch(it.id) : it.name] }
    end

    def live_scenarios
      @live_scenarios ||= Scenario.where(user: user, purpose: "live")
    end

    # Bounded scan: portable across SQLite and Postgres without DISTINCT ON.
    def latest_call_per_workflow
      seen = {}
      started_calls.where(workflow_id: Workflow.visible_to(user).select(:id))
                   .includes(workflow: :tags)
                   .order(created_at: :desc)
                   .limit(RECENTLY_RUN_SCAN)
                   .each do |origin|
        next if seen.key?(origin.workflow_id)

        seen[origin.workflow_id] = origin
        break if seen.size >= RECENTLY_RUN_LIMIT
      end
      seen.values
    end

    def started_calls
      @started_calls ||= live_scenarios.origins
    end
  end
end
