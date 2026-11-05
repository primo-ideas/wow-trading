# Addresses from when the site was organised by market rather than by realm. A link to
# a market leads to a realm of it, the player's own when it is one.
class LegacyController < ApplicationController
  def markets
    redirect_to realms_path, status: :moved_permanently
  end

  def search
    if remembered_realm
      redirect_to realm_search_path(remembered_realm.region, remembered_realm.slug, q: params[:q].presence), status: :moved_permanently
    else
      redirect_to realms_path, status: :moved_permanently
    end
  end

  def market
    realm = realm_of_market or return redirect_to(realms_path, status: :moved_permanently)
    redirect_to realm_path(realm.region, realm.slug), status: :moved_permanently
  end

  def deals
    realm = realm_of_market or return redirect_to(realms_path, status: :moved_permanently)
    redirect_to realm_deals_path(realm.region, realm.slug), status: :moved_permanently
  end

  def item
    variant = params[:variant].to_s.presence
    realm = realm_of_market(params[:market_id])
    unless realm
      return redirect_to realms_path(item: params[:id], variant: variant), status: :moved_permanently
    end

    redirect_to realm_item_path(realm.region, realm.slug, params[:id], variant: variant, period: params[:period].to_s.presence,
      format: params[:format]), status: :moved_permanently
  end

  private

  # The commodities of a region are the same from any of its realms, so only the
  # player's own will do: without one, they pick it.
  def realm_of_market(id = params[:id])
    market = AuctionHouse.find(id)
    realms = market.commodities? ? Realm.where(region: market.region) : Realm.where(auction_house_id: market.id)
    return remembered_realm if remembered_realm && realms.exists?(region: remembered_realm.region, slug: remembered_realm.slug)
    return if market.commodities?

    realms.by_name.first
  end
end
