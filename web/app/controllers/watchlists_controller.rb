class WatchlistsController < ApplicationController
  def show
    @products = current_realm ? watchlist.products(current_realm.markets) : []
    @at_target = current_realm ? watchlist.at_target(current_realm.markets) : []
  end

  def update
    watchlist.toggle(params[:item_id], params[:series])
    save_watchlist
    redirect_back_or_to watchlist_path, status: :see_other
  end

  # An empty field takes the target off. What cannot be read as an amount changes nothing.
  def target
    text = params[:target].to_s.strip
    target = MoneyInput.parse(text)
    if text.empty? || target
      watchlist.set_target(params[:item_id], params[:series], target)
      save_watchlist
    else
      flash[:alert] = "“#{text.first(30)}” is not an amount: write it like 12g 50s, or 12.5 for gold."
    end
    redirect_back_or_to watchlist_path, status: :see_other
  end

  private

  def save_watchlist
    cookies[:watched] = cookie_options.merge(value: watchlist.to_cookie)
    cookies.delete(:watchlist, path: cookie_options[:path])
  end
end
