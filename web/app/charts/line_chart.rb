# Lines over time, with an optional band behind them.
#
# `rows` are hashes holding :time, :title for the tooltip, and a value per series key.
class LineChart < ChartFrame
  Series = Data.define(:key, :name, :css_class)
  Band = Data.define(:low_key, :high_key, :name)

  # Below this distance two end labels would touch, so only the first is kept.
  MIN_LABEL_GAP = 16

  attr_reader :series, :band

  def initialize(rows:, series:, band: nil, format_value:, format_axis:, whole_numbers: false)
    @rows = rows
    @series = series
    @band = band
    @format_value = format_value
    @format_axis = format_axis
    @whole_numbers = whole_numbers
  end

  def whole_numbers? = @whole_numbers

  def legend? = series.size + (band ? 1 : 0) > 1

  def x(time)
    first, last = @rows.first[:time], @rows.last[:time]
    return plot_left + plot_width / 2.0 if first == last

    (plot_left + (time - first).fdiv(last - first) * plot_width).round(1)
  end

  def line_path(key)
    coordinates = @rows.map { |row| "#{x(row[:time])} #{y(row[key])}" }
    "M#{coordinates.join("L")}"
  end

  def band_path
    upper = @rows.map { |row| "#{x(row[:time])} #{y(row[band.high_key])}" }
    lower = @rows.reverse.map { |row| "#{x(row[:time])} #{y(row[band.low_key])}" }
    "M#{(upper + lower).join("L")}Z"
  end

  def y_labels
    y_ticks.map { |value| { y: y(value), label: @format_axis.call(value) } }
  end

  def x_labels
    TimeTicks.new(@rows.first[:time], @rows.last[:time]).ticks.map do |tick|
      { x: x(tick[:time]), label: tick[:label] }
    end
  end

  # One per series, the first ones winning when their labels would overlap.
  def end_marks
    last = @rows.last
    placed = []
    series.map do |line|
      position = y(last[line.key])
      labelled = placed.none? { |other| (other - position).abs < MIN_LABEL_GAP }
      placed << position if labelled
      {
        series: line,
        x: x(last[:time]),
        y: position,
        label: labelled ? @format_value.call(last[line.key]) : nil
      }
    end
  end

  # For the script: it only places what is already formatted here.
  def points
    @rows.map do |row|
      {
        x: x(row[:time]),
        title: row[:title],
        rows: columns.map { |column|
          { name: column[:name], css_class: column[:css_class], value: column[:format].call(row) }
        }
      }
    end
  end

  def table_columns = columns.map { |column| column[:name] }

  def table_rows
    @rows.reverse.map do |row|
      [ row[:title], *columns.map { |column| column[:format].call(row) } ]
    end
  end

  private

  def columns
    @columns ||= series.map { |line|
      { name: line.name, css_class: line.css_class, format: ->(row) { @format_value.call(row[line.key]) } }
    } + band_columns
  end

  def band_columns
    return [] unless band

    [ {
      name: band.name,
      css_class: "band",
      format: ->(row) { "#{@format_value.call(row[band.low_key])} – #{@format_value.call(row[band.high_key])}" }
    } ]
  end

  def y_range
    keys = series.map(&:key) + (band ? [ band.low_key, band.high_key ] : [])
    @rows.flat_map { |row| row.values_at(*keys) }.minmax
  end
end
