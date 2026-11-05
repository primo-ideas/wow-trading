class RealmsController < ApplicationController
  before_action :load_realm, only: %i[show deals]

  # Straight to a returning player's realm.
  def home
    return redirect_to realm_path(remembered_realm.region, remembered_realm.slug) if remembered_realm

    index
    render :index
  end

  # Where a player picks their realm. With an item, picking leads to its page there.
  def index
    @realms = Realm.followed(tracked_markets).to_a
    @query = params[:q].to_s.delete("\0").strip.first(100)
    @item = Item.find_by(id: params[:item].to_s[/\A\d{1,9}\z/])
    @variant = params[:variant].to_s.delete("\0").presence if @item
  end

  def show
    markets = current_realm.markets
    @listing = MarketListing.new(markets,
      query: params[:q], item_class: params[:item_class], quality: params[:quality],
      sort: params[:sort], dir: params[:dir], page: params[:page])
    @movers = MarketMovers.new(markets)
    @item_classes = Rails.cache.fetch("item_classes", expires_in: 1.hour) do
      Item.where.not(item_class: nil).distinct.pluck(:item_class)
        .sort_by { |name| ActiveSupport::Inflector.transliterate(name) }
    end
  end

  def deals
    @deals = MarketDeals.new(current_realm.markets, sort: params[:sort])
  end
end
