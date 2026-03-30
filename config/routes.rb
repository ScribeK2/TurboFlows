Rails.application.routes.draw do
  devise_for :users, controllers: {
    registrations: 'users/registrations'
  }
  root to: 'dashboard#index'

  # Mount ActionCable
  mount ActionCable.server => '/cable'

  resources :workflows do
    collection do
      get :import
      post :import_file
    end
    member do
      get :export
      get :export_pdf
      get :preview
      get :variables
      get :start
      post :begin_execution
      # Publishing & versioning
      post :publish
      get :versions
      # AR step persistence
      patch :sync_steps
      # Builder panel routes
      get :flow_diagram
      get :settings
      # Tag assignment
      post :add_tag
      delete :remove_tag
    end
    resources :versions, only: [:show], controller: "workflow_versions" do
      member do
        post :restore
      end
    end
    resources :scenarios, only: %i[new create]
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

  resources :tags, only: [:index, :create, :destroy]

  # Folder management (accessible to editors/admins)
  patch 'folders/move_workflow', to: 'folders#move_workflow', as: :move_workflow_folder

  # Session heartbeat (for client-side timeout detection)
  get "session/heartbeat", to: "sessions#heartbeat", as: :session_heartbeat

  # Nav menu and search
  get "nav/menu", to: "nav#menu", as: :nav_menu
  get "nav/search_data", to: "nav#search_data", as: :nav_search_data

  resources :scenarios, only: [:show] do
    member do
      post :next_step
      get :step
      post :stop
    end
  end

  # Admin namespace
  namespace :admin do
    root to: 'dashboard#index'
    resources :users, only: %i[index update] do
      collection do
        patch :bulk_assign_groups
        patch :bulk_update_role
        patch :bulk_deactivate
      end
      member do
        patch :update_role
        patch :update_groups
        post :reset_password
      end
    end
    resources :workflows, only: %i[index show destroy]
    resources :groups do
      patch 'folders/reorder', to: 'folders#reorder', as: :reorder_folders
      resources :folders, except: [:show]
    end
    get "analytics", to: "analytics#index", as: :analytics
  end
end
