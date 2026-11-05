class MarketsController < ApplicationController
  # Straight to a returning player's market.
  def home
    return redirect_to market_path(remembered_market) if remembered_market

    render :index
  end

  def index
  end

  def deals
    @market = AuctionHouse.find(params[:id])
    remember(@market)
    @deals = MarketDeals.new(@market, sort: params[:sort])
  end

  def show
    @market = AuctionHouse.find(params[:id])
    remember(@market)
    @listing = MarketListing.new(@market,
      query: params[:q], item_class: params[:item_class], quality: params[:quality],
      sort: params[:sort], dir: params[:dir], page: params[:page])
    @movers = MarketMovers.new(@market)
    @item_classes = Rails.cache.fetch("item_classes", expires_in: 1.hour) do
      Item.where.not(item_class: nil).distinct.pluck(:item_class)
        .sort_by { |name| ActiveSupport::Inflector.transliterate(name) }
    end
  end
end
