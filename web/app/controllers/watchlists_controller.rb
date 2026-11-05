class WatchlistsController < ApplicationController
  def show
    products = watchlist.products.group_by(&:auction_house_id)
    @groups = tracked_markets.filter_map { |market| [ market, products[market.id] ] if products.key?(market.id) }
  end

  def update
    watchlist.toggle(params[:market_id], params[:item_id], params[:series])
    cookies[:watchlist] = { value: watchlist.to_cookie, expires: 1.year, same_site: :lax, path: cookie_path }
    redirect_back_or_to watchlist_path, status: :see_other
  end
end
