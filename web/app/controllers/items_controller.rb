class ItemsController < ApplicationController
  def show
    @market = AuctionHouse.find(params[:market_id])
    @item = Item.find(params[:id])
    @variants = variants_on_sale
    @variant = params[:variant]&.to_s&.delete("\0") || default_variant
    @history = ItemHistory.new(@market, @item, variant: @variant, period: params[:period])
  end

  private

  def variants_on_sale
    latest = @market.latest_snapshot_at
    return [] unless latest

    PricePoint
      .where(auction_house_id: @market.id, item_id: @item.id, taken_at: latest)
      .order(:variant)
      .pluck(:variant)
  end

  # A caged pet or a piece of gear has no plain variant: its first one stands in.
  def default_variant
    @variants.include?("") ? "" : @variants.first.to_s
  end
end
