class WatchlistsController < ApplicationController
  def show
    @products = current_realm ? watchlist.products(current_realm.markets) : []
  end

  def update
    watchlist.toggle(params[:item_id], params[:series])
    cookies[:watched] = cookie_options.merge(value: watchlist.to_cookie)
    cookies.delete(:watchlist, path: cookie_options[:path])
    redirect_back_or_to watchlist_path, status: :see_other
  end
end
