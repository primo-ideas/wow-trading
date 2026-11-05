# The curves of one item variant on one market. Hourly detail comes from the
# partitioned tables, and older days from the tables the fetcher rolls them up into.
#
# The period ends at the latest snapshot rather than now, so that curves do not
# empty out when the fetcher has not run for a while.
class ItemHistory
  PERIODS = {
    "24h" => 1.day,
    "7j" => 7.days,
    "30j" => 30.days,
    "90j" => 90.days,
    "tout" => nil
  }.freeze
  DEFAULT_PERIOD = "7j"
  # Sales are spiky: per hour over a day, per day beyond that.
  HOURLY_SALES_PERIOD = "24h"

  # Before any data, for periods without a start.
  EARLIEST = Time.utc(2000)

  # How far from exactly a day or a week ago a snapshot can be and still give a change.
  REFERENCE_TOLERANCE = 12.hours

  SalesBucket = Data.define(:starts_at, :hourly, :sold_quantity, :sold_value, :sold_auctions) do
    def hourly? = hourly
  end

  Range = Data.define(:low, :high, :average)

  attr_reader :period, :variant

  def initialize(market, item, variant:, period: nil)
    @market = market
    @item = item
    @variant = variant
    @period = PERIODS.key?(period) ? period : DEFAULT_PERIOD
  end

  def latest_taken_at
    return @latest_taken_at if defined?(@latest_taken_at)

    @latest_taken_at = @market.latest_snapshot_at
  end

  def starts_at
    return @starts_at if defined?(@starts_at)

    length = PERIODS.fetch(period)
    @starts_at = latest_taken_at && length ? latest_taken_at - length : nil
  end

  def prices
    return [] unless latest_taken_at

    @prices ||= PricePoint.find_by_sql([ <<~SQL, binds ])
      SELECT taken_at, false AS daily, min_price, p25_price, median_price, p75_price, quantity,
             auction_count
      FROM price_points
      WHERE auction_house_id = :house AND item_id = :item AND variant = :variant
        AND taken_at >= :from
      UNION ALL
      SELECT (day + time '12:00') AT TIME ZONE 'UTC', true, min_price, p25_price, median_price,
             p75_price, quantity, auction_count
      FROM price_points_daily
      WHERE auction_house_id = :house AND item_id = :item AND variant = :variant
        AND day >= (:from)::date
      ORDER BY 1
    SQL
  end

  # Where the median moved over the period, to tell at a glance if it is cheap now.
  def median_range
    medians = prices.map(&:median_price)
    return if medians.empty?

    Range.new(low: medians.min, high: medians.max, average: medians.sum.fdiv(medians.size).round)
  end

  # Every bucket of the period, including the ones without a sale.
  def sales
    return [] unless latest_taken_at

    @sales ||= begin
      rows = sales_rows.index_by { |row| row.bucket.to_i }
      sales_bucket_starts(rows).map do |starts_at|
        row = rows[starts_at.to_i]
        SalesBucket.new(
          starts_at: starts_at.in_time_zone,
          hourly: hourly_sales?,
          sold_quantity: row&.sold_quantity.to_i,
          sold_value: row&.sold_value.to_i,
          sold_auctions: row&.sold_auctions.to_i
        )
      end
    end
  end

  # The point of the latest snapshot, or nil if the variant is no longer on sale.
  def current
    return unless latest_taken_at

    return @current if defined?(@current)

    @current = points.find_by(taken_at: latest_taken_at)
  end

  # The point from about a day before the latest snapshot.
  def reference
    return @reference if defined?(@reference)

    @reference = point_about(1.day)
  end

  # The point from about a week before the latest snapshot.
  def week_reference
    return @week_reference if defined?(@week_reference)

    @week_reference = point_about(7.days)
  end

  def sold_last_day
    return 0 unless latest_taken_at

    @sold_last_day ||= sales_last_day.sum(:sold_quantity)
  end

  def sold_value_last_day
    return 0 unless latest_taken_at

    @sold_value_last_day ||= sales_last_day.sum(:sold_value)
  end

  private

  def points
    PricePoint.where(auction_house_id: @market.id, item_id: @item.id, variant: variant)
  end

  def point_about(ago)
    return unless latest_taken_at

    target = latest_taken_at - ago
    points
      .where(taken_at: (target - REFERENCE_TOLERANCE)..target)
      .order(taken_at: :desc)
      .first
  end

  def sales_last_day
    SalesPoint
      .where(auction_house_id: @market.id, item_id: @item.id, variant: variant)
      .where("taken_at > ?", latest_taken_at - 1.day)
  end

  def hourly_sales? = period == HOURLY_SALES_PERIOD

  def binds
    { house: @market.id, item: @item.id, variant: variant, from: starts_at || EARLIEST }
  end

  # Whole days only: a first column covering half a day would look like a drop.
  def sales_binds
    return binds.merge(unit: "hour") if hourly_sales?

    binds.merge(unit: "day", from: (starts_at || EARLIEST).utc.beginning_of_day)
  end

  def sales_rows
    SalesPoint.find_by_sql([ <<~SQL, sales_binds ])
      SELECT bucket,
             sum(sold_quantity)::bigint AS sold_quantity,
             least(sum(sold_value), 9223372036854775807)::bigint AS sold_value,
             sum(sold_auctions)::bigint AS sold_auctions
      FROM (
        SELECT date_trunc(:unit, taken_at, 'UTC') AS bucket, sold_quantity, sold_value, sold_auctions
        FROM sales_points
        WHERE auction_house_id = :house AND item_id = :item AND variant = :variant
          AND taken_at >= :from
        UNION ALL
        SELECT day::timestamp AT TIME ZONE 'UTC', sold_quantity, sold_value, sold_auctions
        FROM sales_points_daily
        WHERE auction_house_id = :house AND item_id = :item AND variant = :variant
          AND day >= (:from)::date
      ) AS sold
      GROUP BY bucket
      ORDER BY bucket
    SQL
  end

  def sales_bucket_starts(rows)
    first = starts_at&.utc || rows.keys.min&.then { |seconds| Time.at(seconds).utc }
    return [] unless first

    step = hourly_sales? ? 1.hour : 1.day
    current = hourly_sales? ? first.beginning_of_hour : first.beginning_of_day
    starts = []
    while current <= latest_taken_at
      starts << current
      current += step
    end
    starts
  end
end
