module ProductsHelper
  QUALITIES = {
    "POOR" => "Poor",
    "COMMON" => "Common",
    "UNCOMMON" => "Uncommon",
    "RARE" => "Rare",
    "EPIC" => "Epic",
    "LEGENDARY" => "Legendary",
    "ARTIFACT" => "Artifact",
    "HEIRLOOM" => "Heirloom"
  }.freeze

  def quality_label(quality) = QUALITIES[quality]

  def quality_class(quality)
    QUALITIES.key?(quality) ? "q-#{quality.downcase}" : "q-unknown"
  end

  # The icon sits on Blizzard's image server. A missing one leaves a plain tile, in
  # the quality's color like the real thing, rather than a broken image.
  def product_icon(icon_url, quality, size: :small)
    classes = [ "icon", "icon-#{size}", quality_class(quality) ]
    return tag.span("", class: classes, "aria-hidden": "true") if icon_url.blank?

    pixels = size == :large ? 64 : 28
    image_tag(icon_url, alt: "", class: classes, width: pixels, height: pixels, loading: "lazy", decoding: "async")
  end

  # What tells apart products sharing an item id, see `variant` in the README.
  def variant_label(variant)
    case variant.to_s
    when "" then nil
    when /\Apet:(.+)\z/ then "Species #{$1}"
    when /\Abonus:(.+)\z/ then "Bonus #{$1.split(",").join(", ")}"
    else variant
    end
  end

  # Adds a product to the reader's watchlist, or takes it off.
  def watch_button(item_id, series, compact: false)
    watching = watchlist.include?(item_id, series)
    label = watching ? "★ Watching" : "☆ Watch"
    button_to (compact ? label.first : label), watchlist_path, method: :patch,
      params: { item_id: item_id, series: series },
      class: [ "watch-button", ("is-watching" if watching) ], form_class: "watch-form",
      "aria-label": (watching ? "Remove from your watchlist" : "Add to your watchlist"),
      data: { tip: watching ? "Remove from your watchlist" : "Add to your watchlist: it follows you from realm to realm" },
      "aria-pressed": watching, form: { data: { turbo_frame: "_top" } }
  end

  def sparkline(values)
    line = Sparkline.new(values)
    return tag.span("", class: "sparkline-empty") unless line.drawable?

    x, y = line.end_point
    tag.svg(viewBox: line.view_box, class: "sparkline #{line.direction}", width: Sparkline::WIDTH,
      height: Sparkline::HEIGHT, "aria-hidden": "true") do
      safe_join([
        tag.path(d: line.area_path, class: "sparkline-area"),
        tag.path(d: line.line_path, class: "sparkline-line"),
        tag.circle(cx: x, cy: y, r: 2.5, class: "sparkline-end")
      ])
    end
  end

  # How recent the data is, as this also tells whether the fetcher is still running.
  def freshness(time)
    return unless time

    state = Time.current - time > Freshness::STALE_AFTER ? "stale" : "fresh"
    label = state == "stale" ? "Stale data: " : "Updated "
    tag.span(class: "freshness #{state}", tabindex: 0, data: { tip: "Latest snapshot: #{l(time, format: "%b %-d, %Y at %H:%M")}" }) do
      safe_join([ tag.i("", class: "freshness-dot", "aria-hidden": "true"), "#{label}#{time_ago_in_words(time)} ago" ])
    end
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
        LineChart::Series.new(key: :median, name: "Median", css_class: "series-1"),
        LineChart::Series.new(key: :min, name: "Minimum", css_class: "series-2")
      ],
      band: LineChart::Band.new(low_key: :p25, high_key: :p75, name: "1st – 3rd quartile"),
      format_value: method(:money_text),
      format_label: method(:money),
      format_axis: method(:axis_money),
      format_parts: method(:money_parts)
    )
  end

  def quantity_chart(history)
    LineChart.new(
      rows: history.prices.map { |point|
        { time: point.taken_at, title: point_title(point), quantity: point.quantity }
      },
      series: [ LineChart::Series.new(key: :quantity, name: "For sale", css_class: "series-1") ],
      format_value: method(:number_with_delimiter),
      format_axis: method(:axis_count),
      format_parts: method(:count_parts),
      whole_numbers: true
    )
  end

  def sales_chart(history)
    ColumnChart.new(
      rows: history.sales.map { |bucket|
        {
          value: bucket.sold_quantity,
          time: bucket.starts_at,
          title: bucket_title(bucket),
          tick: bucket_tick(bucket),
          details: [
            [ "Quantity", count_parts(bucket.sold_quantity), number_with_delimiter(bucket.sold_quantity) ],
            [ "Value", money_parts(bucket.sold_value), money_text(bucket.sold_value) ],
            [ "Listings", count_parts(bucket.sold_auctions), number_with_delimiter(bucket.sold_auctions) ]
          ]
        }
      },
      format_axis: method(:axis_count)
    )
  end

  # Columns for buckets that recur, like the hours of a day: units sold per day in each,
  # and the price they sold at.
  def rhythm_chart(buckets, short_label: ->(bucket) { bucket.label })
    ColumnChart.new(
      rows: buckets.each_with_index.map { |bucket, index|
        sold = number_with_precision(bucket.quantity, precision: 1, strip_insignificant_zeros: true, delimiter: ",")
        {
          value: bucket.quantity,
          time: index,
          title: bucket.label,
          tick: short_label.call(bucket),
          details: [
            [ "Sold per day", [ [ sold, nil ] ], sold ],
            [ "Average price", money_parts(bucket.price), money_text(bucket.price) ]
          ]
        }
      },
      format_axis: method(:axis_count),
      newest_first: false,
      max_x_labels: 12
    )
  end

  private

  def point_title(point)
    return "#{l(point.taken_at.to_date, format: "%b %-d, %Y")}, daily average" if point.daily

    l(point.taken_at, format: "%b %-d, %H:%M")
  end

  # Buckets are UTC days, which is how the fetcher rolls up, whatever the display zone.
  def bucket_title(bucket)
    return l(bucket.starts_at, format: "%b %-d, %H:00") if bucket.hourly?

    l(bucket.starts_at.utc.to_date, format: "%b %-d, %Y")
  end

  def bucket_tick(bucket)
    return l(bucket.starts_at, format: "%H:00") if bucket.hourly?

    l(bucket.starts_at.utc.to_date, format: "%b %-d")
  end
end
