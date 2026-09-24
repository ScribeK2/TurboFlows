require "application_system_test_case"

# Characterization tests for the unified builder at /workflows/:id.
#
# These replace a set deleted on 2026-08-24 that had rotted onto CSS selectors
# from a builder UI that no longer exists (`.step-item`,
# `button[data-step-type='question']`). Written against semantics instead:
# visible button text, the step list's own `data-step-uuid` hooks, and the
# Turbo Frame id the panel actually uses. Those are behavioural contracts, not
# decoration, so restyling will not silently delete this coverage again.
#
# Every assertion here was mutation-verified when written — the behaviour it
# covers was broken on purpose and the test confirmed to go red — because a
# test written against already-passing code proves nothing until you have seen
# it fail.
class WorkflowBuilderTest < ApplicationSystemTestCase
  # STEP_ROW, open_step, assert_panel_settled and panel_body_width live in
  # ApplicationSystemTestCase — all three builder files need them.

  setup do
    @user = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    @workflow = Workflow.create!(title: "Builder E2E Workflow", user: @user, status: "draft")
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "All done", position: 0, resolution_type: "success"
    )
    @workflow.update!(start_step: @resolve)

    sign_in_as @user
  end

  test "adds a step of the type chosen in the picker" do
    visit_builder_in_edit_mode

    assert_step_count 1

    click_on "Add unconnected step"
    click_on "Question"

    assert_step_count 2
    assert_equal 1, @workflow.steps.where(type: "Steps::Question").count
  end

  # Regression: the picker used to be anchored to the bottom prompt, so on a
  # 40-step workflow it opened ~650px below a stub pressed on row 1. Door
  # stubs make the picker's own trigger the main gesture, so it has to open
  # beside whatever was pressed, wherever that row sits in the list.
  test "the type picker opens beside a door stub pressed high in a long list" do
    @resolve.update!(position: 30)
    steps = Array.new(25) { |i| Steps::Action.create!(workflow: @workflow, position: i, title: "Step #{i + 1}") }
    @workflow.update!(start_step: steps.first)

    visit_builder_in_edit_mode
    assert_step_count 26

    page.execute_script("document.querySelector('.builder__list-scroll').scrollTop = 0")

    find("#{STEP_NODE}[data-node-uuid='#{steps.first.uuid}'] .builder__door-stub", match: :first).click
    assert_selector "[data-step-list-target='typePicker']:not(.is-hidden)", wait: 5

    rects = page.evaluate_script(<<~JS)
      (() => {
        const stub = document.querySelector("[data-node-uuid='#{steps.first.uuid}'] .builder__door-stub");
        const menu = document.querySelector("[data-step-list-target='typePicker']");
        const s = stub.getBoundingClientRect();
        const m = menu.getBoundingClientRect();
        return { gap: m.top - s.bottom, top: m.top, bottom: m.bottom, left: m.left, right: m.right,
                 winW: window.innerWidth, winH: window.innerHeight };
      })()
    JS

    assert_operator rects["gap"].abs, :<=, 60,
                    "the picker should open within ~60px of the stub it belongs to, not the bottom prompt"
    assert_operator rects["top"], :>=, 0, "the picker must not open above the viewport"
    assert_operator rects["bottom"], :<=, rects["winH"], "the picker must not open below the viewport"
    assert_operator rects["left"], :>=, 0, "the picker must not open left of the viewport"
    assert_operator rects["right"], :<=, rects["winW"], "the picker must not open right of the viewport"

    click_on "Action"

    assert_eventually(timeout: 10) { @workflow.steps.reload.count == 26 + 1 }
    new_step = @workflow.steps.order(:position).second
    assert_equal "Untitled Action", new_step.title
    assert_equal [new_step], steps.first.reload.transitions.map(&:target_step),
                 "the new step should land directly after row 1 and be connected from it"
  end

  test "each type in the picker creates that type of step" do
    visit_builder_in_edit_mode

    # The picker offers seven types and every one has to build its own class.
    # A single-type test would not have caught the Form step being missing from
    # the surface area, which has happened before in this codebase.
    {
      "Action" => "Steps::Action",
      "Message" => "Steps::Message",
      "Form" => "Steps::Form",
      "Escalate" => "Steps::Escalate"
    }.each do |label, klass|
      click_on "Add unconnected step"
      click_on label
      # Scoped to the list. `data-step-type` is carried by the row *and* by the
      # editor panel, and creating a step now opens that panel — so an unscoped
      # count matches twice. It only ever matched once because the panel was
      # rendering 32px wide and Capybara did not consider it visible.
      within "#steps-list" do
        assert_selector step_row_selector_for(klass), wait: 5, count: 1
      end
    end
  end

  test "removing a step takes its row out of the list" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "Doomed step", position: 1,
      question: "Doomed step", answer_type: "yes_no"
    )

    visit_builder_in_edit_mode
    assert_step_count 2
    assert_selector "#{STEP_ROW}[data-step-uuid='#{question.uuid}']"

    # The delete control is opacity:0 until the row is hovered, so hovering is
    # part of the real interaction rather than a test workaround.
    row = step_row(question.uuid)
    row.hover
    accept_confirm { row.find("button[title='Remove step']").click }

    assert_no_selector "#{STEP_ROW}[data-step-uuid='#{question.uuid}']", wait: 5
    assert_step_count 1
  end

  test "clicking a step row opens its editor in the builder panel" do
    visit_builder_in_edit_mode

    # The panel starts as an empty Turbo Frame, so it has no visible content
    # until a step fills it — hence visible: :all on the frame itself.
    assert_selector "turbo-frame#builder-panel", visible: :all
    assert_no_field "step[title]"

    step_row(@resolve.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_field "step[title]", with: "All done", wait: 5
    end
  end

  # Used to assert this restored as the "Yes" preset in the freeform editor.
  # Step::Doors#reads_as? and condition_preset_controller.js#buildPresets are
  # the same matching, so a condition the preset dropdown would recognise is
  # now claimed as a door before the editor ever sees it - it shows as the
  # wired door row instead, with no dropdown at all.
  test "a yes/no condition is shown as its door, not in Other connections" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "Did it work?", position: 1,
      question: "Did it work?", answer_type: "yes_no", variable_name: "verified"
    )
    Transition.create!(step: question, target_step: @resolve, position: 0, condition: "verified == 'yes'")

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_selector ".step-doors__row", text: /Yes.*All done/m, wait: 5
      find("summary", text: "Other connections").click
      assert_text "No other connections."
    end
  end

  # See the comment above "a yes/no condition is shown as its door...": the
  # same door-matching now claims an option condition before it ever reaches
  # the freeform editor's preset dropdown.
  test "an option condition is shown as its door, not in Other connections" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "What product?", position: 1,
      question: "What product?", answer_type: "dropdown", variable_name: "what",
      options: [{ "label" => "Hosting", "value" => "hosting_email" }]
    )
    Transition.create!(step: question, target_step: @resolve, position: 0, condition: "what == 'hosting_email'")

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_selector ".step-doors__row", text: /Hosting.*All done/m, wait: 5
      find("summary", text: "Other connections").click
      assert_text "No other connections."
    end
  end

  # What this pins: a stored condition comes back as its preset, not as
  # Custom. The two tests above moved that claim onto the door row for the
  # transition Step::Doors claims; this is the same claim for a transition it
  # does not - Step::Doors claims only the first matching transition per door
  # (position order), so a second "verified == 'yes'" transition, on a
  # different target, stays an "extra" the freeform editor still has to
  # restore correctly rather than falling back to Custom. Without this, no
  # test anywhere - controller or system - exercises
  # condition_preset_controller.js's known-preset restore branch at all, since
  # every condition it would recognise is now claimed by a door before the
  # editor ever renders it.
  test "a second transition sharing a door's condition still restores as that preset" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "Did it work?", position: 1,
      question: "Did it work?", answer_type: "yes_no", variable_name: "verified"
    )
    also_yes = Steps::Action.create!(workflow: @workflow, position: 2, title: "Also yes")
    Transition.create!(step: question, target_step: @resolve, position: 0, condition: "verified == 'yes'")
    Transition.create!(step: question, target_step: also_yes, position: 1, condition: "verified == 'yes'")

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_selector ".step-doors__row", text: /Yes.*All done/m, wait: 5
      # Already open: the disclosure starts open whenever it has a row to show
      # (editor_transitions.any?), unlike the empty-state tests above, which
      # open it themselves.
      assert_text "1 connection"

      within all(".transition-item", minimum: 1, wait: 5).last do
        assert_eventually do
          preset_dropdown.value == "yes"
        end
        assert_selector "[data-condition-preset-target='sentenceContainer'].is-hidden", visible: :all
      end
    end
  end

  test "an unmatched condition stays Custom" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "Did it work?", position: 1,
      question: "Did it work?", answer_type: "yes_no", variable_name: "verified"
    )
    Transition.create!(step: question, target_step: @resolve, position: 0, condition: "verified == 'maybe'")

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_selector "select[data-condition-preset-target='presetDropdown']", wait: 5
      assert_eventually do
        preset_dropdown.value == "__custom__"
      end
      kept = find("[data-condition-preset-target='keepAsWritten']", visible: :all)
      assert_includes kept.text, "verified == 'maybe'"
      assert_equal "verified == 'maybe'", condition_hidden.value
    end
  end

  # There is no longer a pre-existing transition to load this against: a
  # blank condition on a Yes/No question is the "Anything else" door
  # (Step::Doors), so it would be claimed before ever reaching this editor.
  # "Add Connection" builds the same freeform row from scratch instead.
  test "choosing Custom shows the sentence, not a raw condition field" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "Did it work?", position: 1,
      question: "Did it work?", answer_type: "yes_no", variable_name: "verified"
    )

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      find("summary", text: "Other connections").click
      click_on "Add Connection"

      within all(".transition-item", minimum: 1, wait: 5).last do
        find("select[data-condition-preset-target='presetDropdown'] option[value='__custom__']").select_option

        assert_selector "[data-condition-preset-target='sentenceContainer']:not(.is-hidden)", wait: 5
        assert_selector "select[data-condition-preset-target='sentenceVariable']"
        assert_no_selector "[data-condition-preset-target='customInput']"
        assert_no_text "e.g., answer =="
      end
    end
  end

  # Same reason as "choosing Custom shows the sentence" above: no pre-existing
  # transition, since a blank one on `later` would be its own "Anything else"
  # door rather than reaching this editor.
  test "Custom can point at another question's Yes" do
    Steps::Question.create!(
      workflow: @workflow, title: "Already verified?", position: 1,
      question: "Already?", answer_type: "yes_no", variable_name: "already_verified"
    )
    later = Steps::Question.create!(
      workflow: @workflow, title: "Did it work?", position: 2,
      question: "Work?", answer_type: "yes_no", variable_name: "verified"
    )

    visit_builder_in_edit_mode
    step_row(later.uuid).click
    assert_panel_settled
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      find("summary", text: "Other connections").click
      click_on "Add Connection"

      within all(".transition-item", minimum: 1, wait: 5).last do
        find("select[data-condition-preset-target='presetDropdown'] option[value='__custom__']").select_option
        assert_selector "select[data-condition-preset-target='sentenceVariable']", wait: 5
        sentence_variable.find("option[value='already_verified']").select_option
        sentence_operator.find("option[value='==']").select_option
        find("[data-condition-preset-target='sentenceValue'] select option[value='yes']").select_option
      end

      assert_eventually do
        condition_hidden.value == "already_verified == 'yes'"
      end
    end
  end

  test "a condition on another question restores as a filled sentence" do
    Steps::Question.create!(
      workflow: @workflow, title: "Already verified?", position: 1,
      question: "Already?", answer_type: "yes_no", variable_name: "already_verified"
    )
    later = Steps::Question.create!(
      workflow: @workflow, title: "Did it work?", position: 2,
      question: "Work?", answer_type: "yes_no", variable_name: "verified"
    )
    Transition.create!(
      step: later, target_step: @resolve, position: 0,
      condition: "already_verified == 'yes'"
    )

    visit_builder_in_edit_mode
    step_row(later.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_eventually { preset_dropdown.value == "__custom__" }
      assert_selector "[data-condition-preset-target='sentenceContainer']:not(.is-hidden)"
      assert_equal "already_verified", sentence_variable.value
      assert_no_selector "[data-condition-preset-target='customInput']"
    end
  end

  test "an unparseable condition is kept as written" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "Did it work?", position: 1,
      question: "Did it work?", answer_type: "yes_no", variable_name: "verified"
    )
    Transition.create!(
      step: question, target_step: @resolve, position: 0,
      condition: "not a real condition"
    )

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_eventually { preset_dropdown.value == "__custom__" }
      kept = find("[data-condition-preset-target='keepAsWritten']", visible: :all)
      assert_includes kept.text, "not a real condition"
      assert_equal "not a real condition", condition_hidden.value
    end
  end

  test "Add Connection's Custom path is the sentence" do
    question = Steps::Question.create!(
      workflow: @workflow, title: "Did it work?", position: 1,
      question: "Did it work?", answer_type: "yes_no", variable_name: "verified"
    )

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      find("summary", text: "Other connections").click
      click_on "Add Connection"
      assert_selector "[data-condition-preset-target='sentenceContainer']", visible: :all, wait: 5
      within all(".transition-item", minimum: 1).last do
        find("select[data-condition-preset-target='presetDropdown'] option[value='__custom__']").select_option
        assert_selector "[data-condition-preset-target='sentenceVariable']"
        assert_no_selector "[data-condition-preset-target='customInput']"
      end
    end
  end

  # The panel is loaded by two different mechanisms and only one of them used to
  # open it. Clicking a row sets the frame's `src`, so Turbo fires
  # `turbo:frame-load` and `builder#panelLoaded` runs. Creating a step injects
  # the same partial with `turbo_stream.replace`, which fires no frame-load at
  # all — so the editor's content arrived and the panel stayed shut: 32px wide,
  # off the right edge of the viewport.
  #
  # Asserting the field is *present* does not catch that; it is present either
  # way, and Capybara calls a 32px-wide field visible. The width is the
  # assertion that bites.
  test "adding a step opens its editor, not merely loads it" do
    visit_builder_in_edit_mode

    click_on "Add unconnected step"
    click_on "Question"

    within "turbo-frame#builder-panel" do
      assert_field "step[title]", wait: 5
    end

    assert_panel_width(:>, 200, "the editor loaded but the panel never opened")
  end

  # Selection used to be painted server-side (a selected_step local on the
  # new row), and #create rebroadcasts the same #steps-list subtree over
  # Action Cable right after responding — with no such local — so a solo
  # editor's own browser raced its own two renders of the row it had just
  # opened. Selection is now derived client-side, from the open panel
  # (builder_controller#syncSelectedRow), so a re-render from elsewhere must
  # not disturb it.
  #
  # The config/cable.yml test adapter does deliver a real broadcast to the
  # browser (it subclasses Async) — confirmed against the pre-fix code, where
  # a real Turbo::StreamsChannel.broadcast_update_to call here did strip the
  # row's selected class. But its delivery latency is real network time: the
  # same broadcast, run in isolation rather than inside the full suite, did
  # not land within this test's 5s wait at all, so a test built on it would
  # pass or fail depending on what else the suite is doing at the time.
  # Injecting the same stream via Turbo.renderStreamMessage happens
  # synchronously in the browser, so it exercises the identical client-side
  # path (turbo:before-stream-render → syncSelectedRow) without that variance.
  test "a grown step's selection survives a list re-render from elsewhere" do
    visit_builder_in_edit_mode

    click_on "Add unconnected step"
    click_on "Action"

    # Wait on the DOM, not the database directly: the click only fires the
    # request, and querying the row before the response lands races it.
    assert_selector "[data-step-type='action'].builder__step--selected", wait: 5
    grown = @workflow.steps.reload.find_by!(type: "Steps::Action")

    html = ApplicationController.render(
      partial: "workflows/steps_list_items",
      locals: { workflow: @workflow.reload, steps: @workflow.steps.reload.ordered.includes(transitions: :target_step) }
    )
    stream = %(<turbo-stream action="update" target="steps-list"><template>#{html}</template></turbo-stream>)
    page.execute_script("Turbo.renderStreamMessage(#{stream.to_json})")

    assert_selector "[data-step-id='#{grown.id}'].builder__step--selected", wait: 5
  end

  test "closing the panel collapses it again" do
    visit_builder_in_edit_mode
    step_row(@resolve.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_field "step[title]", wait: 5
    end

    assert_panel_settled

    find("[data-action~='click->builder#closePanel']", match: :first).click

    assert_panel_width(:==, 0, "closing must actually collapse the panel")
  end

  test "editing a step title autosaves and survives a reload" do
    visit_builder_in_edit_mode
    step_row(@resolve.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_field "step[title]", with: "All done", wait: 5
      fill_in "step[title]", with: "Renamed by autosave"
    end

    # Autosave is debounced at 2000ms (inline-autosave-delay-value). Polling the
    # record rather than sleeping a flat interval keeps this honest: it fails if
    # the save never lands, instead of passing because the sleep outlasted a
    # broken debounce.
    assert_eventually(timeout: 10) { @resolve.reload.title == "Renamed by autosave" }

    visit workflow_path(@workflow)
    assert_text "Renamed by autosave"
  end

  # A Form step's field inputs carried no data-action at all, so editing a
  # field's label, name, required flag or its select choices fired no request.
  # The edit persisted only if the operator ALSO touched the step title or
  # instructions, whose save carried the whole `options` array along with it —
  # which is why the form builder looked like it worked.
  #
  # Only a browser can catch this: every server-side test posts the params
  # directly and so asserts nothing about whether anything would have posted
  # them. That is exactly how it shipped.
  test "editing a form field autosaves without touching the step title" do
    form = Steps::Form.create!(
      workflow: @workflow, title: "Collect details", position: 1,
      options: [{ "name" => "channel", "label" => "Channel", "field_type" => "text",
                  "required" => false, "position" => 0 }]
    )
    Transition.create!(step: form, target_step: @resolve, position: 0)
    @workflow.update!(start_step: form)

    visit_builder_in_edit_mode
    step_row(form.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_field "step[options][][label]", with: "Channel", wait: 5
      fill_in "step[options][][label]", with: "Contact channel"
    end

    assert_eventually(timeout: 10) do
      form.reload.options.first["label"] == "Contact channel"
    end
  end

  # The rows "Add Field" builds are created in JavaScript rather than rendered
  # from the template, so a fix applied only to the ERB would leave them silently
  # unsaveable while the existing rows worked — a worse failure than the uniform
  # one it replaced. The autosave action lives on the wrapper and these events
  # bubble, which is what makes one declaration cover both.
  test "a field added in the builder is saved too" do
    form = Steps::Form.create!(
      workflow: @workflow, title: "Collect details", position: 1,
      options: [{ "name" => "channel", "label" => "Channel", "field_type" => "text",
                  "required" => false, "position" => 0 }]
    )
    Transition.create!(step: form, target_step: @resolve, position: 0)
    @workflow.update!(start_step: form)

    visit_builder_in_edit_mode
    step_row(form.uuid).click
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_field "step[options][][label]", with: "Channel", wait: 5
      click_button "Add Field"
      all("input[name='step[options][][name]']").last.set("urgency")
      all("input[name='step[options][][label]']").last.set("Urgency")
    end

    assert_eventually(timeout: 10) do
      form.reload.options.pluck("name") == %w[channel urgency]
    end
  end

  # "+ Add Option" built its inputs with the wizard's names,
  # workflow[steps][][options][], which StepsController never reads, and no
  # option input asked for an autosave. An option added in the panel was
  # dropped even when another field's save carried the form along.
  test "an option added to a question in the builder is saved" do
    question = question_with_options([{ "label" => "Phone", "value" => "phone" }])

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled
    # "+ Add Option" moves while the panel animates open; a click that lands
    # mid-animation adds no row, and the test then types into the Phone row.
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_field "step[options][][label]", with: "Phone", wait: 5
      click_button "+ Add Option"
      all("input[name='step[options][][label]']").last.set("Email")
      all("input[name='step[options][][value]']").last.set("email")
    end

    assert_eventually(timeout: 10) do
      question.reload.options == [{ "label" => "Phone", "value" => "phone" }, { "label" => "Email", "value" => "email" }]
    end
  end

  test "removing a question option in the builder is saved" do
    question = question_with_options([{ "label" => "Phone", "value" => "phone" }, { "label" => "Email", "value" => "email" }])

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_field "step[options][][label]", with: "Email", wait: 5
      # The remove button only shows while its row is hovered (forms.css).
      row = find_field("step[options][][label]", with: "Email").ancestor(".option-item")
      row.hover
      row.find("button[title='Remove option']").click
    end

    assert_eventually(timeout: 10) do
      question.reload.options == [{ "label" => "Phone", "value" => "phone" }]
    end
  end

  # The 1 -> 0 case. An HTML form posts no key at all for an empty list, so
  # this save carried no `options` and the server, permitting nothing for it,
  # kept the option that had just been removed - it came back on reload.
  test "removing a question's only option in the builder is saved" do
    question = question_with_options([{ "label" => "Phone", "value" => "phone" }])

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled
    assert_panel_settled

    within "turbo-frame#builder-panel" do
      assert_field "step[options][][label]", with: "Phone", wait: 5
      row = find_field("step[options][][label]", with: "Phone").ancestor(".option-item")
      row.hover
      row.find("button[title='Remove option']").click
    end

    assert_eventually(timeout: 10) { question.reload.options == [] }

    # And the step is saveable afterwards: a Question with no options at all is
    # what the health check asks about, not something the panel refuses.
    within("turbo-frame#builder-panel") { fill_in "step[title]", with: "No options left" }
    assert_eventually(timeout: 10) { question.reload.title == "No options left" }
    assert_equal [], question.reload.options
  end

  # The marker above must stay off for a Question that takes no options, or
  # every save would carry `options` - writing [] over a nil and streaming the
  # doors on each one (DOOR_DECIDING_PARAMS reads the key, not a change).
  test "saving a Yes/No question does not send an options list it never had" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light?", question: "Light?",
                                       position: 9, answer_type: "yes_no", variable_name: "light")

    visit_builder_in_edit_mode
    step_row(question.uuid).click
    assert_panel_settled
    assert_panel_settled

    within("turbo-frame#builder-panel") { fill_in "step[title]", with: "Is the light green?" }

    assert_eventually(timeout: 10) { question.reload.title == "Is the light green?" }
    assert_nil question.reload.options
  end

  # A new Question starts with no question text, and that field was `required`.
  # requestSubmit() runs the browser's required check, so two seconds after the
  # title was typed the browser refused the save, moved the cursor into the
  # empty field, and the title was never sent, not even when the panel closed.
  test "a new question's title saves before its question text is typed" do
    visit_builder_in_edit_mode
    click_on "Add unconnected step"
    click_on "Question"

    within "turbo-frame#builder-panel" do
      assert_field "step[title]", with: "Untitled Question", wait: 5
      fill_in "step[title]", with: "Caller verified"
    end

    # `reload`, not a repeated query: this thread's query cache would answer
    # the same SELECT with the title from before the save.
    question = @workflow.steps.find_by!(type: "Steps::Question")
    assert_eventually(timeout: 10) { question.reload.title == "Caller verified" }
  end

  # "+ Add Field" appends a row whose name and label are empty and `required`.
  test "a form step's title still saves after a field is added" do
    visit_builder_in_edit_mode
    click_on "Add unconnected step"
    click_on "Form"

    within "turbo-frame#builder-panel" do
      assert_field "step[title]", with: "Untitled Form", wait: 5
      click_button "Add Field"
      fill_in "step[title]", with: "Collect callback details"
    end

    # The row "+ Add Field" added was never filled in, so it isn't stored.
    form = @workflow.steps.find_by!(type: "Steps::Form")
    assert_eventually(timeout: 10) { form.reload.title == "Collect callback details" && form.fields.empty? }
  end

  # A Sub-Flow added from the picker has no target yet, and until one was picked
  # every workflow save was refused: the header said "Save failed" and the new
  # title was gone after a reload.
  test "the workflow still renames while a new sub-flow has no target" do
    visit_builder_in_edit_mode
    click_on "Add unconnected step"
    click_on "Sub-Flow"
    within("#steps-list") { assert_selector step_row_selector_for("Steps::SubFlow"), wait: 5 }

    title = find("input[placeholder='Workflow title...']")
    title.set("Renamed with a sub-flow pending")
    title.send_keys(:tab)

    assert_eventually(timeout: 10) { @workflow.reload.title == "Renamed with a sub-flow pending" }
  end

  # The title field saved on blur/change ONLY, while every other builder field
  # autosaves on a debounce. An author who renames the workflow and goes straight
  # to a step — never blurring the field, because clicking a step row inside the
  # builder does not always take focus out of it — lost the rename with nothing
  # said. Typed here and deliberately never blurred.
  test "the workflow title saves without being blurred" do
    visit_builder_in_edit_mode
    find("input[placeholder='Workflow title...']").set("Renamed and never blurred")

    assert_eventually(timeout: 10) { @workflow.reload.title == "Renamed and never blurred" }
  end

  # The Details panel shows the server's reason through its Turbo Stream; the
  # header title saves through fetch and overwrote it with a bare "Save failed".
  test "a refused title save says why in the header" do
    visit_builder_in_edit_mode
    title = find("input[placeholder='Workflow title...']")
    title.set("x" * 256)
    title.send_keys(:tab)

    assert_selector "#autosave-status", text: "Save failed — Title is too long (maximum is 255 characters)", wait: 10
  end

  test "a large workflow renders every step row" do
    # The deleted version of this asserted a 5 second wall-clock budget. That is
    # the kind of timing assertion that fails for reasons unrelated to the code,
    # which is exactly the flakiness this suite was just cleaned of. What is
    # worth protecting is that nothing truncates or paginates the list.
    50.times do |i|
      Steps::Action.create!(
        workflow: @workflow, title: "Bulk step #{i}", position: i + 1,
        action_type: "Instruction"
      )
    end

    visit_builder_in_edit_mode

    assert_step_count 51
    assert_selector STEP_ROW, count: 51, wait: 10
  end

  private

  # The panel animates over --duration-normal, so a width read the instant after
  # a click catches it mid-transition. Poll like Capybara does rather than
  # sleeping a fixed amount.
  def assert_panel_width(operator, expected, message, timeout: 5)
    deadline = Time.current + timeout
    width = panel_body_width
    while !width.public_send(operator, expected) && Time.current < deadline
      sleep 0.1
      width = panel_body_width
    end

    assert width.public_send(operator, expected), "#{message} (#{width}px wide)"
  end

  def visit_builder_in_edit_mode
    visit workflow_path(@workflow, edit: true)
    assert_selector "[data-builder-mode-value='edit']", wait: 5
  end

  def question_with_options(options)
    question = Steps::Question.create!(workflow: @workflow, title: "Contact channel?", position: 1,
                                       question: "How did they reach us?", answer_type: "multiple_choice", options:)
    Transition.create!(step: question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: question)
    question
  end

  def step_row(uuid)
    find("#{STEP_ROW}[data-step-uuid='#{uuid}']")
  end

  def preset_dropdown
    find("select[data-condition-preset-target='presetDropdown']")
  end

  def sentence_variable
    find("select[data-condition-preset-target='sentenceVariable']")
  end

  def sentence_operator
    find("select[data-condition-preset-target='sentenceOperator']")
  end

  def condition_hidden
    find("[data-condition-preset-target='conditionHidden']", visible: :all)
  end

  def assert_step_count(expected)
    assert_selector STEP_ROW, count: expected, wait: 5
  end

  def step_row_selector_for(klass)
    "[data-step-type='#{klass.demodulize.underscore}']"
  end

  # Polls a condition instead of sleeping past a debounce. Returns as soon as
  # the block is true, and fails loudly with the elapsed time if it never is.
  def assert_eventually(timeout: 5, interval: 0.2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "condition never became true within #{timeout}s"
      end
      sleep interval
    end
  end
end
