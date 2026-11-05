# Lines over time, with an optional band behind them, and a value label at the end of
# each line unless it would overlap another.
#
# `rows` are hashes holding :time, :title for the tooltip, and a value per series key.
class LineChart < ChartFrame
  Series = Data.define(:key, :name, :css_class)
  Band = Data.define(:low_key, :high_key, :name)

  # Percent of the plot's height under which two end labels would touch.
  MIN_LABEL_GAP = 7
  # How far above the highest line the band can push the scale.
  BAND_HEADROOM = 1.5

  attr_reader :series, :band

  # `format_value` is for the data table, where a line of plain text per value keeps a
  # long period from weighing hundreds of kilobytes. `format_label` is for the line ends.
  def initialize(rows:, series:, band: nil, format_value:, format_axis:, format_parts:, format_label: format_value, whole_numbers: false)
    @rows = rows
    @series = series
    @band = band
    @format_value = format_value
    @format_label = format_label
    @format_axis = format_axis
    @format_parts = format_parts
    @whole_numbers = whole_numbers
  end

  def whole_numbers? = @whole_numbers

  def legend? = series.size + (band ? 1 : 0) > 1

  def x(time)
    first, last = @rows.first[:time], @rows.last[:time]
    return 50.0 if first == last

    ((time - first).fdiv(last - first) * 100).round(2)
  end

  # In a 100 by 100 box, stretched to the plot.
  def line_path(key)
    coordinates = @rows.map { |row| "#{x(row[:time])} #{y(row[key])}" }
    return "M#{coordinates.first}h0" if coordinates.one?

    "M#{coordinates.join("L")}"
  end

  # Stops at the edges of the plot when the scale leaves part of the band out.
  def band_path
    upper = @rows.map { |row| "#{x(row[:time])} #{y(row[band.high_key]).clamp(0, 100)}" }
    lower = @rows.reverse.map { |row| "#{x(row[:time])} #{y(row[band.low_key]).clamp(0, 100)}" }
    "M#{(upper + lower).join("L")}Z"
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
        label: labelled ? @format_label.call(last[line.key]) : nil
      }
    end
  end

  def markers = series.map(&:css_class)

  # For the script: it only places what is already formatted here.
  def points
    @rows.map do |row|
      {
        x: x(row[:time]),
        t: row[:time].to_i,
        title: row[:title],
        y: series.map { |line| y(row[line.key]) },
        rows: columns.map { |column|
          { name: column[:name], css_class: column[:css_class], parts: column[:parts].call(row) }
        }
      }
    end
  end

  def table_columns = columns.map { |column| column[:name] }

  def table_rows
    @rows.reverse.map do |row|
      [ row[:title], *columns.map { |column| column[:cell].call(row) } ]
    end
  end

  private

  def columns
    @columns ||= series.map { |line|
      {
        name: line.name,
        css_class: line.css_class,
        parts: ->(row) { @format_parts.call(row[line.key]) },
        cell: ->(row) { @format_value.call(row[line.key]) }
      }
    } + band_columns
  end

  def band_columns
    return [] unless band

    [ {
      name: band.name,
      css_class: "band",
      parts: ->(row) {
        @format_parts.call(row[band.low_key]) + [ [ "–", nil ] ] + @format_parts.call(row[band.high_key])
      },
      cell: ->(row) {
        ActiveSupport::SafeBuffer.new.tap do |cell|
          cell << @format_value.call(row[band.low_key]) << " – " << @format_value.call(row[band.high_key])
        end
      }
    } ]
  end

  # The lines decide. A few absurd listings can put the third quartile at ten times the
  # median, and a scale that showed it all would flatten what the reader came to see.
  def y_range
    low, high = @rows.flat_map { |row| row.values_at(*series.map(&:key)) }.minmax
    return [ low, high ] unless band

    band_low, band_high = @rows.flat_map { |row| row.values_at(band.low_key, band.high_key) }.minmax
    [ [ low, band_low ].min, [ high, [ band_high, high * BAND_HEADROOM ].min ].max ]
  end
end
