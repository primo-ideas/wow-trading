# When a product sells: estimated sales by hour of the day and by day of the week, on
# average over the last two weeks of hourly detail, in the site's time zone. Gear adds up
# its variants and each caged pet stands alone, as in `listed_products`.
class SalesRhythm
  PERIOD = 14.days
  MIN_DAYS_FOR_HOURS = 2
  MIN_DAYS_FOR_WEEKDAYS = 7
  # A snapshot counts what sold since the one before, about an hour earlier: half of that
  # hour back is closer to when it sold.
  SALE_SHIFT = "30 minutes".freeze
  # Monday first, as `isodow` counts.
  WEEKDAYS = %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday].freeze

  Bucket = Data.define(:key, :label, :quantity, :value) do
    # Per day the bucket happens, so that buckets are comparable.
    def price = quantity.positive? ? value.fdiv(quantity).round : nil
  end

  def initialize(market, item_id, series, latest_taken_at)
    @market = market
    @item_id = item_id
    @series = series.to_s
    @latest_taken_at = latest_taken_at
  end

  # Days of history the averages cover, at most PERIOD.
  def days
    return 0.0 unless @latest_taken_at

    @days ||= begin
      first = Snapshot.where(auction_house_id: @market.id, taken_at: (@latest_taken_at - PERIOD)..@latest_taken_at).minimum(:taken_at)
      first ? (@latest_taken_at - first).fdiv(1.day) : 0.0
    end
  end

  def hours? = days >= MIN_DAYS_FOR_HOURS && sold?

  def weekdays? = days >= MIN_DAYS_FOR_WEEKDAYS && sold?

  def sold? = rows.any? { |row| row.quantity.positive? }

  # 24 buckets, from midnight: units sold per day in that hour.
  def hours
    @hours ||= (0..23).map do |hour|
      matching = rows.select { |row| row.hour == hour }
      Bucket.new(key: hour, label: format("%02d:00", hour),
        quantity: matching.sum(&:quantity).fdiv(days_or_one), value: matching.sum(&:value).fdiv(days_or_one))
    end
  end

  # 7 buckets, from Monday: units sold on that day, on average over the times it came.
  def weekdays
    @weekdays ||= WEEKDAYS.each_with_index.map do |name, index|
      matching = rows.select { |row| row.weekday == index + 1 }
      count = [ weekday_counts.fetch(index + 1, 0), 1 ].max
      Bucket.new(key: index + 1, label: name, quantity: matching.sum(&:quantity).fdiv(count), value: matching.sum(&:value).fdiv(count))
    end
  end

  def best_hour = hours.max_by(&:quantity)

  def best_weekday = weekdays.max_by(&:quantity)

  private

  def days_or_one = [ days, 1.0 ].max

  def rows
    return [] unless @latest_taken_at

    @rows ||= SalesPoint.find_by_sql([ <<~SQL, house: @market.id, item: @item_id, series: @series, zone: zone, from: @latest_taken_at - PERIOD, to: @latest_taken_at ])
      SELECT extract(hour FROM (taken_at - interval '#{SALE_SHIFT}') AT TIME ZONE :zone)::int AS hour,
             extract(isodow FROM (taken_at - interval '#{SALE_SHIFT}') AT TIME ZONE :zone)::int AS weekday,
             sum(sold_quantity)::bigint AS quantity,
             least(sum(sold_value), 9223372036854775807)::bigint AS value
      FROM sales_points
      WHERE auction_house_id = :house AND item_id = :item
        AND taken_at > :from AND taken_at <= :to
        AND (CASE WHEN variant LIKE 'pet:%' THEN variant ELSE '' END) = :series
      GROUP BY 1, 2
    SQL
  end

  # How many times each day of the week falls within the period covered.
  def weekday_counts
    @weekday_counts ||= begin
      last = @latest_taken_at.in_time_zone(Time.zone).to_date
      first = (@latest_taken_at - days.days).in_time_zone(Time.zone).to_date
      (first..last).map(&:cwday).tally
    end
  end

  def zone = Time.zone.tzinfo.identifier
end
