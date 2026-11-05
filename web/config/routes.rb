Rails.application.routes.draw do
  # run.ps1 polls this to know when the site is up.
  get "up" => "rails/health#show", as: :rails_health_check

  root "realms#home"

  get "realms" => "realms#index", as: :realms

  resource :watchlist, only: %i[show update]

  # Everything is seen from a player's realm: /eu/hyjal, /eu/hyjal/items/2589.
  constraints region: /us|eu|kr|tw/, realm: %r{[^/.]+} do
    get ":region/:realm" => "realms#show", as: :realm
    get ":region/:realm/deals" => "realms#deals", as: :realm_deals
    get ":region/:realm/search" => "search#show", as: :realm_search
    get ":region/:realm/items/:id" => "items#show", as: :realm_item, constraints: { id: /\d{1,9}/ }
    get ":region/:realm/items/:id/tooltip" => "items#tooltip", as: :realm_item_tooltip, constraints: { id: /\d{1,9}/ }
  end

  # Addresses from when the site was organised by market, which bookmarks may still hold.
  get "search" => "legacy#search"
  get "markets" => "legacy#markets"
  get "markets/:id" => "legacy#market", constraints: { id: /\d{1,9}/ }
  get "markets/:id/deals" => "legacy#deals", constraints: { id: /\d{1,9}/ }
  get "markets/:market_id/items/:id" => "legacy#item", constraints: { market_id: /\d{1,9}/, id: /\d{1,9}/ }
end
