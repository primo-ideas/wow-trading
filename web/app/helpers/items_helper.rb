module ItemsHelper
  QUALITIES = {
    "POOR" => "Médiocre",
    "COMMON" => "Commune",
    "UNCOMMON" => "Inhabituelle",
    "RARE" => "Rare",
    "EPIC" => "Épique",
    "LEGENDARY" => "Légendaire",
    "ARTIFACT" => "Artefact",
    "HEIRLOOM" => "Héritage"
  }.freeze

  def quality_label(quality) = QUALITIES[quality]

  # What tells apart products sharing an item id, see `variant` in the README.
  def variant_label(variant)
    case variant.to_s
    when "" then nil
    when /\Apet:(.+)\z/ then "Espèce #{$1}"
    when /\Abonus:(.+)\z/ then "Bonus #{$1.split(",").join(", ")}"
    else variant
    end
  end

  def listed_name(row)
    row.name.presence || "Objet ##{row.item_id}"
  end

  def snapshot_age(time)
    "il y a #{time_ago_in_words(time)}"
  end

  def price_chart(history)
    LineChart.new(
      rows: history.prices.map { |point|
        {
          time: point.taken_at,
          title: point_title(point),
          median: point.median_price,
          min: point.min_price,
          p25: point.p25_price,
          p75: point.p75_price
        }
      },
      series: [
        LineChart::Series.new(key: :median, name: "Médiane", css_class: "series-1"),
        LineChart::Series.new(key: :min, name: "Minimum", css_class: "series-2")
      ],
      band: LineChart::Band.new(low_key: :p25, high_key: :p75, name: "1er – 3e quartile"),
      format_value: method(:money),
      format_axis: method(:axis_money)
    )
  end

  def quantity_chart(history)
    LineChart.new(
      rows: history.prices.map { |point|
        { time: point.taken_at, title: point_title(point), quantity: point.quantity }
      },
      series: [ LineChart::Series.new(key: :quantity, name: "En vente", css_class: "series-1") ],
      format_value: method(:number_with_delimiter),
      format_axis: method(:axis_count),
      whole_numbers: true
    )
  end

  def sales_chart(history)
    ColumnChart.new(
      rows: history.sales.map { |bucket|
        {
          value: bucket.sold_quantity,
          title: bucket_title(bucket),
          tick: bucket_tick(bucket),
          details: [
            [ "Quantité", number_with_delimiter(bucket.sold_quantity) ],
            [ "Valeur", money(bucket.sold_value) ],
            [ "Annonces", number_with_delimiter(bucket.sold_auctions) ]
          ]
        }
      },
      format_axis: method(:axis_count)
    )
  end

  private

  def point_title(point)
    return "#{l(point.taken_at.to_date, format: "%-d %b %Y")} (moyenne du jour)" if point.daily

    l(point.taken_at, format: "%-d %b %Hh%M")
  end

  # Buckets are UTC days, which is how the fetcher rolls up, whatever the display zone.
  def bucket_title(bucket)
    return l(bucket.starts_at, format: "%-d %b %Hh") if bucket.hourly?

    l(bucket.starts_at.utc.to_date, format: "%-d %b %Y")
  end

  def bucket_tick(bucket)
    return l(bucket.starts_at, format: "%Hh") if bucket.hourly?

    l(bucket.starts_at.utc.to_date, format: "%-d %b")
  end
end
