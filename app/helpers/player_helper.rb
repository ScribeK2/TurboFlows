module PlayerHelper
  def player_back_button(scenario)
    return nil unless scenario.execution_path.present? && scenario.execution_path.length > 0

    link_to player_scenario_back_path(scenario),
            class: "scenario-btn-cancel",
            data: { turbo_method: :post } do
      raw('<svg class="icon icon--sm" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"></path></svg>') + "Back"
    end
  end
end
