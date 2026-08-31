require "test_helper"

# Every class the Player renders must be styled by a stylesheet the Player loads.
#
# The Player has its own layout and its own hand-picked `stylesheet_link_tag`
# list — a subset of the application layout's. That is deliberate (it is a
# standalone surface and does not want the builder's CSS), but it means shared
# chrome can be styled in a sheet the Player does not load, and there is no
# error when that happens: the class simply matches nothing.
#
# It is not a subtle failure either. `reset.css` neutralises only `font` and
# `color` on a button, so an unstyled `<button>` falls back to raw browser
# chrome — grey fill, outset bevel, square corners. That is exactly what
# `.dark-mode-toggle` did in the Player for as long as it lived in
# `navigation.css`, which only the application layout loads.
#
# The assertion is deliberately narrow: a class is a failure only when some
# stylesheet defines it and none of the Player's do. A class styled nowhere at
# all is ordinary — Stimulus targets and JS state hooks carry no rules — and
# flagging those would make this test noise rather than a guard.
class PlayerLayoutStylesheetCoverageTest < ActionDispatch::IntegrationTest
  STYLESHEET_DIR = Rails.root.join("app/assets/stylesheets")
  PLAYER_LAYOUT  = Rails.root.join("app/views/layouts/player.html.erb")

  setup do
    @user = User.create!(
      email: "coverage-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    sign_in @user

    @workflow = Workflow.create!(title: "Coverage Workflow", user: @user, status: "published")
    @question = Steps::Question.create!(workflow: @workflow, position: 0, title: "Coverage Question",
                                        question: "Is it styled?", variable_name: "styled",
                                        answer_type: "yes_no")
    @resolve = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Coverage Done",
                                      resolution_type: "success")
    Transition.create!(step: @question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @question)
  end

  test "the Player's index styles every class it renders" do
    get play_path

    assert_response :success
    assert_no_unstyled_classes response.body, "the Player index"
  end

  test "the Player's step styles every class it renders" do
    get player_scenario_step_path(open_run)

    assert_response :success
    assert_no_unstyled_classes response.body, "the Player step"
  end

  test "the Player's completion screen styles every class it renders" do
    get player_scenario_show_path(finished_run)

    assert_response :success
    assert_no_unstyled_classes response.body, "the Player completion screen"
  end

  private

  def open_run
    Scenario.create!(
      workflow: @workflow, user: @user, purpose: "live", started_at: Time.current,
      current_node_uuid: @question.uuid, execution_path: [], results: {}, inputs: {}
    )
  end

  def finished_run
    scenario = Scenario.create!(
      workflow: @workflow, user: @user, purpose: "live", started_at: Time.current,
      current_node_uuid: @resolve.uuid, execution_path: [], results: {}, inputs: {}
    )
    ScenarioSettler.new(scenario).settle(nil, resolved_here: true)
    scenario.reload
  end

  def assert_no_unstyled_classes(html, surface)
    loaded = player_stylesheets
    defined_in = class_definitions

    orphans = rendered_classes(html).filter_map do |klass|
      sheets = defined_in[klass]
      next if sheets.nil? || sheets.intersect?(loaded)

      "  .#{klass} — styled in #{sheets.to_a.sort.join(', ')}"
    end

    assert_empty orphans, <<~MESSAGE
      #{surface} renders classes that are styled only by stylesheets it does not load,
      so they render with no styles at all — a button falls back to browser chrome:

      #{orphans.sort.join("\n")}

      The Player loads: #{loaded.to_a.sort.join(', ')}

      Fix by moving the rule into a sheet every layout loads (shared chrome belongs
      in the components layer, not in a page module), rather than by appending the
      module to the Player's list.
    MESSAGE
  end

  # The sheet names in the layout's `stylesheet_link_tag`, read from the layout
  # itself so the test cannot drift from what the Player actually serves.
  def player_stylesheets
    call = PLAYER_LAYOUT.read[/stylesheet_link_tag(.*?)%>/m]
    assert call, "could not find stylesheet_link_tag in #{PLAYER_LAYOUT}"

    call.split(/\bdata:|"data-turbo-track"/).first.scan(/"([\w-]+)"/).flatten.to_set
  end

  # class name => set of stylesheets defining it, across every sheet on disk.
  #
  # Only selector text is scanned — the run up to each `{` — so a class named
  # in a declaration value cannot be mistaken for a definition. Comments go
  # first for the same reason: several of them cite class names, and this
  # guide-heavy codebase has more prose in its CSS than most.
  def class_definitions
    @class_definitions ||= Dir[STYLESHEET_DIR.join("*.css")].each_with_object({}) do |path, map|
      selectors = File.read(path).gsub(%r{/\*.*?\*/}m, "").scan(/([^{}]*)\{/).flatten

      selectors.join(" ").scan(/\.(-?[_a-zA-Z][\w-]*)/).flatten.uniq.each do |klass|
        (map[klass] ||= Set.new) << File.basename(path, ".css")
      end
    end
  end

  def rendered_classes(html)
    Nokogiri::HTML(html).css("[class]").flat_map { |node| node["class"].split }.uniq
  end
end
