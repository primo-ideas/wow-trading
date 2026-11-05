class ApplicationController < ActionController::Base
  helper_method :current_realm, :watchlist

  # The fetcher creates the schema on its first run, which may not have happened yet.
  rescue_from ActiveRecord::StatementInvalid do |error|
    raise error unless error.cause.is_a?(PG::UndefinedTable)

    # The header shows the realm, from a table that is missing as well.
    @current_realm = nil
    render "errors/not_ready", status: :service_unavailable
  end

  private

  def tracked_markets
    @tracked_markets ||= AuctionHouse.tracked.to_a
  end

  # The realm of the page, or else the one the player picked last.
  def current_realm
    return @current_realm if defined?(@current_realm)

    @current_realm = remembered_realm
  end

  def remembered_realm
    return @remembered_realm if defined?(@remembered_realm)

    region, slug = cookies[:realm].to_s.split("/", 2)
    @remembered_realm = slug.present? ? Realm.find_by_route(region, slug) : nil
  end

  # The realm in the address, which becomes the player's: the next visit starts there.
  def load_realm
    @current_realm = find_realm
    unless remembered_realm == @current_realm
      cookies[:realm] = cookie_options.merge(value: "#{@current_realm.region}/#{@current_realm.slug}")
    end
  end

  def find_realm
    Realm.find_by_route(params[:region], params[:realm]) or raise ActiveRecord::RecordNotFound
  end

  def watchlist
    @watchlist ||= Watchlist.new(cookies[:watched], legacy: cookies[:watchlist])
  end

  # Other sites may share the domain: this one's cookies stay within its path.
  def cookie_options
    { expires: 1.year, same_site: :lax, path: request.script_name.presence || "/", secure: request.ssl? }
  end
end
