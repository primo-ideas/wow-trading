class MarketsController < ApplicationController
  def index
    @query = params[:q].to_s.delete("\0").strip
    @markets = AuctionHouse.matching(@query).with_latest_snapshot.listing_order
    @any_market = AuctionHouse.exists?
  end

  def show
    @market = AuctionHouse.find(params[:id])
    @listing = MarketListing.new(@market, query: params[:q], sort: params[:sort], page: params[:page])
  end
end
