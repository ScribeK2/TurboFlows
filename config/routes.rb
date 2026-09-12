Rails.application.routes.draw do
  get "healthz", to: proc { [200, {}, ["OK"]] }

  devise_for :users, controllers: {
    registrations: 'users/registrations',
    sessions: 'users/sessions'
  }

  resource :first_run, only: %i[new create]
  # A person in no group chooses their own (spec 2026-09-11 Q3).
  resource :welcome, only: %i[show create] do
    resource :skip, only: :create, module: :welcomes
  end
  resource :profile, only: %i[edit update] do
    # My groups (spec 2026-09-11 Q8).
    resources :memberships, only: %i[create destroy], module: :profiles
  end
  root to: 'dashboard#index'

  # Mount ActionCable
  mount ActionCable.server => '/cable'

  resources :workflows do
    resource :preview, only: [:show], controller: "workflows/previews"
    resource :variables, only: [:show], controller: "workflows/variables"
    resource :flow_diagram, only: [:show], controller: "workflows/flow_diagrams"
    resource :settings, only: [:show], controller: "workflows/settings"
    resources :versions, only: [:index], controller: "workflows/versions"
    resource :execution, only: %i[new create], controller: "workflows/executions"
    resource :publishing, only: [:create], controller: "workflows/publishings" do
      get :confirm
    end
    resources :taggings, only: %i[create destroy], controller: "workflows/taggings", param: :tag_id
    resource :share, only: %i[create destroy], controller: "workflows/shares"
    resource :pin, only: %i[create destroy], controller: "workflows/pins"
    resource :export, only: [:show], controller: "workflows/exports" do
      get :pdf, on: :member
    end
    resource :health, only: [:show], controller: "workflows/healths"
    resource :health_fix, only: [:create], controller: "workflows/health_fixes"
    # WorkflowVersionsController handles show/diff/restore (versioned snapshots)
    get "versions/diff", to: "workflow_versions#diff", as: :diff_versions
    get "versions/:id", to: "workflow_versions#show", as: :version
    post "versions/:id/restore", to: "workflow_versions#restore", as: :restore_version
    # The changelog is written AFTER the fact, not on publish: publishing a single
    # workflow is one click, and a modal there to capture an optional field is the
    # one people dismiss — which buys the friction and the empty column both.
    patch "versions/:id", to: "workflow_versions#update", as: :update_version
    resources :steps, except: [:index] do
      collection do
        post :apply_template
      end
      member do
        patch :reorder
        get :panel_edit
      end
    end
  end

  # Workflow import (collection-level, not per-workflow)
  resource :workflow_import, only: %i[new create], controller: "workflows/imports",
                             path: "workflows/import" do
    post :commit
  end

  resources :tags, only: %i[index create destroy]

  # Folder management (accessible to editors/admins)
  patch 'folders/move_workflow', to: 'folders#move_workflow', as: :move_workflow_folder

  # Session heartbeat (for client-side timeout detection)
  get "session/heartbeat", to: "sessions#heartbeat", as: :session_heartbeat

  # Nav menu and search
  get "nav/search_data", to: "nav#search_data", as: :nav_search_data

  resources :scenarios, only: [:show] do
    member do
      post :next_step
      get :step
      post :back
      post :stop
    end
  end

  # Shared player route (no auth required)
  get "s/:share_token", to: "player#show_shared", as: :shared_player

  # Player routes (authenticated)
  get "play", to: "player#index", as: :play
  post "play/:id", to: "player#start", as: :play_workflow
  scope "player/scenarios/:id" do
    get "step", to: "player#step", as: :player_scenario_step
    post "next", to: "player#next_step", as: :player_scenario_next
    post "back", to: "player#back", as: :player_scenario_back
    post "stop", to: "player#stop", as: :player_scenario_stop
    get "show", to: "player#show", as: :player_scenario_show
  end

  # Analytics, for administrators and the managers of groups (spec 2026-09-12).
  # It left the admin area so a manager can use it without being an admin; the
  # old address stays as a redirect for bookmarks.
  get "analytics", to: "analytics#index", as: :analytics
  namespace :analytics do
    resources :agents, only: :show
    resources :runs, only: :show
  end
  get "admin/analytics", to: redirect(lambda { |_params, request|
    ["/analytics", request.query_string.presence].compact.join("?")
  })

  # Admin namespace
  namespace :admin do
    root to: 'dashboard#index'
    resources :users, only: %i[index show update] do
      collection do
        patch :bulk_assign_groups
        patch :bulk_update_role
        patch :bulk_deactivate
      end
      member do
        patch :update_role
        patch :update_groups
        post :reset_password
        patch :deactivate
        patch :reactivate
      end
    end
    resource :smtp_setting, only: %i[show update], path: "email" do
      post :test_delivery
    end
    resources :groups do
      resources :memberships, only: %i[index create destroy]
      resources :managers, only: %i[index create destroy], controller: "group_managers"
      patch 'folders/reorder', to: 'folders#reorder', as: :reorder_folders
      resources :folders, only: %i[create update destroy]
    end
    get "data_health", to: "data_health#index", as: :data_health
    post "data_health/cleanup_drafts", to: "data_health#cleanup_drafts", as: :data_health_cleanup_drafts
    resources :failed_jobs, only: :destroy, path: "data_health/failed_jobs" do
      resource :retry, only: :create, module: :failed_jobs
    end
  end
end
