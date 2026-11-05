Rails.application.routes.draw do
  # run.ps1 polls this to know when the site is up.
  get "up" => "rails/health#show", as: :rails_health_check

  root "markets#home"

  get "search" => "search#show"

  resource :watchlist, only: %i[show update]

  resources :markets, only: %i[index show] do
    get :deals, on: :member
    resources :items, only: :show
  end
end
