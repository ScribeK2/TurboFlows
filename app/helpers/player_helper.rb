module PlayerHelper
  def player_back_button(scenario)
    return nil unless scenario.execution_path.present? && scenario.execution_path.length.positive?

    link_to player_scenario_back_path(scenario),
            class: "scenario-btn-cancel",
            data: { turbo_method: :post } do
      back_icon = '<svg class="icon icon--sm" fill="none" stroke="currentColor" viewBox="0 0 24 24">' \
                  '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"></path></svg>'
      raw(back_icon) + "Back" # rubocop:disable Style/StringConcatenation -- SafeBuffer#+ preserves html_safe
    end
  end
end
