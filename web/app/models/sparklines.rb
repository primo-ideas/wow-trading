# The recent price of a page of products, in as few queries and points as a tiny
# curve needs.
class Sparklines
  PERIOD = 7.days
  # Gear adds up into one curve while each caged pet has its own, as in `listed_products`.
  SERIES = "CASE WHEN variant LIKE 'pet:%' THEN variant ELSE '' END".freeze

  def initialize(rows, latest_taken_at)
    @rows = rows
    @latest_taken_at = latest_taken_at
  end

  def for(row) = series.fetch([ row.auction_house_id, row.item_id, row.series ], [])

  private

  def series
    @series ||= begin
      points = @rows.empty? || @latest_taken_at.nil? ? [] : fetch_points
      points.group_by { |point| [ point.auction_house_id, point.item_id, point.series ] }
        .transform_values { |group| group.map(&:price) }
    end
  end

  def fetch_points
    pets = @rows.filter_map { |row| row.series.presence }
    PricePoint.find_by_sql([ <<~SQL, houses: @rows.map(&:auction_house_id).uniq, since: @latest_taken_at - PERIOD, ids: @rows.map(&:item_id).uniq, pets: pets ])
      SELECT auction_house_id, item_id, #{SERIES} AS series,
             date_bin('6 hours', taken_at, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS bucket,
             (sum(median_price::numeric * quantity) / NULLIF(sum(quantity), 0))::float8 AS price
      FROM price_points
      WHERE auction_house_id IN (:houses) AND taken_at >= :since AND item_id IN (:ids)
        AND (variant NOT LIKE 'pet:%' OR variant IN (:pets))
      GROUP BY 1, 2, 3, 4
      ORDER BY 4
    SQL
  end
end
