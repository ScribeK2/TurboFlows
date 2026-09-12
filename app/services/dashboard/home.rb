module Dashboard
  # The Editor and Admin home page: the viewer's own work, and for an admin what
  # waits on an administrator (spec docs/designs/2026-09-12-editor-admin-home.md).
  #
  # The page renders in one response with nothing loaded after it, so everything
  # here is bounded. The one per-workflow cost is the hero's health check, and it
  # runs only for a draft.
  class Home
    RECENT_LIMIT = 6 # the hero plus five
    NAMED_LIMIT = 5

    attr_reader :viewer

    delegate :admin?, to: :viewer

    def initialize(viewer)
      @viewer = viewer
    end

    # [workflow, last_edited_at], or nil when there is nothing to continue.
    def hero
      recent.first
    end

    def also_recent
      recent.drop(1)
    end

    # An admin who has built nothing sees the library's recent edits instead.
    def showing_library?
      return @showing_library if defined?(@showing_library)

      @showing_library = admin? && !own_with_steps.exists?
    end

    # The hero's publish blockers when it is a draft. A published hero is not
    # checked: nothing on it is "before publishing".
    def hero_blockers
      return @hero_blockers if defined?(@hero_blockers)

      workflow = hero&.first
      @hero_blockers = workflow&.draft? ? WorkflowHealthCheck.call(workflow).publish_blockers : nil
    end

    def draft_count
      @draft_count ||= own_drafts.count
    end

    def named_drafts
      @named_drafts ||= Workflow.recently_edited(own_drafts, limit: NAMED_LIMIT).map(&:first)
    end

    # None for an admin: the attention strip counts every published workflow with
    # no audience, theirs included, and the same problem must not appear twice.
    def no_audience_count
      return 0 if admin?

      @no_audience_count ||= own_no_audience.count
    end

    def named_no_audience
      return [] if admin?

      @named_no_audience ||= own_no_audience.order(updated_at: :desc).limit(NAMED_LIMIT).to_a
    end

    def waiting?
      draft_count.positive? || no_audience_count.positive?
    end

    def attention
      return unless admin?

      @attention ||= Admin::Attention.new
    end

    private

    def recent
      @recent ||= Workflow.recently_edited(showing_library? ? library : own_with_steps, limit: RECENT_LIMIT)
    end

    # An empty draft is not work to continue: Create Workflow reuses one, and it
    # is swept once orphaned.
    def own_with_steps
      Workflow.where(user: viewer, steps_count: 1..)
    end

    def own_drafts
      own_with_steps.draft
    end

    def own_no_audience
      Workflow.published_without_audience.where(user: viewer)
    end

    def library
      Workflow.where(id: Workflow.visible_to(viewer).select(:id))
              .or(Workflow.where(id: Workflow.drafts_visible_to(viewer).select(:id)))
              .where(steps_count: 1..)
    end
  end
end
