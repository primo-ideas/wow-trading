class ItemsController < ApplicationController
  before_action :load_realm, only: :show

  def show
    @item = Item.find(params[:id])
    @market = current_realm.market_of(@item.id)
    @variants = variants_on_sale
    @variant = params[:variant]&.to_s&.delete("\0") || @variants.first&.variant.to_s
    @product = Product.new(@item, @variant)
    @history = ItemHistory.new(@market, @item, variant: @variant, period: params[:period])

    respond_to do |format|
      format.html do
        @listed = ListedProduct.find_by(auction_house_id: @market.id, item_id: @item.id, series: @product.series)
        @across_markets = ProductAcrossMarkets.new(@market, @item.id, @product.series, realm: current_realm)
        @rhythm = SalesRhythm.new(@market, @item.id, @product.series, @history.latest_taken_at)
      end
      format.csv do
        send_data @history.to_csv, type: "text/csv",
          filename: "#{current_realm.region}-#{current_realm.slug.parameterize}-#{@item.id}-#{@history.period}.csv"
      end
    end
  end

  # The card shown on hovering a link to the item. Looking does not change the
  # player's realm, so this one is not remembered.
  def tooltip
    @current_realm = find_realm
    @item = Item.find(params[:id])
    @product = Product.new(@item, params[:variant].to_s.delete("\0"))
    @listed = ListedProduct.find_by(auction_house_id: current_realm.market_ids, item_id: @item.id, series: @product.series)
    render partial: "items/tooltip"
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
