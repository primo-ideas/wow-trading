class ItemsController < ApplicationController
  def show
    @market = AuctionHouse.find(params[:market_id])
    remember(@market)
    @item = Item.find(params[:id])
    @variants = variants_on_sale
    @variant = params[:variant]&.to_s&.delete("\0") || @variants.first&.variant.to_s
    @product = Product.new(@item, @variant)
    @history = ItemHistory.new(@market, @item, variant: @variant, period: params[:period])
  end

  private

  # The most listed first, which is also the one a page opens on.
  def variants_on_sale
    latest = @market.latest_snapshot_at
    return [] unless latest

    PricePoint
      .where(auction_house_id: @market.id, item_id: @item.id, taken_at: latest)
      .order(quantity: :desc, variant: :asc)
      .to_a
  end
end
