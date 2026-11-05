# The recent price of a page of products, in as few queries and points as a tiny
# curve needs.
class Sparklines
  PERIOD = 7.days
  # Gear adds up into one curve while each caged pet has its own, as in `listed_products`.
  SERIES = "CASE WHEN variant LIKE 'pet:%' THEN variant ELSE '' END".freeze

  def initialize(market, rows, latest_taken_at)
    @market = market
    @rows = rows
    @latest_taken_at = latest_taken_at
  end

  def for(row) = series.fetch([ row.item_id, row.series ], [])

  private

  def series
    @series ||= begin
      points = @rows.empty? ? [] : fetch_points
      points.group_by { |point| [ point.item_id, point.series ] }
        .transform_values { |group| group.map(&:price) }
    end
  end

  def fetch_points
    pets = @rows.filter_map { |row| row.series.presence }
    PricePoint.find_by_sql([ <<~SQL, house: @market.id, since: @latest_taken_at - PERIOD, ids: @rows.map(&:item_id).uniq, pets: pets ])
      SELECT item_id, #{SERIES} AS series,
             date_bin('6 hours', taken_at, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS bucket,
             (sum(median_price::numeric * quantity) / NULLIF(sum(quantity), 0))::float8 AS price
      FROM price_points
      WHERE auction_house_id = :house AND taken_at >= :since AND item_id IN (:ids)
        AND (variant NOT LIKE 'pet:%' OR variant IN (:pets))
      GROUP BY 1, 2, 3
      ORDER BY 3
    SQL
  end
end
